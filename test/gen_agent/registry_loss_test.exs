defmodule GenAgent.RegistryLossTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Support.TestAgent

  test "a Registry partition crash stops globally and caller-owned agents" do
    global_name = {:registry_loss, make_ref()}
    caller_name = {:registry_loss, make_ref()}

    {:ok, global_pid} =
      GenAgent.start_agent(TestAgent, name: global_name, backend: Mock, notify_pid: self())

    task_supervisor = start_supervised!({Task.Supervisor, name: unique_name(:tasks)})
    agent_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    {:ok, caller_pid} =
      DynamicSupervisor.start_child(
        agent_supervisor,
        GenAgent.child_spec(TestAgent,
          name: caller_name,
          backend: Mock,
          notify_pid: self(),
          task_supervisor: task_supervisor
        )
      )

    global_monitor = Process.monitor(global_pid)
    caller_monitor = Process.monitor(caller_pid)

    [{_, partition, _, _}] = Supervisor.which_children(GenAgent.Registry)
    Process.exit(partition, :kill)

    assert_receive {:DOWN, ^global_monitor, :process, ^global_pid, {:shutdown, :registry_lost}},
                   2_000

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller_pid, {:shutdown, :registry_lost}},
                   2_000

    assert_receive {:test_agent, :terminate_agent, {:shutdown, :registry_lost}}
    assert_receive {:test_agent, :terminate_agent, {:shutdown, :registry_lost}}
    assert GenAgent.whereis(global_name) == nil
    assert GenAgent.whereis(caller_name) == nil

    assert_registry_partition_restarted(partition)

    assert {:ok, fresh_pid} =
             GenAgent.start_agent(TestAgent, name: global_name, backend: Mock)

    assert fresh_pid != global_pid
    assert :ok = GenAgent.stop(global_name)

    assert {:ok, fresh_caller_pid} =
             DynamicSupervisor.start_child(
               agent_supervisor,
               GenAgent.child_spec(TestAgent,
                 name: caller_name,
                 backend: Mock,
                 task_supervisor: task_supervisor
               )
             )

    assert fresh_caller_pid != caller_pid
    assert :ok = GenAgent.stop(caller_name, agent_supervisor)
  end

  test "an orderly Registry restart does not strand globally supervised agents" do
    name = {:registry_restart, make_ref()}
    {:ok, pid} = GenAgent.start_agent(TestAgent, name: name, backend: Mock)
    monitor = Process.monitor(pid)

    try do
      assert :ok = Supervisor.terminate_child(GenAgent.Supervisor, GenAgent.Registry)

      assert_receive {:DOWN, ^monitor, :process, ^pid, {:shutdown, :registry_lost}},
                     2_000
    after
      assert {:ok, _} = Supervisor.restart_child(GenAgent.Supervisor, GenAgent.Registry)
    end

    assert GenAgent.whereis(name) == nil
    assert {:ok, fresh_pid} = GenAgent.start_agent(TestAgent, name: name, backend: Mock)
    assert fresh_pid != pid
    assert :ok = GenAgent.stop(name)
  end

  test "Registry loss cancels an active prompt task" do
    parent = self()
    name = {:registry_active, make_ref()}

    blocking_script = fn _prompt ->
      send(parent, {:prompt_task, self()})

      receive do
        :unblock -> []
      end
    end

    {:ok, agent_pid} =
      GenAgent.start_agent(TestAgent, name: name, backend: Mock, scripts: [blocking_script])

    agent_monitor = Process.monitor(agent_pid)

    spawn(fn ->
      result =
        try do
          GenAgent.ask(name, "work")
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:ask_result, result})
    end)

    assert_receive {:prompt_task, task_pid}
    task_monitor = Process.monitor(task_pid)
    [{_, partition, _, _}] = Supervisor.which_children(GenAgent.Registry)
    Process.exit(partition, :kill)

    assert_receive {:DOWN, ^agent_monitor, :process, ^agent_pid, {:shutdown, :registry_lost}},
                   2_000

    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, _}, 2_000
    assert_receive {:ask_result, {:exit, _}}, 2_000
    assert GenAgent.whereis(name) == nil
    assert_registry_partition_restarted(partition)
  end

  defp assert_registry_partition_restarted(old_partition, attempts \\ 200)

  defp assert_registry_partition_restarted(_old_partition, 0) do
    flunk("Registry partition did not restart")
  end

  defp assert_registry_partition_restarted(old_partition, attempts) do
    case Supervisor.which_children(GenAgent.Registry) do
      [{_, new_partition, _, _}]
      when is_pid(new_partition) and new_partition != old_partition ->
        assert Process.alive?(new_partition)

      _ ->
        Process.sleep(10)
        assert_registry_partition_restarted(old_partition, attempts - 1)
    end
  end

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
