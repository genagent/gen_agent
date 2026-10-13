defmodule GenAgentEnsemble.Strategies.SupervisorLifecycleTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend, TestAgent}
  alias GenAgentEnsemble.Strategies.Supervisor, as: SupStrat

  defmodule BlockingWorker do
    @moduledoc false
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, Keyword.take(opts, [:scripts]), %{observer: opts[:observer]}}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}

    # Runs when the ensemble stops the worker. The bounded wait means a
    # failing test can never leave the session stuck behind this callback.
    @impl true
    def terminate_agent(reason, state) do
      send(state.observer, {:worker_stopping, self(), reason})

      receive do
        :release_worker -> :ok
      after
        3_000 -> :ok
      end
    end
  end

  setup do
    name = "sup-life-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # Release first so the session can finish shutting down.
      for worker <- ["#{name}/#{name}-w-1", "#{name}/worker-1"],
          pid = GenAgent.whereis(worker),
          do: send(pid, :release_worker)

      try do
        Ensemble.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    %{name: name}
  end

  defp await_poll(name, token, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    case Ensemble.poll(name, token) do
      {:ok, :pending} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_poll(name, token, deadline)
        else
          flunk("token #{inspect(token)} did not complete")
        end

      other ->
        other
    end
  end

  defp await_phase(name, phase, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    {:ok, status} = Ensemble.status(name)

    cond do
      status.phase == phase ->
        status

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        await_phase(name, phase, deadline)

      true ->
        flunk("session did not reach #{inspect(phase)}; got #{inspect(status.phase)}")
    end
  end

  test "reply is delivered before blocked worker cleanup is released", %{name: name} do
    coord_script = [Event.new(:result, %{text: "a"})]
    coord = {"#{name}-coord", TestAgent, [backend: Mock, scripts: [coord_script]]}

    worker =
      {"#{name}-w", BlockingWorker,
       [
         backend: Mock,
         observer: self(),
         scripts: [fn prompt -> [Event.new(:result, %{text: "did #{prompt}"})] end]
       ]}

    {:ok, _} =
      Ensemble.start_link(
        name: name,
        strategy: SupStrat,
        opts: [
          coordinator: coord,
          worker_template: worker,
          decomposer: &String.split(&1, "\n", trim: true)
        ]
      )

    task = Task.async(fn -> Ensemble.ask(name, "q", timeout: 5_000) end)

    try do
      # The worker's terminate_agent stays blocked until released below, so
      # this reply can only arrive if it was emitted before the stop op.
      reply = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
      assert {:ok, {:ok, response}} = reply
      assert response.text == "### a\n\ndid a"

      assert_receive {:worker_stopping, worker_pid, :shutdown}, 2_000
      assert Process.alive?(worker_pid)
      ref = Process.monitor(worker_pid)

      send(worker_pid, :release_worker)
      assert_receive {:DOWN, ^ref, :process, ^worker_pid, _}, 2_000

      assert %{agents: agents} = await_agents(name, ["#{name}-coord"])
      assert agents == ["#{name}-coord"]
    after
      for worker <- ["#{name}/#{name}-w-1"],
          pid = GenAgent.whereis(worker),
          do: send(pid, :release_worker)
    end
  end

  defp await_agents(name, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    {:ok, status} = Ensemble.status(name)

    cond do
      Enum.sort(status.agents) == Enum.sort(expected) ->
        status

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        await_agents(name, expected, deadline)

      true ->
        flunk("agents did not become #{inspect(expected)}; got #{inspect(status.agents)}")
    end
  end

  test "death of a completed worker retains the result and queued run", %{name: name} do
    coordinator =
      {"coordinator", ControlledAgent,
       [backend: ControlledBackend, observer: self(), tag: "coordinator"]}

    worker =
      {"worker", ControlledAgent, [backend: ControlledBackend, observer: self(), tag: "worker"]}

    {:ok, _} =
      Ensemble.start_link(
        name: name,
        strategy: SupStrat,
        opts: [
          coordinator: coordinator,
          worker_template: worker,
          decomposer: &String.split(&1, "\n", trim: true)
        ]
      )

    {:ok, first} = Ensemble.tell(name, "first")
    assert_receive {:controlled_prompt, "coordinator", "first", coordinator1}, 2_000
    {:ok, second} = Ensemble.tell(name, "second")

    send(coordinator1, {:result, "one\ntwo"})
    assert_receive {:controlled_prompt, "worker", "one", worker1_task}, 2_000
    assert_receive {:controlled_prompt, "worker", "two", worker2_task}, 2_000

    # worker-2 finishes, then dies while worker-1 is still pending.
    send(worker2_task, {:result, "TWO"})
    assert %{phase: {:fanning_out, 1, 2}} = await_phase(name, {:fanning_out, 1, 2})

    [{worker2, _}] = Registry.lookup(GenAgent.Registry, "#{name}/worker-2")
    ref = Process.monitor(worker2)
    Process.exit(worker2, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker2, _}, 2_000

    # The run and queue survive the completed worker's death.
    # Synchronize with the Server's own DOWN handling, not only this test's
    # monitor: otherwise the phase could still be the pre-death state.
    await_agents(name, ["coordinator", "worker-1"])
    assert %{phase: {:fanning_out, 1, 2}, queued: 1} = await_phase(name, {:fanning_out, 1, 2})
    assert {:ok, :pending} = Ensemble.poll(name, first)

    send(worker1_task, {:result, "ONE"})
    assert {:ok, :completed, response} = await_poll(name, first)
    assert response.text == "### one\n\nONE\n\n### two\n\nTWO"

    # The queued request then runs normally.
    assert_receive {:controlled_prompt, "coordinator", "second", coordinator2}, 2_000
    send(coordinator2, {:result, "next"})
    assert_receive {:controlled_prompt, "worker", "next", next_task}, 2_000
    send(next_task, {:result, "NEXT"})
    assert {:ok, :completed, response} = await_poll(name, second)
    assert response.text == "### next\n\nNEXT"
  end
end
