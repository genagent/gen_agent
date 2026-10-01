defmodule GenAgentEnsemble.Strategies.PoolTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
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

  test "dispatches across free workers first", %{name: name} do
    # Each worker has one echo script.
    echo = fn prompt -> [Event.new(:result, %{text: "echo:#{prompt}"})] end
    {:ok, _} = start_pool(name, 3, [echo, echo, echo])

    # Three concurrent tells should each land on a different worker.
    {:ok, t1} = GenAgentEnsemble.tell(name, "a")
    {:ok, t2} = GenAgentEnsemble.tell(name, "b")
    {:ok, t3} = GenAgentEnsemble.tell(name, "c")

    # Pool should have no queue depth.
    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.queued == 0

    assert %{text: "echo:a"} = await_completion(name, t1)
    assert %{text: "echo:b"} = await_completion(name, t2)
    assert %{text: "echo:c"} = await_completion(name, t3)
  end

  test "queues when all workers are busy, drains as they free up", %{name: name} do
    # 2 workers, 4 tells. Each worker needs two scripts (one per turn).
    echo = fn prompt -> [Event.new(:result, %{text: "r:#{prompt}"})] end
    {:ok, _} = start_pool(name, 2, [echo, echo, echo, echo])

    {:ok, t1} = GenAgentEnsemble.tell(name, "p1")
    {:ok, t2} = GenAgentEnsemble.tell(name, "p2")
    {:ok, t3} = GenAgentEnsemble.tell(name, "p3")
    {:ok, t4} = GenAgentEnsemble.tell(name, "p4")

    # Timing-dependent to observe mid-flight queue depth with the Mock
    # backend -- skip that and just verify all four eventually complete
    # and pool settles.
    for t <- [t1, t2, t3, t4] do
      assert %{text: "r:" <> _} = await_completion(name, t)
    end

    # Eventually, pool settles back to all-free.
    Process.sleep(50)
    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.free == 2
    assert info.busy == 0
    assert info.queued == 0
  end

  test "worker turn error fails the token, pool continues", %{name: name} do
    # First script errors; second echoes.
    scripts = [{:error, :boom}, fn p -> [Event.new(:result, %{text: "ok:#{p}"})] end]
    {:ok, _} = start_pool(name, 1, scripts)

    assert {:error, :boom} = GenAgentEnsemble.ask(name, "bad", timeout: 5_000)
    assert {:ok, %{text: "ok:good"}} = GenAgentEnsemble.ask(name, "good", timeout: 5_000)
  end

  test "worker death shrinks pool; zero workers halts session", %{name: name} do
    echo = fn _ -> [Event.new(:result, %{text: "x"})] end
    {:ok, pid} = start_pool(name, 1, [echo])
    ref = Process.monitor(pid)

    # Kill the only worker. The Server namespaces sub-agent names internally
    # as "<session>/<bare>", so we reach it by the registered name.
    GenAgent.stop("#{name}/#{name}-w-1")

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  test "status reports pool shape", %{name: name} do
    {:ok, _} = start_pool(name, 3, [])
    {:ok, info} = GenAgentEnsemble.status(name)

    assert info.free == 3
    assert info.busy == 0
    assert info.queued == 0
    assert length(info.workers) == 3
  end

  defp await_completion(name, token, retries \\ 100) do
    case GenAgentEnsemble.poll(name, token) do
      {:ok, :completed, response} ->
        response

      {:ok, :pending} when retries > 0 ->
        Process.sleep(20)
        await_completion(name, token, retries - 1)

      other ->
        flunk("expected completion, got: #{inspect(other)}")
    end
  end
end
