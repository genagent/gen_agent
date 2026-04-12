defmodule GenAgent.Scenarios.HeartbeatTest do
  @moduledoc """
  End-to-end scenario port of the Heartbeat pattern.

  A time-driven agent: sits idle until a synthetic `:tick` event
  arrives on a fixed interval, then decides per-tick whether the
  accumulated state is worth a turn. Mechanically close to Watcher,
  but with two properties worth locking down:

    * **State-based filtering at tick time** -- `handle_event(:tick, ...)`
      pattern-matches on agent state rather than event content, so the
      "should I dispatch" decision lives on the state guard.
    * **Notify deferral under real wall-clock timing** -- ticks that
      arrive while the agent is in `:processing` must be drained
      against post-decision state, and observations buffered in the
      same window must survive into that state. This is the only
      pattern test that exercises the deferral path via a real
      (`Process.sleep`-backed) slow mock stream.
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event

  defmodule Agent do
    @moduledoc false
    use GenAgent

    defmodule State do
      @moduledoc false
      defstruct observations: [],
                summaries: [],
                ticks: 0,
                skipped: 0,
                min_batch: 3,
                parent: nil
    end

    @impl true
    def init_agent(opts) do
      parent = Keyword.fetch!(opts, :parent)
      scripts = Keyword.get(opts, :scripts, [])
      min_batch = Keyword.get(opts, :min_batch, 3)

      {:ok, [scripts: scripts], %State{parent: parent, min_batch: min_batch}}
    end

    @impl true
    def handle_event({:observation, payload}, %State{} = state) do
      state = %{state | observations: state.observations ++ [payload]}
      send(state.parent, {:observed, payload})
      {:noreply, state}
    end

    def handle_event(:tick, %State{observations: obs, min_batch: min} = state)
        when length(obs) < min do
      state = %{state | ticks: state.ticks + 1, skipped: state.skipped + 1}
      send(state.parent, {:tick_skipped, length(obs)})
      {:noreply, state}
    end

    def handle_event(:tick, %State{observations: obs} = state) do
      state = %{state | ticks: state.ticks + 1, observations: []}
      send(state.parent, {:tick_dispatched, length(obs)})
      {:prompt, "summarize #{length(obs)} obs", state}
    end

    def handle_event(_other, state), do: {:noreply, state}

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      state = %{state | summaries: state.summaries ++ [response.text]}
      send(state.parent, {:responded, response.text})
      {:noreply, state}
    end
  end

  defp start(name, scripts, opts \\ []) do
    min_batch = Keyword.get(opts, :min_batch, 3)

    {:ok, _pid} =
      GenAgent.start_agent(Agent,
        name: name,
        backend: Mock,
        scripts: scripts,
        parent: self(),
        min_batch: min_batch
      )

    name
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp result(text), do: [Event.new(:result, %{text: text})]

  # A mock script that sleeps before yielding its result event, so
  # the agent spends real wall-clock time in `:processing`. Events
  # notified during that window exercise the deferral path.
  defp slow_result(text, sleep_ms) do
    fn _prompt ->
      Stream.resource(
        fn -> false end,
        fn
          false ->
            Process.sleep(sleep_ms)
            {[Event.new(:result, %{text: text})], true}

          true ->
            {:halt, true}
        end,
        fn _ -> :ok end
      )
    end
  end

  describe "per-tick state filtering" do
    test "tick with fewer than min_batch observations is skipped" do
      name = unique("hb")
      start(name, [result("unused")])

      GenAgent.notify(name, {:observation, %{cpu: 80}})
      assert_receive {:observed, _}, 500

      GenAgent.notify(name, :tick)
      assert_receive {:tick_skipped, 1}, 500
      refute_receive {:responded, _}, 100

      s = GenAgent.status(name).agent_state
      assert s.ticks == 1
      assert s.skipped == 1
      assert s.summaries == []
      assert length(s.observations) == 1

      GenAgent.stop(name)
    end

    test "tick with min_batch observations dispatches and resets observations" do
      name = unique("hb")
      start(name, [result("summary")])

      for n <- 1..3, do: GenAgent.notify(name, {:observation, %{n: n}})
      for _ <- 1..3, do: assert_receive({:observed, _}, 500)

      GenAgent.notify(name, :tick)

      assert_receive {:tick_dispatched, 3}, 500
      assert_receive {:responded, "summary"}, 500

      s = GenAgent.status(name).agent_state
      assert s.observations == []
      assert s.summaries == ["summary"]

      GenAgent.stop(name)
    end

    test "tick without observations is skipped" do
      name = unique("hb")
      start(name, [])

      GenAgent.notify(name, :tick)
      assert_receive {:tick_skipped, 0}, 500

      s = GenAgent.status(name).agent_state
      assert s.ticks == 1
      assert s.skipped == 1

      GenAgent.stop(name)
    end
  end

  describe "idle-until-triggered" do
    test "no turn runs until an above-threshold tick lands" do
      name = unique("hb")
      start(name, [result("only")])

      Process.sleep(50)
      assert GenAgent.status(name).state == :idle
      assert GenAgent.status(name).agent_state.summaries == []

      # Below-threshold ticks leave the agent idle.
      GenAgent.notify(name, {:observation, %{n: 1}})
      GenAgent.notify(name, :tick)
      assert_receive {:tick_skipped, 1}, 500

      # Cross the threshold.
      GenAgent.notify(name, {:observation, %{n: 2}})
      GenAgent.notify(name, {:observation, %{n: 3}})
      GenAgent.notify(name, :tick)

      assert_receive {:responded, "only"}, 500

      GenAgent.stop(name)
    end
  end

  describe "real-timer ticker" do
    test "a wall-clock ticker drives dispatches via notify" do
      name = unique("hb")
      start(name, [result("r1"), result("r2")], min_batch: 1)

      ticker =
        Task.async(fn ->
          Enum.each(1..6, fn _ ->
            Process.sleep(15)
            GenAgent.notify(name, :tick)
          end)
        end)

      GenAgent.notify(name, {:observation, %{n: 1}})
      assert_receive {:responded, "r1"}, 1_000

      GenAgent.notify(name, {:observation, %{n: 2}})
      assert_receive {:responded, "r2"}, 1_000

      Task.await(ticker)

      s = GenAgent.status(name).agent_state
      assert s.summaries == ["r1", "r2"]
      assert s.observations == []

      GenAgent.stop(name)
    end
  end

  describe "notify deferral under real-timer ticks" do
    test "observation+tick during :processing survive into post-turn state" do
      name = unique("hb")

      # min_batch: 1 so a single observation is enough to trigger a
      # dispatch. The deferred-observation mutation has to actually
      # land in state for the second tick to see obs=[:during] and
      # dispatch -- if the mutation were lost, the second tick would
      # see obs=[] and skip instead.
      start(name, [slow_result("first", 100), result("deferred")], min_batch: 1)

      GenAgent.notify(name, {:observation, %{k: :pre}})
      assert_receive {:observed, %{k: :pre}}, 500

      GenAgent.notify(name, :tick)
      assert_receive {:tick_dispatched, 1}, 500

      # Confirm we're mid-turn before firing the deferred events.
      Process.sleep(20)
      assert GenAgent.status(name).state == :processing

      # These two notifies arrive while the slow turn is still in
      # flight. The deferral guarantee: the observation's state
      # mutation survives against post-decision state, and the tick
      # is drained against that post-decision state, so it sees
      # obs=[:during] -> dispatch.
      GenAgent.notify(name, {:observation, %{k: :during}})
      GenAgent.notify(name, :tick)

      assert_receive {:responded, "first"}, 1_000
      assert_receive {:observed, %{k: :during}}, 500
      assert_receive {:tick_dispatched, 1}, 500
      assert_receive {:responded, "deferred"}, 1_000

      s = GenAgent.status(name).agent_state
      assert s.summaries == ["first", "deferred"]
      assert s.observations == []
      assert s.skipped == 0

      GenAgent.stop(name)
    end
  end
end
