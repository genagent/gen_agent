defmodule GenAgentEnsemble.Strategies.FailureContractTest do
  use ExUnit.Case, async: false

  alias GenAgent.Response
  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend, TestAgent}
  alias GenAgentEnsemble.Strategies.{Consensus, Debate, Failure}
  alias GenAgentEnsemble.Strategies.Supervisor, as: Sup

  defp opts(Debate), do: [agents: [{"a", TestAgent, []}, {"b", TestAgent, []}]]

  defp opts(Consensus) do
    [
      agents: [{"a", TestAgent, []}, {"b", TestAgent, []}],
      verdict_parser: fn text -> {:ok, :yes, text} end
    ]
  end

  defp opts(Sup) do
    [
      coordinator: {"c", TestAgent, []},
      worker_template: {"w", TestAgent, [backend: GenAgent.Backends.Mock]},
      decomposer: fn _ -> ["one", "two"] end
    ]
  end

  defp init(strategy, extra \\ []) do
    {:ok, state, _} = strategy.init(Keyword.merge(opts(strategy), extra))
    state
  end

  defp start(strategy, extra \\ []) do
    state = init(strategy, Keyword.put_new(extra, :failure_reply, :structured))
    {:ok, _, state} = strategy.handle_tell("question", [], :first, state)
    state
  end

  defp response(strategy, agent, text, state),
    do: strategy.handle_response(agent, %Response{text: text}, state)

  defp entry(agent, phase, index, text),
    do: %{agent: agent, phase: phase, index: index, text: text}

  defp failure(ops, token \\ :first) do
    assert {:reply_error, ^token, %Failure{} = failure} =
             Enum.find(ops, &match?({:reply_error, ^token, _}, &1))

    failure
  end

  test "invalid option is rejected by each strategy at init" do
    for strategy <- [Debate, Consensus, Sup] do
      assert_raise ArgumentError, ":failure_reply must be :legacy or :structured", fn ->
        init(strategy, failure_reply: :invalid)
      end
    end
  end

  test "default and explicit legacy have identical operations and errors" do
    for strategy <- [Debate, Consensus, Sup] do
      implicit = init(strategy)
      explicit = init(strategy, failure_reply: :legacy)
      assert implicit == explicit
      {:ok, ops, implicit} = strategy.handle_tell("q", [], :first, implicit)
      {:ok, explicit_ops, explicit} = strategy.handle_tell("q", [], :first, explicit)
      assert ops == explicit_ops
      assert implicit == explicit
      agent = if strategy == Sup, do: "c", else: "a"

      assert strategy.handle_error(agent, :boom, implicit) ==
               strategy.handle_error(agent, :boom, explicit)

      assert strategy.handle_dispatch_rejected(agent, :first, :missing, implicit) ==
               strategy.handle_dispatch_rejected(agent, :first, :missing, explicit)
    end

    state = start(Debate, failure_reply: :legacy)
    assert {:ok, [{:reply_error, :first, :boom}], _} = Debate.handle_error("a", :boom, state)
    state = start(Consensus, failure_reply: :legacy, threshold: :unanimous)

    assert {:ok, [{:reply_error, :first, {"a", :boom}}], _} =
             Consensus.handle_error("a", :boom, state)

    state = start(Sup, failure_reply: :legacy)
    assert {:ok, [{:reply_error, :first, :boom}], _} = Sup.handle_error("c", :boom, state)
    {:ok, _, state} = response(Sup, "c", "plan", state)
    {:ok, ops, _} = Sup.handle_error("w-2", :boom, state)
    assert List.last(ops) == {:reply_error, :first, {"w-2", :boom}}
  end

  test "Debate retains completed turns before backend failure and isolates successor" do
    state = start(Debate)
    {:ok, [], state} = Debate.handle_tell("next", [], :next, state)
    {:ok, _, state} = response(Debate, "a", "first text", state)
    {:ok, ops, state} = Debate.handle_error("b", :boom, state)

    assert failure(ops) == %Failure{
             strategy: Debate,
             phase: :turn,
             agent: "b",
             reason: :boom,
             partial: [entry("a", :turn, 1, "first text")]
           }

    assert List.last(ops) == {:dispatch, "a", "next", :next}
    {:ok, ops, _} = Debate.handle_error("a", :again, state)
    assert failure(ops, :next).partial == []
  end

  test "Debate callback errors include the latest response and complete synthesis inputs" do
    state = start(Debate, converge: fn _ -> throw(:secret) end)
    {:ok, _, state} = response(Debate, "a", "one", state)
    {:ok, ops, _} = response(Debate, "b", "two", state)

    assert %Failure{
             phase: :converge,
             agent: "b",
             reason: {:strategy_function_failed, :converge, :throw, :other}
           } = failure(ops)

    assert failure(ops).partial == [entry("a", :turn, 1, "one"), entry("b", :turn, 2, "two")]

    state =
      start(Debate,
        rounds: 2,
        reply:
          {:synthesize,
           fn inputs ->
             assert inputs == [{"a", "one"}, {"b", "two"}]
             :malformed
           end}
      )

    {:ok, _, state} = response(Debate, "a", "one", state)
    {:ok, ops, _} = response(Debate, "b", "two", state)

    assert %Failure{
             phase: :synthesizer_reply,
             agent: nil,
             reason: {:invalid_strategy_result, :synthesizer_reply}
           } = failure(ops)

    assert length(failure(ops).partial) == 2
  end

  test "Consensus retains earlier rounds in configured order and excludes tolerated errors" do
    agents = for name <- ["a", "b", "c"], do: {name, TestAgent, []}

    parser = fn
      "bad" -> :malformed
      "A1" -> {:ok, :yes, "A1"}
      text -> {:ok, :no, text}
    end

    state = start(Consensus, agents: agents, verdict_parser: parser, threshold: {:at_least, 1})
    {:ok, [], state} = response(Consensus, "b", "B1", state)
    {:ok, [], state} = Consensus.handle_error("c", :tolerated, state)
    {:ok, ops, state} = response(Consensus, "a", "A1", state)
    assert Enum.all?(ops, &match?({:dispatch, _, _, :first}, &1))
    {:ok, [], state} = response(Consensus, "b", "B2", state)
    {:ok, ops, _} = response(Consensus, "a", "bad", state)

    assert %Failure{
             phase: :verdict_parser,
             agent: "a",
             reason: {:invalid_strategy_result, :verdict_parser}
           } = failure(ops)

    assert failure(ops).partial == [
             entry("a", :turn, 1, "A1"),
             entry("b", :turn, 1, "B1"),
             entry("a", :turn, 2, "bad"),
             entry("b", :turn, 2, "B2")
           ]
  end

  test "Consensus terminal turn failure retains successful text and first original error" do
    state = start(Consensus, threshold: :unanimous)
    {:ok, [], state} = response(Consensus, "b", "completed", state)
    {:ok, ops, state} = Consensus.handle_error("a", :boom, state)

    assert %Failure{
             phase: :turn,
             agent: "a",
             reason: {"a", :boom},
             partial: [%{text: "completed"}]
           } = failure(ops)

    assert state.phase == :idle
    assert state.partial == []
  end

  test "Consensus synthesis failure includes all completed inputs, ordered by agent" do
    state =
      start(Consensus,
        reply:
          {:synthesize,
           fn summary ->
             assert Enum.map(summary.responses, &elem(&1, 0)) == ["a", "b"]
             exit(:secret)
           end}
      )

    {:ok, [], state} = response(Consensus, "b", "B", state)
    {:ok, ops, _} = response(Consensus, "a", "A", state)

    assert %Failure{
             phase: :synthesizer_reply,
             agent: nil,
             reason: {:strategy_function_failed, :synthesizer_reply, :exit, :other}
           } = failure(ops)

    assert failure(ops).partial == [entry("a", :turn, 1, "A"), entry("b", :turn, 1, "B")]
  end

  test "Supervisor worker failure retains coordinator plus numeric completed worker order" do
    state =
      start(Sup,
        decomposer: fn _ -> Enum.map(1..12, &Integer.to_string/1) end,
        max_subtasks: 12
      )

    {:ok, _, state} = response(Sup, "c", "plan", state)
    {:ok, [], state} = response(Sup, "w-10", "ten", state)
    {:ok, [], state} = response(Sup, "w-2", "two", state)
    {:ok, ops, state} = Sup.handle_error("w-1", :boom, state)
    assert %Failure{phase: :turn, agent: "w-1", reason: {"w-1", :boom}} = failure(ops)

    assert failure(ops).partial == [
             entry("c", :coordinator, 0, "plan"),
             entry("w-2", :worker, 2, "two"),
             entry("w-10", :worker, 10, "ten")
           ]

    assert Enum.all?(Enum.drop(ops, -1), &match?({:stop, _}, &1))
    assert state.partial == []
  end

  test "Supervisor decomposition failures retain coordinator response" do
    for {extra, reason} <- [
          {[decomposer: fn _ -> raise "secret" end],
           {:strategy_function_failed, :decomposer, :error, RuntimeError}},
          {[decomposer: fn _ -> ["ok" | :bad] end], {:invalid_strategy_result, :decomposer}},
          {[max_subtasks: 1], {:too_many_subtasks, 2, 1}}
        ] do
      {:ok, ops, _} = response(Sup, "c", "plan", start(Sup, extra))

      assert failure(ops) == %Failure{
               strategy: Sup,
               phase: :decomposer,
               agent: "c",
               reason: reason,
               partial: [entry("c", :coordinator, 0, "plan")]
             }

      assert length(ops) == 1
    end
  end

  test "Supervisor synthesis replies before cleanup and successor dispatch with full inputs" do
    state =
      start(Sup,
        synthesizer: fn outputs, prompts ->
          assert outputs == [{"w-1", "one"}, {"w-2", "two"}]
          assert prompts == ["one", "two"]
          :invalid
        end
      )

    {:ok, [], state} = Sup.handle_tell("next", [], :next, state)
    {:ok, _, state} = response(Sup, "c", "plan", state)
    {:ok, [], state} = response(Sup, "w-2", "two", state)
    {:ok, ops, state} = response(Sup, "w-1", "one", state)

    assert [
             {:reply_error, :first, %Failure{}},
             {:stop, _},
             {:stop, _},
             {:dispatch, "c", "next", :next}
           ] = ops

    assert %Failure{
             phase: :synthesizer,
             agent: nil,
             reason: {:invalid_strategy_result, :synthesizer}
           } = failure(ops)

    assert failure(ops).partial == [
             entry("c", :coordinator, 0, "plan"),
             entry("w-1", :worker, 1, "one"),
             entry("w-2", :worker, 2, "two")
           ]

    {:ok, ops, _} = Sup.handle_error("c", :again, state)
    assert failure(ops, :next).partial == []
  end

  test "structured dispatch rejection terminally resets each strategy and advances queue" do
    for {strategy, agent} <- [{Debate, "a"}, {Consensus, "a"}, {Sup, "c"}] do
      state = start(strategy)
      {:ok, [], state} = strategy.handle_tell("next", [], :next, state)
      {:ok, ops, state} = strategy.handle_dispatch_rejected(agent, :first, :missing, state)

      assert %Failure{strategy: ^strategy, phase: :dispatch, agent: ^agent, partial: []} =
               failure(ops)

      assert Enum.any?(ops, &match?({:dispatch, _, "next", :next}, &1))
      {:ok, ops, unchanged} = strategy.handle_dispatch_rejected(agent, :old, :missing, state)
      assert unchanged == state
      assert failure(ops, :old).partial == []
    end
  end

  test "Consensus reachable threshold tolerates legacy dispatch rejection but structured advances queue" do
    agents = for name <- ["a", "b", "c"], do: {name, TestAgent, []}

    for mode <- [:legacy, :structured] do
      state = start(Consensus, agents: agents, threshold: :majority, failure_reply: mode)
      {:ok, [], state} = Consensus.handle_tell("next", [], :next, state)
      {:ok, [], state} = response(Consensus, "b", "completed", state)
      {:ok, ops, state} = Consensus.handle_dispatch_rejected("a", :first, :missing, state)

      case mode do
        :legacy ->
          # b's vote plus c's outstanding turn can still reach the two-vote majority.
          assert ops == []
          assert {:running, :first, "question", 1, pending} = state.phase
          assert pending["b"] == {:yes, "completed", "completed"}
          assert {nil, _, ""} = pending["a"]
          refute Map.has_key?(pending, "c")
          assert state.errors == [{"a", :missing}]
          assert Consensus.handle_status(state).queued == 1

        :structured ->
          assert ops == [
                   {:reply_error, :first,
                    %Failure{
                      strategy: Consensus,
                      phase: :dispatch,
                      agent: "a",
                      reason: {"a", :missing},
                      partial: [entry("b", :turn, 1, "completed")]
                    }},
                   {:dispatch, "a", "next", :next},
                   {:dispatch, "b", "next", :next},
                   {:dispatch, "c", "next", :next}
                 ]

          assert state.phase == {:running, :next, "next", 1, %{}}
          assert state.errors == []
          assert state.partial == []
          assert Consensus.handle_status(state).queued == 0
      end
    end
  end

  test "success, parser abstention, divergence, non-true convergence and empty decomposition survive" do
    state = start(Debate, rounds: 2, converge: fn _ -> :anything end)
    {:ok, _, state} = response(Debate, "a", "one", state)

    assert {:ok, [{:reply, :first, %Response{}}], %{phase: :idle}} =
             response(Debate, "b", "two", state)

    state = start(Consensus, rounds: 1, verdict_parser: fn _ -> :error end)
    {:ok, [], state} = response(Consensus, "a", "one", state)

    assert {:ok, [{:reply, :first, %Response{text: text}}], %{partial: []}} =
             response(Consensus, "b", "two", state)

    assert text =~ "DIVERGED"
    state = start(Sup, decomposer: fn _ -> [] end)

    assert {:ok, [{:reply, :first, %Response{text: "plan"}}], %{partial: []}} =
             response(Sup, "c", "plan", state)
  end

  test "cancellation clears journals and deaths keep legacy reasons" do
    for {strategy, agent} <- [{Debate, "a"}, {Consensus, "a"}, {Sup, "c"}] do
      state = start(strategy)

      {:ok, death_ops, _} = strategy.handle_agent_down(agent, :dead, state)

      assert {:ok, ^death_ops, _} =
               strategy.handle_agent_down(agent, :dead, %{state | failure_reply: :legacy})

      {:ok, _, state} = strategy.handle_cancel(:first, state)
      assert state.phase == :idle
      {:ok, _, state} = strategy.handle_tell("fresh", [], :fresh, state)
      {:ok, ops, _} = strategy.handle_dispatch_rejected(agent, :fresh, :missing, state)
      assert failure(ops, :fresh).partial == []
    end
  end

  test "live Consensus parser failure fences late sibling and isolates queued successor" do
    name = "failure-contract-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        Ensemble.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    agents =
      for tag <- ["a", "b"],
          do: {tag, ControlledAgent, [backend: ControlledBackend, observer: self(), tag: tag]}

    {:ok, _} =
      Ensemble.start_link(
        name: name,
        strategy: Consensus,
        opts: [
          agents: agents,
          failure_reply: :structured,
          verdict_parser: fn text -> if text == "bad", do: :invalid, else: {:ok, :yes, text} end
        ]
      )

    {:ok, first} = Ensemble.tell(name, "first")
    assert_receive {:controlled_prompt, "a", "first", a1}, 2_000
    assert_receive {:controlled_prompt, "b", "first", b1}, 2_000
    {:ok, next} = Ensemble.tell(name, "next")
    send(a1, {:result, "bad"})
    assert {:error, %Failure{partial: [%{text: "bad"}]}} = Ensemble.await(name, first, 2_000)
    assert_receive {:controlled_prompt, "a", "next", a2}, 2_000
    send(b1, {:result, "late"})
    assert_receive {:controlled_prompt, "b", "next", b2}, 2_000
    send(b2, {:result, "new"})
    # Waiting for b's completion is deterministic through the status mailbox.
    wait_responded(name)
    send(a2, {:result, "bad"})
    assert {:error, %Failure{partial: partial}} = Ensemble.await(name, next, 2_000)
    assert Enum.map(partial, & &1.text) == ["bad", "new"]
  end

  defp wait_responded(name, retries \\ 100) do
    case Ensemble.status(name) do
      {:ok, %{phase: %{responded: 1}}} ->
        :ok

      _ when retries > 0 ->
        Process.sleep(10)
        wait_responded(name, retries - 1)

      other ->
        flunk("response did not arrive: #{inspect(other)}")
    end
  end
end
