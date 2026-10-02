defmodule GenAgent.WhereisTest do
  use ExUnit.Case, async: false

  test "whereis/1 ignores a dead pid before Registry removes its entry" do
    name = "whereis-dead-#{System.unique_integer([:positive])}"
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(GenAgent.Registry, name, nil)
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    assert_receive :registered
    assert GenAgent.whereis(name) == pid

    [{_, partition, :worker, [Registry.Partition]}] =
      Supervisor.which_children(GenAgent.Registry)

    :ok = :sys.suspend(partition)

    try do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # Registry's ETS row persists until the suspended partition handles DOWN.
      assert [{^pid, nil}] = Registry.lookup(GenAgent.Registry, name)
      assert GenAgent.whereis(name) == nil
      assert Registry.whereis_name({GenAgent.Registry, name}) == :undefined
    after
      :ok = :sys.resume(partition)
    end
  end
end
