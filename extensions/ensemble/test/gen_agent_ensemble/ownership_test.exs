defmodule GenAgentEnsemble.OwnershipTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.{Solo, Switchboard}

  defmodule FailingAgent do
    use GenAgent

    @impl true
    def init_agent(_opts), do: {:error, :refused}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  setup do
    name = "owned-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case Registry.lookup(GenAgentEnsemble.Registry, name) do
        [{server, _}] when is_pid(server) ->
          case DynamicSupervisor.terminate_child(GenAgentEnsemble.Supervisor, server) do
            :ok -> :ok
            {:error, :not_found} -> Ensemble.stop(name)
          end

        [] ->
          :ok
      end
    end)

    {:ok, name: name}
  end

  defp spec(tag, module \\ ControlledAgent) do
    {tag, module, [backend: ControlledBackend, observer: self(), tag: tag]}
  end

  defp start_solo(name) do
    {:ok, server} = Ensemble.start_link(name: name, strategy: Solo, opts: [agent: spec("worker")])
    Process.unlink(server)
    server
  end

  defp held_turn(name, server) do
    {:ok, token} = Ensemble.tell(name, "hold")
    assert_receive {:controlled_prompt, "worker", "hold", task}, 2_000
    agent = GenAgent.whereis("#{name}/worker")
    tree = :sys.get_state(server).agent_tree
    {agent, task, tree, token}
  end

  test "abrupt owner loss stops its agent and task and permits a clean restart", %{name: name} do
    server = start_solo(name)
    {agent, task, tree, _token} = held_turn(name, server)
    refs = Enum.map([server, agent, task, tree], &Process.monitor/1)

    Process.exit(server, :kill)

    Enum.each(refs, fn ref ->
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end)

    assert_deregistered("#{name}/worker")
    assert no_ensemble_telemetry_handler?(name)

    replacement = start_solo(name)
    {replacement_agent, replacement_task, _tree, token} = held_turn(name, replacement)
    assert replacement_agent != agent
    send(replacement_task, {:result, "restarted"})
    assert {:ok, :completed, %{text: "restarted"}} = await_result(name, token)
  end

  test "graceful stop removes the owned tree and allows the same name again", %{name: name} do
    server = start_solo(name)
    {agent, task, tree, _token} = held_turn(name, server)
    refs = Enum.map([server, agent, task, tree], &Process.monitor/1)

    :ok = Ensemble.stop(name)

    Enum.each(refs, fn ref ->
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end)

    assert no_ensemble_telemetry_handler?(name)
    assert is_pid(start_solo(name))
  end

  test "loss of the task supervisor stops the session instead of retaining stale child PIDs", %{
    name: name
  } do
    server = start_solo(name)
    {agent, task, tree, _token} = held_turn(name, server)
    task_supervisor = :sys.get_state(server).task_supervisor
    refs = Enum.map([server, agent, task, tree], &Process.monitor/1)

    Process.exit(task_supervisor, :kill)

    Enum.each(refs, fn ref ->
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end)

    assert_deregistered("#{name}/worker")
    assert is_pid(start_solo(name))
  end

  test "an application-supervised session restarts after its prior tree finishes", %{name: name} do
    opts = [name: name, strategy: Solo, opts: [agent: spec("worker")]]

    {:ok, old_server} =
      DynamicSupervisor.start_child(GenAgentEnsemble.Supervisor, {GenAgentEnsemble.Server, opts})

    {old_agent, old_task, old_tree, _token} = held_turn(name, old_server)
    refs = Enum.map([old_server, old_agent, old_task, old_tree], &Process.monitor/1)
    Process.exit(old_server, :kill)

    Enum.each(refs, fn ref ->
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end)

    replacement = await_replacement(name, old_server)
    {_agent, task, _tree, token} = held_turn(name, replacement)
    send(task, {:result, "restarted"})
    assert {:ok, :completed, %{text: "restarted"}} = await_result(name, token)
  end

  test "a failed initial child leaves no usable session or surviving sibling", %{name: name} do
    # This ownership test also runs against the currently published Hex core.
    # The precise startup tag is covered by the core's startup tests.
    assert {:error, {_, :refused}} =
             Ensemble.start_link(
               name: name,
               strategy: Switchboard,
               opts: [agents: [spec("good"), spec("bad", FailingAgent)]]
             )

    assert Registry.lookup(GenAgentEnsemble.Registry, name) == []
    assert_deregistered("#{name}/good")
    assert_deregistered("#{name}/bad")
    assert no_ensemble_telemetry_handler?(name)
    assert is_pid(start_solo(name))
  end

  test "a caller that dies during initialization takes the session and its tree with it", %{
    name: name
  } do
    # The session start event fires inside init/1 after the tree and agents
    # exist, so blocking it parks a fully built session before start returns.
    handler = "ownership-test-block-init:#{name}"

    :ok =
      :telemetry.attach(
        handler,
        [:gen_agent_ensemble, :session, :start],
        &__MODULE__.block_session_start/4,
        {name, self()}
      )

    on_exit(fn ->
      :telemetry.detach(handler)

      # On regression the server is still parked in init; release it so the
      # setup cleanup can stop it.
      case Registry.lookup(GenAgentEnsemble.Registry, name) do
        [{server, _}] -> send(server, :release_session_start)
        [] -> :ok
      end
    end)

    opts = [name: name, strategy: Solo, opts: [agent: spec("worker")]]
    caller = spawn(fn -> Ensemble.start_link(opts) end)

    assert_receive {:session_start_blocked, server}, 2_000
    assert [{^server, _}] = Registry.lookup(GenAgentEnsemble.Registry, name)
    assert [{tree, _}] = Registry.lookup(GenAgentEnsemble.AgentTreeRegistry, name)
    agent = GenAgent.whereis("#{name}/worker")
    assert is_pid(agent)
    refs = Enum.map([server, tree, agent], &Process.monitor/1)

    Process.exit(caller, :kill)

    Enum.each(refs, fn ref ->
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end)

    assert_deregistered("#{name}/worker")
    :telemetry.detach(handler)
    assert is_pid(start_solo(name))
  end

  def block_session_start(_event, _measurements, %{session: session}, {session, test_pid}) do
    send(test_pid, {:session_start_blocked, self()})

    receive do
      :release_session_start -> :ok
    end
  end

  def block_session_start(_event, _measurements, _metadata, _config), do: :ok

  test "starting after an older crash removes its stale telemetry handler", %{name: name} do
    handler = "gen_agent_ensemble:#{name}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:gen_agent, :prompt, :stop], [:gen_agent, :prompt, :error]],
        &__MODULE__.ignore_event/4,
        self()
      )

    assert is_pid(start_solo(name))
    assert no_ensemble_telemetry_handler?(name)
  end

  defp no_ensemble_telemetry_handler?(name) do
    Enum.all?(:telemetry.list_handlers([:gen_agent, :prompt, :stop]), fn handler ->
      handler.id != "gen_agent_ensemble:#{name}"
    end)
  end

  def ignore_event(_event, _measurements, _metadata, _config), do: :ok

  defp assert_deregistered(name) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    await_deregistration(name, deadline)
  end

  defp await_deregistration(name, deadline) do
    case GenAgent.whereis(name) do
      nil ->
        :ok

      pid ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("#{name} remained registered as #{inspect(pid)}")
        else
          Process.sleep(10)
          await_deregistration(name, deadline)
        end
    end
  end

  defp await_result(name, token, attempts \\ 100) do
    case Ensemble.poll(name, token) do
      {:ok, :pending} when attempts > 0 ->
        Process.sleep(10)
        await_result(name, token, attempts - 1)

      result ->
        result
    end
  end

  defp await_replacement(name, old_server, attempts \\ 100) do
    case Registry.lookup(GenAgentEnsemble.Registry, name) do
      [{replacement, _}] when replacement != old_server ->
        if GenAgent.whereis("#{name}/worker") do
          replacement
        else
          retry_replacement(name, old_server, attempts)
        end

      _ ->
        retry_replacement(name, old_server, attempts)
    end
  end

  defp retry_replacement(_name, _old_server, 0), do: flunk("session did not restart")

  defp retry_replacement(name, old_server, attempts) do
    Process.sleep(10)
    await_replacement(name, old_server, attempts - 1)
  end
end
