defmodule GenAgentEnsemble.Strategies.PoolTest do
  use ExUnit.Case, async: false

  defmodule RejectingReplacementAgent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      start_count = Keyword.fetch!(opts, :start_count)
      initial_starts = Keyword.fetch!(opts, :initial_starts)
      attempt = Agent.get_and_update(start_count, fn count -> {count, count + 1} end)

      if attempt < initial_starts do
        {:ok, Keyword.take(opts, [:observer, :tag, :scripts]), %{}}
      else
        {:error, :replacement_blocked}
      end
    end

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.Pool
  alias GenAgentEnsemble.TestAgent

  setup do
    name = "pool-#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(name) end)
    %{name: name}
  end

  defp safe_stop(name) do
    GenAgentEnsemble.stop(name)
  catch
    :exit, _ -> :ok
  end

  defp start_pool(name, count, worker_scripts) do
    worker = {"#{name}-w", TestAgent, [backend: Mock, scripts: worker_scripts]}

    GenAgentEnsemble.start_link(
      name: name,
      strategy: Pool,
      opts: [worker_count: count, worker_template: worker]
    )
  end

  test "sequential requests rotate across every worker" do
    {:ok, state, _specs} =
      Pool.init(worker_count: 3, worker_template: {"worker", TestAgent, []})

    {workers, _state} =
      Enum.map_reduce(1..6, state, fn turn, state ->
        token = "token-#{turn}"

        {:ok, [{:dispatch, worker, _prompt, ^token}], state} =
          Pool.handle_ask("prompt-#{turn}", [], token, state)

        {:ok, [{:reply, ^token, :done}], state} = Pool.handle_response(worker, :done, state)
        {worker, state}
      end)

    assert workers == ["worker-1", "worker-2", "worker-3", "worker-1", "worker-2", "worker-3"]
  end

  test "dispatches across free workers first", %{name: name} do
    with_held_tasks(name, fn ->
      start_controlled_pool(name, 3)

      {:ok, t1} = GenAgentEnsemble.tell(name, "a")
      {:ok, t2} = GenAgentEnsemble.tell(name, "b")
      {:ok, t3} = GenAgentEnsemble.tell(name, "c")

      # All three prompts are running at once, so each landed on its own worker.
      tasks = for prompt <- ["a", "b", "c"], do: hold_prompt(prompt)
      assert tasks |> Enum.uniq() |> length() == 3

      {:ok, info} = GenAgentEnsemble.status(name)
      assert {info.free, info.busy, info.queued} == {0, 3, 0}

      for {task, prompt} <- Enum.zip(tasks, ["a", "b", "c"]) do
        send(task, {:result, "echo:#{prompt}"})
      end

      assert {:ok, %{text: "echo:a"}} = GenAgentEnsemble.await(name, t1, 5_000)
      assert {:ok, %{text: "echo:b"}} = GenAgentEnsemble.await(name, t2, 5_000)
      assert {:ok, %{text: "echo:c"}} = GenAgentEnsemble.await(name, t3, 5_000)

      {:ok, info} = GenAgentEnsemble.status(name)
      assert {info.free, info.busy, info.queued} == {3, 0, 0}
    end)
  end

  test "queues when all workers are busy, drains as they free up", %{name: name} do
    with_held_tasks(name, fn ->
      start_controlled_pool(name, 2)

      {:ok, t1} = GenAgentEnsemble.tell(name, "p1")
      task1 = hold_prompt("p1")
      {:ok, t2} = GenAgentEnsemble.tell(name, "p2")
      task2 = hold_prompt("p2")
      {:ok, t3} = GenAgentEnsemble.tell(name, "p3")
      {:ok, t4} = GenAgentEnsemble.tell(name, "p4")

      # tell/status are serialized by the ensemble, so both queued prompts are
      # visible here and neither has reached a backend.
      {:ok, info} = GenAgentEnsemble.status(name)
      assert {info.free, info.busy, info.queued} == {0, 2, 2}
      refute_received {:controlled_prompt, _, "p3", _}
      refute_received {:controlled_prompt, _, "p4", _}

      # Finish p2 before p1 (out of start order): the queue head, p3, runs next.
      send(task2, {:result, "r:p2"})
      assert {:ok, %{text: "r:p2"}} = GenAgentEnsemble.await(name, t2, 5_000)
      task3 = hold_prompt("p3")
      refute_received {:controlled_prompt, _, "p4", _}
      {:ok, info} = GenAgentEnsemble.status(name)
      assert {info.free, info.busy, info.queued} == {0, 2, 1}

      send(task1, {:result, "r:p1"})
      assert {:ok, %{text: "r:p1"}} = GenAgentEnsemble.await(name, t1, 5_000)
      task4 = hold_prompt("p4")
      {:ok, info} = GenAgentEnsemble.status(name)
      assert {info.free, info.busy, info.queued} == {0, 2, 0}

      # Release the last two in reverse of start order.
      send(task4, {:result, "r:p4"})
      assert {:ok, %{text: "r:p4"}} = GenAgentEnsemble.await(name, t4, 5_000)
      {:ok, info} = GenAgentEnsemble.status(name)
      assert {info.free, info.busy, info.queued} == {1, 1, 0}

      send(task3, {:result, "r:p3"})
      assert {:ok, %{text: "r:p3"}} = GenAgentEnsemble.await(name, t3, 5_000)
      {:ok, info} = GenAgentEnsemble.status(name)
      assert {info.free, info.busy, info.queued} == {2, 0, 0}
    end)
  end

  test "worker turn error fails the token, pool continues", %{name: name} do
    # First script errors; second echoes.
    scripts = [{:error, :boom}, fn p -> [Event.new(:result, %{text: "ok:#{p}"})] end]
    {:ok, _} = start_pool(name, 1, scripts)

    assert {:error, :boom} = GenAgentEnsemble.ask(name, "bad", timeout: 5_000)
    assert {:ok, %{text: "ok:good"}} = GenAgentEnsemble.ask(name, "good", timeout: 5_000)
  end

  test "idle worker death starts a fresh worker under the same name", %{name: name} do
    echo = fn _ -> [Event.new(:result, %{text: "x"})] end
    {:ok, _pid} = start_pool(name, 2, [echo])

    worker_name = "#{name}/#{name}-w-1"
    old_worker = GenAgent.whereis(worker_name)
    Process.exit(old_worker, :kill)
    new_worker = await_replacement(worker_name, old_worker)

    assert Process.alive?(new_worker)
    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.free == 2
    assert length(info.workers) == 2
    assert {:ok, %{text: "x"}} = GenAgentEnsemble.ask(name, "on surviving worker")
    assert {:ok, %{text: "x"}} = GenAgentEnsemble.ask(name, "on replacement")
  end

  test "busy worker death fails its token and runs queued work on replacement", %{name: name} do
    worker =
      {"#{name}-w", ControlledAgent,
       [backend: ControlledBackend, observer: self(), tag: "worker"]}

    {:ok, _pid} =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Pool,
        opts: [worker_count: 1, worker_template: worker]
      )

    {:ok, first} = GenAgentEnsemble.tell(name, "first")
    assert_receive {:controlled_prompt, "worker", "first", _first_task}, 2_000
    {:ok, second} = GenAgentEnsemble.tell(name, "second")

    worker_name = "#{name}/#{name}-w-1"
    old_worker = GenAgent.whereis(worker_name)
    Process.exit(old_worker, :kill)

    assert {:error, {:worker_down, :killed}} = await_outcome(name, first)
    assert_receive {:controlled_prompt, "worker", "second", second_task}, 2_000
    assert await_replacement(worker_name, old_worker) != old_worker

    send(second_task, {:result, "recovered"})
    assert {:ok, %{text: "recovered"}} = await_outcome(name, second)
    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.free == 1
    assert info.busy == 0
    assert info.queued == 0
  end

  test "failed replacement removes its slot while surviving workers continue", %{name: name} do
    start_count = start_supervised!({Agent, fn -> 0 end})
    echo = fn prompt -> [Event.new(:result, %{text: "echo:#{prompt}"})] end

    worker =
      {"#{name}-w", RejectingReplacementAgent,
       [backend: Mock, start_count: start_count, initial_starts: 2, scripts: [echo]]}

    {:ok, _pid} =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Pool,
        opts: [worker_count: 2, worker_template: worker]
      )

    dead_worker = "#{name}/#{name}-w-1"
    Process.exit(GenAgent.whereis(dead_worker), :kill)

    info = await_worker_count(name, 1)
    assert info.free == 1
    assert info.busy == 0
    assert info.workers == ["#{name}-w-2"]
    assert {:ok, %{text: "echo:survivor"}} = GenAgentEnsemble.ask(name, "survivor")
  end

  test "failed replacement fails queued work and halts an exhausted pool", %{name: name} do
    start_count = start_supervised!({Agent, fn -> 0 end})

    worker =
      {"#{name}-w", RejectingReplacementAgent,
       [
         backend: ControlledBackend,
         start_count: start_count,
         initial_starts: 1,
         observer: self(),
         tag: "worker"
       ]}

    {:ok, pool} =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Pool,
        opts: [worker_count: 1, worker_template: worker]
      )

    monitor = Process.monitor(pool)
    first = Task.async(fn -> GenAgentEnsemble.ask(name, "first", timeout: 5_000) end)
    assert_receive {:controlled_prompt, "worker", "first", _task}, 2_000
    second = Task.async(fn -> GenAgentEnsemble.ask(name, "second", timeout: 5_000) end)
    assert await_queued(name, 1).queued == 1

    Process.exit(GenAgent.whereis("#{name}/#{name}-w-1"), :kill)

    assert {:error, {:worker_down, :killed}} = Task.await(first, 5_000)
    assert {:error, {:worker_start_failed, _}} = Task.await(second, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^pool, :normal}, 2_000
  end

  test "status reports pool shape", %{name: name} do
    {:ok, _} = start_pool(name, 3, [])
    {:ok, info} = GenAgentEnsemble.status(name)

    assert info.free == 3
    assert info.busy == 0
    assert info.queued == 0
    assert length(info.workers) == 3
  end

  defp start_controlled_pool(name, count) do
    worker =
      {"#{name}-w", ControlledAgent,
       [backend: ControlledBackend, observer: self(), tag: "worker"]}

    {:ok, _pid} =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Pool,
        opts: [worker_count: count, worker_template: worker]
      )
  end

  # Waits for a backend to start `prompt` and records its task so it is
  # released if the test fails before sending a result.
  defp hold_prompt(prompt) do
    assert_receive {:controlled_prompt, "worker", ^prompt, task}, 2_000
    monitor = Process.monitor(task)
    Process.put(:held_tasks, [{task, monitor} | Process.get(:held_tasks, [])])
    task
  end

  # Unblocks every held or still-announced backend task on exit, including on
  # assertion failure, so no fixture waits out its timeout.
  defp with_held_tasks(name, fun) do
    fun.()
  after
    tasks = Process.get(:held_tasks, [])
    for {task, _monitor} <- tasks, do: send(task, {:error, :test_cleanup})
    # Stop dispatch before waiting for fixture exits, including after an assertion
    # fails while other work is still queued. Core termination closes its tasks.
    safe_stop(name)
    drain_prompts()

    for {task, monitor} <- tasks do
      assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, 2_000
    end

    Process.delete(:held_tasks)
  end

  defp drain_prompts do
    receive do
      {:controlled_prompt, _tag, _prompt, task} ->
        send(task, {:error, :test_cleanup})
        drain_prompts()
    after
      0 -> :ok
    end
  end

  defp await_outcome(name, token, retries \\ 100) do
    case GenAgentEnsemble.poll(name, token) do
      {:ok, :pending} when retries > 0 ->
        Process.sleep(20)
        await_outcome(name, token, retries - 1)

      {:ok, :completed, response} ->
        {:ok, response}

      other ->
        other
    end
  end

  defp await_replacement(name, old_pid, retries \\ 100) do
    case GenAgent.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when retries > 0 ->
        Process.sleep(20)
        await_replacement(name, old_pid, retries - 1)

      other ->
        flunk("expected a replacement for #{name}, got: #{inspect(other)}")
    end
  end

  defp await_worker_count(name, count, retries \\ 100) do
    {:ok, info} = GenAgentEnsemble.status(name)

    if length(info.workers) == count do
      info
    else
      if retries > 0 do
        Process.sleep(20)
        await_worker_count(name, count, retries - 1)
      else
        flunk("expected #{count} workers, got: #{inspect(info)}")
      end
    end
  end

  defp await_queued(name, count, retries \\ 100) do
    {:ok, info} = GenAgentEnsemble.status(name)

    if info.queued == count do
      info
    else
      if retries > 0 do
        Process.sleep(20)
        await_queued(name, count, retries - 1)
      else
        flunk("expected #{count} queued requests, got: #{inspect(info)}")
      end
    end
  end
end
