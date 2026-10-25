defmodule GenAgent.Delegation.Blocked do
  @behaviour GenAgent.Backend
  def start_session(opts), do: {:ok, Keyword.fetch!(opts, :owner)}

  def prompt(owner, prompt) do
    send(owner, {:started, self(), prompt})

    receive do
      :finish -> {:ok, [GenAgent.Event.new(:result, %{text: prompt})], owner}
    end
  end

  def terminate_session(_), do: :ok
end

defmodule GenAgent.DelegationTest do
  use ExUnit.Case, async: true
  alias GenAgent.Delegation, as: D

  defp manager(opts \\ []) do
    start_supervised!(
      {D, Keyword.merge([name: nil, default_backend: "echo", state_dir: nil], opts)},
      restart: :temporary
    )
  end

  defp blocked(opts \\ []) do
    manager(
      Keyword.merge(
        [
          backends: %{"echo" => GenAgent.Delegation.Blocked},
          backend_options: %{"echo" => [owner: self()]}
        ],
        opts
      )
    )
  end

  defp submit(manager, text, extra \\ %{}) do
    D.spawn_agent(Map.merge(%{"task" => text, "cwd" => File.cwd!()}, extra), manager)
  end

  defp wait(manager, ids, timeout \\ 1000),
    do: D.wait_agents(%{"task_ids" => ids, "timeout_ms" => timeout}, manager)

  test "parallel work is capped, waits do not block the manager, and cancel targets one task" do
    manager = blocked(max_running: 2)
    {:ok, a} = submit(manager, "a")
    {:ok, b} = submit(manager, "b")
    assert_receive {:started, first, "a"}
    assert_receive {:started, second, "b"}
    assert {:error, %{code: "capacity"}} = submit(manager, "overflow")
    waiter = Task.async(fn -> wait(manager, [a["task_id"], b["task_id"]]) end)
    assert {:ok, %{"tasks" => [_, _]}} = D.list_agents(%{}, manager)
    send(first, :finish)
    assert {:ok, %{"timed_out" => false, "tasks" => results}} = Task.await(waiter)
    assert Enum.find(results, &(&1["task_id"] == a["task_id"]))["status"] == "completed"

    monitor = Process.monitor(second)

    assert {:ok, %{"status" => "cancelled", "provider_settled" => false}} =
             D.cancel_agent(%{"task_id" => b["task_id"]}, manager)

    assert_receive {:DOWN, ^monitor, :process, ^second, _}
    assert {:ok, %{"tasks" => [%{"status" => "completed"}]}} = wait(manager, [a["task_id"]])

    assert {:ok, %{"status" => "cancelled"}} =
             D.cancel_agent(%{"task_id" => b["task_id"]}, manager)
  end

  test "continuation retains results and prevents branching from stale turns" do
    manager = manager()
    {:ok, first} = submit(manager, "one")
    assert {:ok, %{"tasks" => [%{"result" => "echo: one"}]}} = wait(manager, [first["task_id"]])

    {:ok, second} =
      D.continue_agent(%{"task_id" => first["task_id"], "message" => "two"}, manager)

    assert second["conversation_id"] == first["conversation_id"]

    assert {:error, %{code: "stale_task"}} =
             D.continue_agent(%{"task_id" => first["task_id"], "message" => "stale"}, manager)

    assert {:ok, %{"tasks" => [%{"result" => "echo: two"}]}} = wait(manager, [second["task_id"]])

    assert {:ok,
            %{"tasks" => [%{"result" => "echo: one"}], "errors" => [%{"task_id" => "unknown"}]}} =
             wait(manager, [first["task_id"], "unknown"])
  end

  for limit <- [5, 10] do
    test "a #{limit}-worker owner refuses overflow and reuses a settled slot" do
      limit = unquote(limit)
      manager = blocked(max_running: limit)

      tasks =
        for n <- 1..limit do
          {:ok, task} = submit(manager, "worker-#{n}")
          assert_receive {:started, pid, prompt}
          assert prompt == "worker-#{n}"
          {task, pid}
        end

      assert {:error, %{code: "capacity"}} = submit(manager, "overflow")
      refute_receive {:started, _, "overflow"}
      [{first, pid} | rest] = tasks
      send(pid, :finish)
      assert {:ok, %{"tasks" => [%{"status" => "completed"}]}} = wait(manager, [first["task_id"]])
      {:ok, replacement} = submit(manager, "replacement")
      assert_receive {:started, replacement_pid, "replacement"}
      for {_task, worker} <- rest, do: send(worker, :finish)
      send(replacement_pid, :finish)
      ids = [replacement["task_id"] | Enum.map(rest, fn {task, _} -> task["task_id"] end)]

      for id <- ids do
        assert {:ok, %{"tasks" => [%{"status" => "completed"}]}} = wait(manager, [id])
      end
    end
  end

  test "wait timeout leaves work alive and task timeout ends the request" do
    manager = blocked()
    {:ok, task} = submit(manager, "timeout", %{"timeout_secs" => 1})
    assert_receive {:started, worker, "timeout"}

    assert {:ok, %{"timed_out" => true, "tasks" => [%{"status" => "running"}]}} =
             wait(manager, [task["task_id"]], 1)

    assert Process.alive?(worker)

    assert {:ok, %{"tasks" => [%{"status" => "failed", "error_info" => %{"kind" => "timeout"}}]}} =
             wait(manager, [task["task_id"]], 2000)

    refute Process.alive?(worker)
  end

  test "manager death cleans up its owned prompt workers" do
    manager = blocked()
    {:ok, _task} = submit(manager, "owned")
    assert_receive {:started, worker, "owned"}
    monitor = Process.monitor(worker)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1000
  end

  test "unknown inputs are refused and retention capacity is enforced" do
    manager = manager(max_tasks: 1)
    assert {:error, %{code: "invalid_args"}} = submit(manager, "bad", %{"output_schema" => %{}})
    assert {:error, %{code: "invalid_args"}} = submit(manager, "bad", %{"cwd" => "."})
    {:ok, task} = submit(manager, "retained")
    wait(manager, [task["task_id"]])
    assert {:error, %{code: "capacity"}} = submit(manager, "extra")
  end
end
