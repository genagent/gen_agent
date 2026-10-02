defmodule GenAgent.ListTest do
  use ExUnit.Case, async: true

  defmodule SimpleAgent do
    use GenAgent

    @impl true
    def init_agent(_opts), do: {:ok, [], nil}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  test "returns registered names, including non-string names" do
    names = [unique_name(), {:list_agent, make_ref()}]
    Enum.each(names, &start_agent/1)

    snapshot = GenAgent.list()

    assert is_list(snapshot)
    for name <- names, do: assert(name in snapshot)
  end

  test "excludes agents running without registration" do
    name = unique_name()

    pid =
      start_supervised!(
        {GenAgent.Server,
         name: name,
         module: SimpleAgent,
         backend: GenAgent.Backends.Mock,
         task_supervisor: GenAgent.TaskSupervisor}
      )

    assert Process.alive?(pid)
    refute name in GenAgent.list()
  end

  test "stopped agents eventually disappear from subsequent snapshots" do
    name = unique_name()
    start_agent(name)
    snapshot = GenAgent.list()
    assert name in snapshot

    assert :ok = GenAgent.stop(name)
    wait_until_absent(name, 100)

    assert name in snapshot
    refute name in GenAgent.list()
  end

  defp unique_name, do: "list-agent-#{System.unique_integer([:positive])}"

  defp start_agent(name) do
    {:ok, pid} =
      GenAgent.start_agent(SimpleAgent, name: name, backend: GenAgent.Backends.Mock)

    on_exit(fn -> GenAgent.stop(name) end)
    pid
  end

  defp wait_until_absent(name, 0), do: refute(name in GenAgent.list())

  defp wait_until_absent(name, attempts) do
    if name in GenAgent.list() do
      Process.sleep(10)
      wait_until_absent(name, attempts - 1)
    end
  end
end
