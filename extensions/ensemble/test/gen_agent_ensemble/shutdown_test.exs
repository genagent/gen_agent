defmodule GenAgentEnsemble.ShutdownTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.Server

  defmodule Backend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts), do: {:ok, opts}

    @impl true
    def prompt(session, _prompt), do: {:ok, [], session}

    @impl true
    def terminate_session(session) do
      send(session[:observer], {:backend_terminating, self()})

      if session[:block],
        do: receive_release(:release_backend, Keyword.get(session, :callback_timeout, 3_000))

      :ok
    end

    def receive_release(message, timeout \\ 3_000) do
      receive do
        ^message -> :ok
      after
        timeout -> raise "shutdown callback was not released"
      end
    end
  end

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, opts, opts}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}

    @impl true
    def terminate_agent(reason, state) do
      send(state[:observer], {:agent_terminating, self(), reason})

      if state[:block],
        do: Backend.receive_release(:release_agent, Keyword.get(state, :callback_timeout, 3_000))

      :ok
    end
  end

  defmodule FailingAgent do
    use GenAgent

    @impl true
    def init_agent(_opts), do: {:error, :refused}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  defmodule Strategy do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(opts), do: {:ok, nil, Keyword.fetch!(opts, :agents)}

    @impl true
    def handle_tell(_prompt, _opts, _token, state), do: {:ok, [], state}

    @impl true
    def handle_ask(_prompt, _opts, _token, state), do: {:ok, [], state}

    @impl true
    def handle_response(_agent, _response, state), do: {:ok, [], state}
  end

  setup do
    name = "shutdown-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if agent = GenAgent.whereis("#{name}/worker") do
        send(agent, :release_agent)
        send(agent, :release_backend)
      end

      case Registry.lookup(GenAgentEnsemble.Registry, name) do
        [{server, _}] ->
          case DynamicSupervisor.terminate_child(GenAgentEnsemble.Supervisor, server) do
            :ok -> :ok
            {:error, :not_found} -> Ensemble.stop(name)
          end

        [] ->
          :ok
      end
    end)

    %{name: name}
  end

  defp options(name, block \\ true) do
    [
      name: name,
      strategy: Strategy,
      opts: [agents: [{"worker", Agent, [backend: Backend, observer: self(), block: block]}]]
    ]
  end

  defp owned_processes(server, name) do
    state = :sys.get_state(server)
    agent = GenAgent.whereis("#{name}/worker")
    pids = [server, state.agent_tree, state.agent_supervisor, state.task_supervisor, agent]
    {agent, Enum.map(pids, &{&1, Process.monitor(&1)})}
  end

  defp release_callbacks(server, agent, refs, shutdown_task \\ nil) do
    assert_receive {:agent_terminating, ^agent, :shutdown}, 2_000
    assert Process.alive?(server)
    assert Registry.keys(GenAgentEnsemble.Registry, server) == []
    {tree, _ref} = Enum.at(refs, 1)
    assert Registry.keys(GenAgentEnsemble.AgentTreeRegistry, tree) != []
    refute_server_down(server, refs)
    if shutdown_task, do: refute_shutdown_reply(shutdown_task)

    send(agent, :release_agent)
    assert_receive {:backend_terminating, ^agent}, 2_000
    assert Process.alive?(server)
    refute_server_down(server, refs)
    if shutdown_task, do: refute_shutdown_reply(shutdown_task)

    send(agent, :release_backend)
    assert_stopped(refs)
  end

  defp refute_server_down(server, refs) do
    {^server, ref} = List.keyfind(refs, server, 0)
    refute_receive {:DOWN, ^ref, :process, ^server, _}, 50
  end

  defp refute_shutdown_reply(%Task{ref: ref}) do
    refute_receive {^ref, _}, 50
  end

  defp assert_stopped(refs) do
    Enum.each(refs, fn {pid, ref} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      refute Process.alive?(pid)
    end)
  end

  # Registry removes dead owners asynchronously, after their monitor fires.
  defp assert_unregistered(registry, name, attempts \\ 100) do
    case Registry.lookup(registry, name) do
      [] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        assert_unregistered(registry, name, attempts - 1)

      entries ->
        flunk("#{name} remained registered: #{inspect(entries)}")
    end
  end

  test "supervisor termination waits for agent and backend callbacks", %{name: name} do
    {:ok, server} =
      DynamicSupervisor.start_child(GenAgentEnsemble.Supervisor, {Server, options(name)})

    {agent, refs} = owned_processes(server, name)

    shutdown =
      Task.async(fn -> DynamicSupervisor.terminate_child(GenAgentEnsemble.Supervisor, server) end)

    release_callbacks(server, agent, refs, shutdown)
    assert Task.await(shutdown) == :ok
    assert_unregistered(GenAgentEnsemble.AgentTreeRegistry, name)
  end

  test "supervisor honors a sub-agent shutdown budget longer than five seconds", %{name: name} do
    opts = options(name)
    [{agent_name, module, agent_opts}] = opts[:opts][:agents]
    agent_opts = Keyword.merge(agent_opts, shutdown: 10_000, callback_timeout: 10_000)
    opts = Keyword.put(opts, :opts, agents: [{agent_name, module, agent_opts}])

    {:ok, server} =
      DynamicSupervisor.start_child(GenAgentEnsemble.Supervisor, {Server, opts})

    {agent, refs} = owned_processes(server, name)
    {^server, ref} = List.keyfind(refs, server, 0)

    shutdown =
      Task.async(fn -> DynamicSupervisor.terminate_child(GenAgentEnsemble.Supervisor, server) end)

    assert_receive {:agent_terminating, ^agent, :shutdown}, 2_000
    # With the old session child spec, its supervisor kills it at five seconds,
    # even though the agent is still within its explicitly longer budget.
    refute_receive {:DOWN, ^ref, :process, ^server, _reason}, 5_100
    refute_shutdown_reply(shutdown)
    send(agent, :release_agent)
    assert_receive {:backend_terminating, ^agent}, 2_000
    send(agent, :release_backend)
    assert_stopped(refs)
    assert Task.await(shutdown) == :ok
  end

  for reason <- [:normal, :shutdown, :killed] do
    test "linked owner exit #{reason} stops the session after its callbacks", %{name: name} do
      observer = self()
      opts = options(name)
      reason = unquote(reason)

      owner =
        spawn(fn ->
          {:ok, server} = Ensemble.start_link(opts)
          send(observer, {:session_started, server})

          receive do
            :finish -> exit(reason)
          end
        end)

      on_exit(fn -> Process.exit(owner, :kill) end)
      assert_receive {:session_started, server}, 2_000
      {agent, refs} = owned_processes(server, name)
      send(owner, :finish)

      release_callbacks(server, agent, refs)
      assert_unregistered(GenAgentEnsemble.AgentTreeRegistry, name)
    end
  end

  test "application shutdown waits for session cleanup", %{name: name} do
    # This synchronous test stops the real application tree and restores it
    # before other tests run; no provider or external shell is involved.
    on_exit(fn -> Application.ensure_all_started(:gen_agent_ensemble) end)

    {:ok, server} =
      DynamicSupervisor.start_child(GenAgentEnsemble.Supervisor, {Server, options(name)})

    {agent, refs} = owned_processes(server, name)
    shutdown = Task.async(fn -> Application.stop(:gen_agent_ensemble) end)

    release_callbacks(server, agent, refs, shutdown)
    assert Task.await(shutdown) == :ok
    assert Process.whereis(GenAgentEnsemble.RootSupervisor) == nil
    assert {:ok, _} = Application.ensure_all_started(:gen_agent_ensemble)
  end

  test "failed startup returns an error to an untrapped caller and cleans its sibling", %{
    name: name
  } do
    assert Process.info(self(), :trap_exit) == {:trap_exit, false}
    opts = options(name, false)
    agents = opts[:opts][:agents] ++ [{"bad", FailingAgent, [backend: Backend]}]
    opts = Keyword.put(opts, :opts, agents: agents)

    assert {:error, {:init_agent_failed, :refused}} = Ensemble.start_link(opts)
    assert_receive {:agent_terminating, agent, :shutdown}, 2_000
    assert_receive {:backend_terminating, ^agent}, 2_000
    refute Process.alive?(agent)
    assert_unregistered(GenAgentEnsemble.Registry, name)
    assert_unregistered(GenAgentEnsemble.AgentTreeRegistry, name)
  end

  test "abrupt AgentTree loss stops the server instead of leaving a zombie", %{name: name} do
    {:ok, server} = Ensemble.start_link(options(name, false))
    Process.unlink(server)
    {_agent, refs} = owned_processes(server, name)
    tree = :sys.get_state(server).agent_tree
    Process.exit(tree, :kill)

    assert_stopped(refs)
    assert_unregistered(GenAgentEnsemble.Registry, name)
  end

  test "unrelated linked peers preserve normal and abnormal exit behavior", %{name: name} do
    {:ok, server} = Ensemble.start_link(options(name, false))
    Process.unlink(server)
    {_agent, refs} = owned_processes(server, name)

    for reason <- [:normal, :shutdown] do
      observer = self()

      peer =
        spawn(fn ->
          Process.link(server)
          send(observer, {:peer_linked, self()})

          receive do
            :finish -> exit(reason)
          end
        end)

      ref = Process.monitor(peer)
      assert_receive {:peer_linked, ^peer}
      send(peer, :finish)
      assert_receive {:DOWN, ^ref, :process, ^peer, ^reason}

      if reason == :normal do
        # Ordered call ensures the prior normal EXIT has been processed.
        assert {:ok, _} = Ensemble.status(name)
      else
        assert_stopped(refs)
      end
    end
  end
end
