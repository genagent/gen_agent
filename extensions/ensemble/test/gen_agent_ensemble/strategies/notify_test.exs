defmodule GenAgentEnsemble.Strategies.NotifyTest do
  use ExUnit.Case, async: false

  # Characterizes notify/2 through the built-in strategies as they stand: Solo
  # forwards each event to its one member's handle_event/2, and every other
  # built-in strategy ignores the event without changing its state.

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.HaltSupport
  alias GenAgentEnsemble.Strategies.{Consensus, Debate, Pipeline, Pool, Solo, Switchboard}
  alias GenAgentEnsemble.Strategies.Supervisor, as: SupStrat
  alias GenAgentEnsemble.TestAgent

  @dispatch_start [:gen_agent_ensemble, :dispatch, :start]

  defmodule ObservedAgent do
    use GenAgent

    @impl true
    def init_agent(opts),
      do: {:ok, Keyword.take(opts, [:scripts]), %{observer: opts[:observer]}}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}

    @impl true
    def handle_event(event, state) do
      send(state.observer, {:member_event, self(), event})
      {:noreply, state}
    end
  end

  setup do
    name = "notify-#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(name) end)
    %{name: name}
  end

  defp safe_stop(name) do
    E.stop(name)
  catch
    :exit, _ -> :ok
  end

  defp say(text), do: fn _prompt -> [Event.new(:result, %{text: text})] end

  defp mock(scripts), do: [backend: Mock, scripts: scripts]

  # Blocks the turn when the backend consumes its stream until the test sends
  # `:release` to the pid announced as `{:reached, pid}`.
  defp gated(text) do
    test = self()

    fn _prompt ->
      Stream.flat_map([:gate], fn _ ->
        send(test, {:reached, self()})

        receive do
          :release -> :ok
        after
          5_000 -> flunk("gate was never released")
        end

        [Event.new(:result, %{text: text})]
      end)
    end
  end

  defp observe_dispatch_starts do
    ref = :telemetry_test.attach_event_handlers(self(), [@dispatch_start])
    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  # Core 0.11 reports buffered notifications in status/2. The published core
  # used by the Hex archive job only has them in runtime_snapshot/2.
  defp member_status(member_name) do
    # A variable module avoids an undefined-function warning on core 0.11.
    core = GenAgent

    if function_exported?(core, :runtime_snapshot, 2) do
      snapshot = core.runtime_snapshot(member_name, :infinity)
      %{state: snapshot.phase, pending_notifications: snapshot.pending_notifications}
    else
      GenAgent.status(member_name)
    end
  end

  # The turn stays gated throughout, so the phase must remain :processing.
  defp await_buffered_notifications(member_name, count, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    snapshot = member_status(member_name)
    assert %{state: :processing} = snapshot

    cond do
      snapshot.pending_notifications == count ->
        snapshot

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        await_buffered_notifications(member_name, count, deadline)

      true ->
        flunk("expected #{count} buffered notifications, got: #{inspect(snapshot)}")
    end
  end

  defp start_solo(name, scripts) do
    E.start_link(
      name: name,
      strategy: Solo,
      opts: [agent: {"a", ObservedAgent, [observer: self()] ++ mock(scripts)}]
    )
  end

  describe "Solo" do
    test "forwards each event, in order, to its member's handle_event/2", %{name: name} do
      {:ok, _} = start_solo(name, [say("after")])
      member = GenAgent.whereis(E.member_name(name, "a"))
      starts = observe_dispatch_starts()

      assert :ok = E.notify(name, :first)
      assert :ok = E.notify(name, {:second, %{n: 2}})

      assert_receive {:member_event, ^member, first}, 2_000
      assert_receive {:member_event, ^member, second}, 2_000
      assert [first, second] == [:first, {:second, %{n: 2}}]

      # A forward is not a dispatch: no token or turn is created for it.
      assert {:ok, %{queued_tokens: 0, pending_tokens: [], in_flight: 0}} = E.status(name)
      refute_received {@dispatch_start, ^starts, _, _}

      assert {:ok, %{text: "after"}} = E.ask(name, "prompt", timeout: 5_000)
    end

    test "an event forwarded mid-turn waits for the turn and leaves its token open",
         %{name: name} do
      {:ok, _} = start_solo(name, [gated("done")])
      member_name = E.member_name(name, "a")
      member = GenAgent.whereis(member_name)

      {:ok, token} = E.tell(name, "work")
      assert_receive {:reached, gate}, 2_000

      assert :ok = E.notify(name, :mid_turn)
      assert {:ok, %{queued_tokens: 1}} = E.status(name)

      # Core buffers notifications that arrive during a turn. The forward is a
      # cast to the member, so wait for the member to record it.
      await_buffered_notifications(member_name, 1)

      refute_received {:member_event, _, _}
      assert {:ok, :pending} = E.poll(name, token)

      send(gate, :release)
      assert {:ok, %{text: "done"}} = E.await(name, token, 5_000)
      assert_receive {:member_event, ^member, :mid_turn}, 2_000
      assert {:ok, %{queued_tokens: 0}} = E.status(name)
    end

    test "ignores notify after the member's death halts the session", %{name: name} do
      {:ok, pid} = start_solo(name, [])
      watched = HaltSupport.watch(pid)

      Process.exit(GenAgent.whereis(E.member_name(name, "a")), :kill)
      HaltSupport.assert_tree_gone(watched)
      assert {:agent_down, _} = reason = HaltSupport.assert_halted(name)

      assert :ok = E.notify(name, :after_halt)
      HaltSupport.assert_halted(name, reason)
      refute_received {:member_event, _, _}
    end
  end

  defp spec(member, text), do: {member, TestAgent, mock([say(text)])}

  # Each entry: strategy, its options, ask options and the expected reply text.
  defp ignoring_strategies do
    [
      {Pool, [worker_count: 1, worker_template: spec("w", "pooled")], [], "pooled"},
      {Switchboard, [agents: [spec("a", "routed")]], [agent: "a"], "routed"},
      {Pipeline, [stages: [spec("s1", "staged")]], [], "staged"},
      {Debate, debate_opts(), [], "b1"},
      {Consensus, consensus_opts(), [], "converged:yes"},
      {SupStrat, supervisor_opts(), [], "worked"}
    ]
  end

  defp debate_opts, do: [agents: [spec("a", "a1"), spec("b", "b1")], rounds: 2, reply: :last]

  defp consensus_opts do
    [
      agents: [spec("a", "yes"), spec("b", "yes")],
      verdict_parser: fn "yes" -> {:ok, :yes, ""} end,
      reply: {:synthesize, fn summary -> "#{summary.status}:#{summary.verdict}" end}
    ]
  end

  defp supervisor_opts do
    [
      coordinator: spec("coord", "only"),
      worker_template: spec("w", "worked"),
      decomposer: &String.split(&1, "\n", trim: true),
      synthesizer: fn outputs, _subtasks -> Enum.map_join(outputs, &elem(&1, 1)) end
    ]
  end

  describe "other built-in strategies" do
    test "handle_notify/2 returns no operations and the same state" do
      for {strategy, opts, _ask_opts, _text} <- ignoring_strategies() do
        {:ok, state, _specs} = strategy.init(opts)

        for event <- [:event, {:forward, "a", :event}, %{any: :term}] do
          assert strategy.handle_notify(event, state) == {:ok, [], state},
                 "#{inspect(strategy)} handled #{inspect(event)}"
        end
      end
    end

    test "notify through a running session leaves it idle and serving", %{name: name} do
      starts = observe_dispatch_starts()

      for {strategy, opts, ask_opts, text} <- ignoring_strategies() do
        session = "#{name}-#{strategy |> Module.split() |> List.last()}"
        on_exit(fn -> safe_stop(session) end)
        {:ok, _} = E.start_link(name: session, strategy: strategy, opts: opts)

        {:ok, before} = E.status(session)
        assert :ok = E.notify(session, :ignored)
        # notify/2 is a cast, so this later call is handled after it.
        assert E.status(session) == {:ok, before}
        refute_received {@dispatch_start, ^starts, _, %{session: ^session}}

        assert {:ok, %{text: ^text}} = E.ask(session, "prompt", [timeout: 5_000] ++ ask_opts)
        assert :ok = E.stop(session)
      end
    end
  end
end
