# Compile the copyable modules directly from the guide, avoiding a second implementation.
guide = Path.expand("../../guides/patterns/pool.md", __DIR__)

for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
    String.starts_with?(code, ["defmodule Pool.Worker do", "defmodule Pool do"]) do
  Code.compile_string(code, guide)
end

defmodule GenAgent.PoolGuideTest do
  use ExUnit.Case, async: false

  defmodule Backend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(_opts), do: {:ok, Process.whereis(GenAgent.PoolGuideTest)}

    @impl true
    def prompt(observer, "hold:" <> _ = prompt) do
      send(observer, {:started, prompt, self()})

      receive do
        :release -> result(observer, prompt)
      after
        5_000 -> {:error, :fixture_deadline}
      end
    end

    def prompt(_observer, "fail"), do: {:error, :controlled_failure}
    def prompt(observer, prompt), do: result(observer, prompt)

    defp result(observer, prompt) do
      {:ok, [GenAgent.Event.new(:result, %{text: prompt})], observer}
    end

    @impl true
    def terminate_session(_session), do: :ok
  end

  setup do
    Process.register(self(), __MODULE__)
    :ok
  end

  defp start_pool(size, opts \\ []) do
    assert {:ok, pool} = Pool.start(size, [backend: Backend] ++ opts)

    on_exit(fn ->
      Enum.each(pool.workers, &stop_worker/1)
    end)

    pool
  end

  defp stop_worker(worker) do
    if GenAgent.whereis(worker), do: GenAgent.stop(worker)
  end

  test "count overload is returned and submit_many preserves every admission outcome" do
    pool = start_pool(1, max_pending_prompts: 1)
    assert {:ok, {worker, first_ref}} = Pool.submit(pool, "hold:first")
    assert_receive {:started, "hold:first", task}, 1_000

    assert [
             {"queued", {:ok, {^worker, queued_ref}}},
             {"rejected", {:error, {:overloaded, %{limit: :count}}}}
           ] = Pool.submit_many(pool, ["queued", "rejected"])

    assert {:error, {:overloaded, %{limit: :count}}} = Pool.submit(pool, "also rejected")
    assert {:error, :timeout} = Pool.wait_for_all(pool, 0)
    send(task, :release)
    assert :ok = Pool.wait_for_all(pool, 2_000)

    assert [%{count: 2, results: results}] = Pool.results(pool)

    assert Enum.map(results, &{&1.task, &1.ref, &1.status}) ==
             [{"hold:first", first_ref, :ok}, {"queued", queued_ref, :ok}]
  end

  test "byte overload uses the configured pending byte limit" do
    pool = start_pool(1, max_pending_prompt_bytes: :erlang.external_size("small"))
    assert {:ok, _} = Pool.submit(pool, "hold:active")
    assert_receive {:started, "hold:active", task}, 1_000
    assert {:ok, _} = Pool.submit(pool, "small")
    assert {:error, {:overloaded, %{limit: :bytes}}} = Pool.submit(pool, "x")
    send(task, :release)
    assert :ok = Pool.wait_for_all(pool, 2_000)
  end

  test "failed turns retain prompt and distinct refs and the worker keeps serving" do
    pool = start_pool(1)
    submissions = Pool.submit_many(pool, ["fail", "fail", "success"])
    assert :ok = Pool.wait_for_all(pool, 2_000)
    assert [%{count: 3, results: [first, second, third]}] = Pool.results(pool)
    assert %{task: "fail", status: :error, reason: :controlled_failure} = first
    assert %{task: "fail", status: :error, reason: :controlled_failure} = second
    assert first.ref != second.ref
    assert %{task: "success", status: :ok, text: "success"} = third

    assert Enum.map(submissions, fn {_, {:ok, {_, ref}}} -> ref end) ==
             Enum.map([first, second, third], & &1.ref)
  end

  test "concurrent dispatch allocates equal shares and starts at the first worker" do
    pool = start_pool(4)

    Enum.each(pool.workers, fn worker ->
      assert {:ok, {^worker, _}} = Pool.submit(pool, "hold:worker")
      assert_receive {:started, "hold:worker", _}, 1_000
    end)

    # Hold workers so all concurrent calls queue, independent of backend speed.
    outcomes =
      1..400
      |> Task.async_stream(fn n -> Pool.submit(pool, "task-#{n}") end,
        max_concurrency: 100,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, {worker, _ref}}} -> worker end)

    assert Enum.frequencies(outcomes) == Map.new(pool.workers, &{&1, 100})

    Enum.each(pool.workers, fn worker ->
      assert GenAgent.runtime_snapshot(worker).pending_prompts == 100
    end)
  end

  test "waiting uses metadata snapshots and waits through queued work" do
    pool = start_pool(1)
    assert {:ok, _} = Pool.submit(pool, "hold:first")
    assert_receive {:started, "hold:first", first_task}, 1_000
    assert {:ok, _} = Pool.submit(pool, "hold:second")

    :erlang.trace_pattern({GenAgent, :runtime_snapshot, 1}, true, [:local])
    :erlang.trace_pattern({GenAgent, :status, 1}, true, [:local])

    on_exit(fn ->
      :erlang.trace_pattern({GenAgent, :runtime_snapshot, 1}, false, [:local])
      :erlang.trace_pattern({GenAgent, :status, 1}, false, [:local])
    end)

    waiter =
      Task.async(fn ->
        receive do
          :go -> Pool.wait_for_all(pool, 2_000)
        end
      end)

    :erlang.trace(waiter.pid, true, [:call, {:tracer, self()}])
    send(waiter.pid, :go)
    assert_receive {:trace, _, :call, {GenAgent, :runtime_snapshot, [_]}}, 1_000
    assert Task.yield(waiter, 0) == nil
    send(first_task, :release)
    assert_receive {:started, "hold:second", second_task}, 1_000
    assert Task.yield(waiter, 0) == nil
    send(second_task, :release)
    assert :ok = Task.await(waiter)
    refute_receive {:trace, _, :call, {GenAgent, :status, [_]}}
  end

  test "stopping extras terminates their processes and retains the other workers" do
    pool = start_pool(3)
    [keep | extras] = pool.workers
    pids = Enum.map(extras, &GenAgent.whereis/1)
    removed = %{pool | workers: extras}
    assert :ok = Pool.wait_for_all(removed)
    assert :ok = Pool.stop(removed)
    Enum.each(pids, fn pid -> refute Process.alive?(pid) end)
    assert Process.alive?(GenAgent.whereis(keep))
    assert {:ok, {^keep, _}} = Pool.submit(%{pool | workers: [keep]}, "still serving")
  end
end
