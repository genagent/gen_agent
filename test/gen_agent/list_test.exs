defmodule GenAgent.ListTest do
  # Not async: the empty-registry test needs no other test's agents running.
  use ExUnit.Case, async: false

  alias GenAgent.Support.TestAgent

  defp start_agent do
    name = "list-#{System.unique_integer([:positive])}"
    {:ok, pid} = GenAgent.start_agent(TestAgent, name: name, backend: GenAgent.Backends.Mock)

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    {name, pid}
  end

  test "list/0 returns an empty list when no agents are registered" do
    assert GenAgent.list() == []
  end

  test "list/0 returns the name and pid of each running agent" do
    agents = for _ <- 1..3, do: start_agent()

    assert Enum.sort(GenAgent.list()) == Enum.sort(agents)
  end

  test "list/0 omits an agent after stop/1" do
    {stopped, _pid} = start_agent()
    kept = start_agent()

    assert :ok = GenAgent.stop(stopped)
    assert GenAgent.list() == [kept]
  end

  test "list/0 omits a dead pid before Registry removes its entry" do
    {name, pid} = start_agent()

    [{_, partition, :worker, [Registry.Partition]}] =
      Supervisor.which_children(GenAgent.Registry)

    :ok = :sys.suspend(partition)

    try do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # Registry's ETS row persists until the suspended partition handles DOWN.
      assert [{^pid, _}] = Registry.lookup(GenAgent.Registry, name)
      assert GenAgent.list() == []
    after
      :ok = :sys.resume(partition)
    end
  end
end
