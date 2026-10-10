defmodule GenAgentEnsemble.ChildSpecTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble, as: Ensemble

  defmodule Strategy do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(opts), do: {:ok, nil, Keyword.fetch!(opts, :agents)}

    @impl true
    def handle_tell(_prompt, _opts, _token, state), do: {:ok, [{:halt, :done}], state}

    @impl true
    def handle_ask(_prompt, _opts, _token, state), do: {:ok, [], state}

    @impl true
    def handle_response(_agent, _response, state), do: {:ok, [], state}
  end

  setup do
    prefix = "child-spec-#{System.unique_integer([:positive])}"
    %{names: ["#{prefix}-one", "#{prefix}-two"]}
  end

  defp options(name) do
    [
      name: name,
      strategy: Strategy,
      opts: [
        agents: [{"worker", GenAgentEnsemble.TestAgent, [backend: GenAgent.Backends.Mock]}]
      ]
    ]
  end

  defp supervise(names) do
    start_supervised!(%{
      id: :caller_supervisor,
      start:
        {Supervisor, :start_link,
         [Enum.map(names, &{Ensemble, options(&1)}), [strategy: :one_for_one]]},
      type: :supervisor
    })
  end

  defp child(supervisor, name) do
    {_, pid, :worker, [Ensemble]} =
      List.keyfind(Supervisor.which_children(supervisor), {Ensemble, name}, 0)

    pid
  end

  defp owned_processes(server, name) do
    state = :sys.get_state(server)

    {:ok, task} =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    [
      server,
      state.agent_tree,
      state.agent_supervisor,
      state.task_supervisor,
      GenAgent.whereis("#{name}/worker"),
      task
    ]
    |> Enum.map(&{&1, Process.monitor(&1)})
  end

  defp assert_cleaned_up(refs) do
    for {pid, ref} <- refs do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      refute Process.alive?(pid)
    end
  end

  defp await_child(supervisor, name, predicate, attempts \\ 200) do
    pid = child(supervisor, name)

    cond do
      predicate.(pid) ->
        pid

      attempts > 0 ->
        Process.sleep(10)
        await_child(supervisor, name, predicate, attempts - 1)

      true ->
        flunk("child #{name} did not reach the expected state")
    end
  end

  test "spec preserves identity and start options without changing the name", %{names: [name | _]} do
    opts = options(name)

    assert %{
             id: {Ensemble, ^name},
             start: {Ensemble, :start_link, [^opts]},
             restart: :transient,
             shutdown: :infinity,
             type: :worker
           } = Ensemble.child_spec(opts)

    assert Ensemble.child_spec(name: :existing_atom).id == {Ensemble, :existing_atom}
    assert_raise KeyError, fn -> Ensemble.child_spec(strategy: Strategy) end
    assert_raise KeyError, fn -> Ensemble.start_link(strategy: Strategy) end
  end

  test "two named ensembles share a caller supervisor with distinct identities", %{names: names} do
    supervisor = supervise(names)
    pids = Enum.map(names, &child(supervisor, &1))
    assert length(Enum.uniq(pids)) == 2

    for {name, pid} <- Enum.zip(names, pids) do
      assert Registry.lookup(GenAgentEnsemble.Registry, name) == [{pid, nil}]
      assert {:ok, _} = Ensemble.status(name)
      assert is_pid(GenAgent.whereis("#{name}/worker"))
    end
  end

  for action <- [:stop, :halt] do
    test "#{action} stays stopped and cleans up the owned tree", %{names: [name, keep]} do
      supervisor = supervise([name, keep])
      server = child(supervisor, name)
      keep_server = child(supervisor, keep)
      refs = owned_processes(server, name)

      case unquote(action) do
        :stop -> assert :ok = Ensemble.stop(name)
        :halt -> assert {:ok, _} = Ensemble.tell(name, "halt")
      end

      assert_cleaned_up(refs)
      assert await_child(supervisor, name, &(&1 == :undefined)) == :undefined
      assert %{active: 1} = Supervisor.count_children(supervisor)
      assert child(supervisor, keep) == keep_server
      assert {:ok, _} = Ensemble.status(keep)
      assert Registry.lookup(GenAgentEnsemble.Registry, name) == []
    end
  end

  test "abnormal exit restarts with the same identity after owned tree cleanup", %{
    names: [name, keep]
  } do
    supervisor = supervise([name, keep])
    old = child(supervisor, name)
    keep_server = child(supervisor, keep)
    refs = owned_processes(old, name)
    Process.exit(old, :kill)
    assert_cleaned_up(refs)

    new = await_child(supervisor, name, &(is_pid(&1) and &1 != old))
    assert Registry.lookup(GenAgentEnsemble.Registry, name) == [{new, nil}]
    assert {:ok, _} = Ensemble.status(name)
    assert is_pid(GenAgent.whereis("#{name}/worker"))
    assert child(supervisor, keep) == keep_server
  end
end
