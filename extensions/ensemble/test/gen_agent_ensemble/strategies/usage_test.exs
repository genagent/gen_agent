defmodule GenAgentEnsemble.Strategies.UsageTest do
  use ExUnit.Case, async: true

  alias GenAgent.Event
  alias GenAgent.Response
  alias GenAgentEnsemble.Strategies.Consensus
  alias GenAgentEnsemble.Strategies.Debate
  alias GenAgentEnsemble.Strategies.Pipeline
  alias GenAgentEnsemble.Strategies.Supervisor

  # Exercise the strategy callbacks with completed backend turns. No processes
  # or sleeps are needed to deterministically test fresh and queued run starts.
  defp response(text, usage) do
    events = if is_nil(usage), do: [], else: [Event.new(:usage, usage)]
    Response.from_events(events ++ [Event.new(:result, %{text: text})])
  end

  defp init(strategy, overrides \\ []) do
    specs = [{"a", StubAgent, []}, {"b", StubAgent, []}]

    opts =
      case strategy do
        Debate ->
          [agents: specs, rounds: 4]

        Pipeline ->
          [stages: specs ++ [{"c", StubAgent, []}]]

        Consensus ->
          [agents: specs, rounds: 2, verdict_parser: &parse/1]

        Supervisor ->
          [
            coordinator: {"a", StubAgent, []},
            worker_template: {"worker", StubAgent, []},
            decomposer: fn _ -> ["one", "two"] end
          ]
      end

    {:ok, state, _} = strategy.init(Keyword.merge(opts, overrides))
    state
  end

  defp parse("yes"), do: {:ok, :yes, "agreed"}
  defp parse("no"), do: {:ok, :no, "disagreed"}
  defp parse(_), do: :error

  defp turns(Debate), do: [{"a", "yes"}, {"b", "no"}, {"a", "yes"}, {"b", "yes"}]
  defp turns(Pipeline), do: [{"a", "first"}, {"b", "middle"}, {"c", "last"}]
  defp turns(Consensus), do: [{"a", "yes"}, {"b", "no"}, {"a", "yes"}, {"b", "yes"}]
  defp turns(Supervisor), do: [{"a", "plan"}, {"worker-2", "two"}, {"worker-1", "one"}]

  defp complete(strategy, state, turns, usage_fun) do
    Enum.reduce(turns, {[], state}, fn {agent, text}, {ops, state} ->
      {:ok, next_ops, next_state} =
        strategy.handle_response(agent, response(text, usage_fun.(agent)), state)

      {ops ++ next_ops, next_state}
    end)
  end

  defp reply(ops, token) do
    assert [{:reply, ^token, response}] =
             Enum.filter(ops, &match?({:reply, ^token, _}, &1))

    response
  end

  for strategy <- [Debate, Pipeline, Consensus, Supervisor] do
    @strategy strategy

    test "#{inspect(strategy)} totals every turn and resets fresh and queued invocations" do
      strategy = @strategy
      {:ok, _, state} = strategy.handle_ask("first", [], "1", init(strategy))
      {:ok, [], state} = strategy.handle_ask("queued", [], "2", state)

      {ops, state} =
        complete(strategy, state, turns(strategy), fn _ ->
          %{input_tokens: 3, output_tokens: 2, model: "ignored"}
        end)

      expected_agents =
        turns(strategy)
        |> Enum.frequencies_by(&elem(&1, 0))
        |> Map.new(fn {agent, n} -> {agent, %{input_tokens: 3 * n, output_tokens: 2 * n}} end)

      assert reply(ops, "1").usage == %{
               input_tokens: 3 * length(turns(strategy)),
               output_tokens: 2 * length(turns(strategy)),
               by_agent: expected_agents
             }

      {ops, state} = complete(strategy, state, turns(strategy), fn _ -> nil end)
      assert reply(ops, "2").usage == nil

      {:ok, _, state} = strategy.handle_ask("fresh", [], "3", state)
      {ops, state} = complete(strategy, state, turns(strategy), fn _ -> %{output_tokens: 1} end)
      assert reply(ops, "3").usage.output_tokens == length(turns(strategy))

      {:ok, _, state} = strategy.handle_ask("fresh without usage", [], "4", state)
      {ops, _} = complete(strategy, state, turns(strategy), fn _ -> nil end)
      assert reply(ops, "4").usage == nil
    end

    for queued? <- [false, true] do
      @queued queued?
      test "#{inspect(strategy)} resets after error (queued: #{queued?})" do
        strategy = @strategy
        [{first, text} | [{failed, _} | _]] = turns(strategy)
        {:ok, _, state} = strategy.handle_ask("failed run", [], "1", init(strategy))

        {:ok, _, state} =
          strategy.handle_response(first, response(text, %{input_tokens: 99}), state)

        state =
          if @queued do
            {:ok, [], state} = strategy.handle_ask("next", [], "2", state)
            state
          else
            state
          end

        {:ok, ops, state} = strategy.handle_error(failed, :boom, state)
        assert Enum.any?(ops, &match?({:reply_error, "1", _}, &1))

        state =
          if @queued do
            state
          else
            {:ok, _, state} = strategy.handle_ask("next", [], "2", state)
            state
          end

        {ops, _} = complete(strategy, state, turns(strategy), fn _ -> nil end)
        assert reply(ops, "2").usage == nil
      end
    end
  end

  test "Debate counts only completed turns on early convergence for every reply mode" do
    for kind <- [:transcript, :last, {:synthesize, fn _ -> "summary" end}] do
      state = init(Debate, reply: kind, converge: fn _ -> true end)
      {:ok, _, state} = Debate.handle_ask("start", [], "1", state)

      {ops, _} =
        complete(Debate, state, Enum.take(turns(Debate), 2), fn _ -> %{input_tokens: 5} end)

      assert reply(ops, "1").usage == %{
               input_tokens: 10,
               by_agent: %{"a" => %{input_tokens: 5}, "b" => %{input_tokens: 5}}
             }

      refute Enum.any?(ops, &(match?({:dispatch, _, _, _}, &1) and elem(&1, 1) == "a"))
    end
  end

  test "Pipeline skips missing usage and preserves the final response's other fields" do
    {:ok, _, state} = Pipeline.handle_ask("start", [], "1", init(Pipeline))
    {:ok, _, state} = Pipeline.handle_response("a", response("first", %{input_tokens: 4}), state)
    {:ok, _, state} = Pipeline.handle_response("b", response("middle", nil), state)
    last = %{response("last", %{output_tokens: 7}) | session_id: "session", duration_ms: 42}
    {:ok, ops, _} = Pipeline.handle_response("c", last, state)
    result = reply(ops, "1")

    assert result.usage == %{
             input_tokens: 4,
             output_tokens: 7,
             by_agent: %{"a" => %{input_tokens: 4}, "c" => %{output_tokens: 7}}
           }

    assert %{result | usage: last.usage, metadata: last.metadata} == last
    assert List.last(result.metadata.pipeline.stages) == {"c", last}
    assert result.metadata.pipeline.total_duration_ms == 42
  end

  test "Consensus counts abstains and both rounds in a divergence and custom synthesis" do
    for opts <- [[], [reply: {:synthesize, fn summary -> Atom.to_string(summary.status) end}]] do
      {:ok, _, state} = Consensus.handle_ask("start", [], "1", init(Consensus, opts))
      turns = [{"a", "yes"}, {"b", "abstain"}, {"b", "no"}, {"a", "yes"}]
      {ops, _} = complete(Consensus, state, turns, fn _ -> %{output_tokens: 2} end)
      result = reply(ops, "1")

      assert result.usage == %{
               output_tokens: 8,
               by_agent: %{"a" => %{output_tokens: 4}, "b" => %{output_tokens: 4}}
             }

      assert String.downcase(result.text) =~ "diverged"
    end
  end

  test "Supervisor empty decomposition counts coordinator once and preserves its response" do
    state = init(Supervisor, decomposer: fn _ -> [] end)
    {:ok, _, state} = Supervisor.handle_ask("start", [], "1", state)
    coordinator = response("nothing to do", %{input_tokens: 6})
    {:ok, ops, _} = Supervisor.handle_response("a", coordinator, state)
    result = reply(ops, "1")
    assert result.usage == %{input_tokens: 6, by_agent: %{"a" => %{input_tokens: 6}}}
    assert %{result | usage: coordinator.usage} == coordinator
  end
end
