defmodule GenAgentEnsemble.Strategies.PipelineTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgent.Response
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.Pipeline
  alias GenAgentEnsemble.TestAgent

  setup do
    name = "pipe-#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(name) end)
    %{name: name}
  end

  defp safe_stop(name) do
    GenAgentEnsemble.stop(name)
  catch
    :exit, _ -> :ok
  end

  defp transform(tag) do
    fn prompt -> [Event.new(:result, %{text: "#{tag}(#{prompt})"})] end
  end

  defp start_pipeline(name, stage_scripts) do
    stages =
      stage_scripts
      |> Enum.with_index(1)
      |> Enum.map(fn {scripts, i} ->
        {"#{name}-s#{i}", TestAgent, [backend: Mock, scripts: scripts]}
      end)

    GenAgentEnsemble.start_link(
      name: name,
      strategy: Pipeline,
      opts: [stages: stages]
    )
  end

  test "each stage transforms the previous output", %{name: name} do
    # s1: wraps in outer(); s2: wraps in mid(); s3: wraps in inner().
    {:ok, _} =
      start_pipeline(name, [
        [transform("outer")],
        [transform("mid")],
        [transform("inner")]
      ])

    {:ok, resp} = GenAgentEnsemble.ask(name, "seed", timeout: 5_000)
    assert resp.text == "inner(mid(outer(seed)))"
  end

  test "backend usage events aggregate across stages and reset on the next ask", %{name: name} do
    script = fn usage ->
      [Event.new(:usage, usage), Event.new(:result, %{text: "done"})]
    end

    {:ok, _} =
      start_pipeline(name, [
        [script.(%{input_tokens: 10, output_tokens: 2}), transform("a")],
        [transform("b"), script.(%{input_tokens: 1})],
        [script.(%{input_tokens: 20, output_tokens: 3}), transform("c")]
      ])

    assert {:ok, first} = GenAgentEnsemble.ask(name, "first", timeout: 5_000)

    assert first.usage == %{
             input_tokens: 30,
             output_tokens: 5,
             by_agent: %{
               "#{name}-s1" => %{input_tokens: 10, output_tokens: 2},
               "#{name}-s3" => %{input_tokens: 20, output_tokens: 3}
             }
           }

    assert {:ok, second} = GenAgentEnsemble.ask(name, "second", timeout: 5_000)
    assert second.usage == %{input_tokens: 1, by_agent: %{"#{name}-s2" => %{input_tokens: 1}}}
  end

  test "queues a second tell behind the first", %{name: name} do
    {:ok, _} =
      start_pipeline(name, [
        [transform("a"), transform("a")],
        [transform("b"), transform("b")]
      ])

    {:ok, t1} = GenAgentEnsemble.tell(name, "one")
    {:ok, t2} = GenAgentEnsemble.tell(name, "two")

    assert %{text: "b(a(one))"} = await_completion(name, t1)
    assert %{text: "b(a(two))"} = await_completion(name, t2)
  end

  test "stage error fails the token with {stage, reason}", %{name: name} do
    {:ok, _} =
      start_pipeline(name, [
        [transform("s1")],
        [{:error, :midstage_boom}]
      ])

    assert {:error, {stage, :midstage_boom}} = GenAgentEnsemble.ask(name, "in", timeout: 5_000)
    assert stage == "#{name}-s2"

    # Pipeline should be idle again.
    Process.sleep(30)
    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.phase == :idle
  end

  test "stage death halts the session", %{name: name} do
    {:ok, pid} =
      start_pipeline(name, [[transform("s1")], [transform("s2")]])

    ref = Process.monitor(pid)
    Process.exit(GenAgent.whereis("#{name}/#{name}-s1"), :kill)

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  test "status reports pipeline shape", %{name: name} do
    {:ok, _} = start_pipeline(name, [[], []])
    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.phase == :idle
    assert length(info.stages) == 2
    assert info.queued == 0
  end

  defp response(text, duration, usage) do
    response =
      Response.from_events(
        [Event.new(:usage, usage), Event.new(:result, %{text: text})],
        duration_ms: duration,
        session_id: text
      )

    %{response | metadata: %{source: text, pipeline: :original}}
  end

  defp strategy_state(stages \\ ["a", "b"]) do
    {:ok, state, _} = Pipeline.init(stages: Enum.map(stages, &{&1, TestAgent, []}))
    state
  end

  test "retains ordered full responses and summed duration without changing final fields" do
    first = response("first", 17, %{input_tokens: 3})
    last = response("last", 23, %{input_tokens: 5, output_tokens: 2})
    {:ok, _, state} = Pipeline.handle_tell("seed", [], "one", strategy_state())

    assert {:ok, [{:dispatch, "b", "first", "one"}], state} =
             Pipeline.handle_response("a", first, state)

    assert {:ok, [{:reply, "one", result}], state} = Pipeline.handle_response("b", last, state)

    assert result.metadata.pipeline == %{
             stages: [{"a", first}, {"b", last}],
             total_duration_ms: 40
           }

    assert result.metadata.source == "last"
    assert %{result | usage: last.usage, metadata: last.metadata} == last

    assert result.usage == %{
             input_tokens: 8,
             output_tokens: 2,
             by_agent: %{"a" => first.usage, "b" => last.usage}
           }

    assert state.responses == []
    assert state.phase == :idle
    {:ok, _, state} = Pipeline.handle_ask("next", [], "two", state)
    fresh = %Response{text: "fresh"}
    {:ok, _, state} = Pipeline.handle_response("a", fresh, state)
    {:ok, [{:reply, "two", result}], _} = Pipeline.handle_response("b", fresh, state)

    assert result.metadata.pipeline == %{
             stages: [{"a", fresh}, {"b", fresh}],
             total_duration_ms: 0
           }

    assert result.usage == nil
  end

  test "single stage includes its original response" do
    original = response("only", 9, %{})
    {:ok, _, state} = Pipeline.handle_tell("seed", [], "one", strategy_state(["a"]))
    {:ok, [{:reply, "one", result}], state} = Pipeline.handle_response("a", original, state)
    assert result.metadata.pipeline == %{stages: [{"a", original}], total_duration_ms: 9}
    assert state.responses == []
  end

  for exit_kind <- [:error, :cancel, :rejected], queued? <- [false, true] do
    test "#{exit_kind} clears partial results with queued successor: #{queued?}" do
      {:ok, _, state} = Pipeline.handle_tell("old", [], "old", strategy_state())

      {:ok, _, state} =
        Pipeline.handle_response("a", response("old", 100, %{input_tokens: 99}), state)

      state =
        if unquote(queued?) do
          {:ok, [], state} = Pipeline.handle_tell("new", [], "new", state)
          state
        else
          state
        end

      {:ok, ops, state} =
        case unquote(exit_kind) do
          :error -> Pipeline.handle_error("b", :boom, state)
          :cancel -> Pipeline.handle_cancel("old", state)
          :rejected -> Pipeline.handle_dispatch_rejected("b", "old", :boom, state)
        end

      if unquote(exit_kind) != :cancel,
        do: assert({:reply_error, "old", {"b", :boom}} in ops)

      assert state.responses == []

      state =
        if unquote(queued?) do
          assert {:dispatch, "a", "new", "new"} in ops
          state
        else
          assert state.phase == :idle
          {:ok, _, state} = Pipeline.handle_tell("new", [], "new", state)
          state
        end

      fresh = response("fresh", 4, %{input_tokens: 1})
      {:ok, _, state} = Pipeline.handle_response("a", fresh, state)
      {:ok, [{:reply, "new", result}], _} = Pipeline.handle_response("b", fresh, state)

      assert result.metadata.pipeline == %{
               stages: [{"a", fresh}, {"b", fresh}],
               total_duration_ms: 8
             }

      assert result.usage.input_tokens == 2
    end
  end

  defp controlled_pipeline(name) do
    stages =
      for stage <- ["a", "b"],
          do: {stage, ControlledAgent, [backend: ControlledBackend, observer: self(), tag: stage]}

    E.start_link(name: name, strategy: Pipeline, opts: [stages: stages])
  end

  defp finish_controlled(first_task, text) do
    send(first_task, {:result, text})
    assert_receive {:controlled_prompt, "b", ^text, second_task}
    send(second_task, {:result, "final " <> text})
  end

  test "queued results survive repeated await and consumption with isolated stages", %{name: name} do
    {:ok, _} = controlled_pipeline(name)
    {:ok, one} = E.tell(name, "one")
    assert_receive {:controlled_prompt, "a", "one", first}
    {:ok, two} = E.tell(name, "two")
    {:ok, cancelled} = E.tell(name, "cancelled")
    send(first, {:result, "first one"})
    assert_receive {:controlled_prompt, "b", "first one", last}
    assert E.cancel(name, cancelled) == {:ok, :cancelled}
    send(last, {:result, "final one"})
    assert {:ok, result_one} = E.await(name, one, 2_000)
    assert_receive {:controlled_prompt, "a", "two", second}
    finish_controlled(second, "first two")
    assert {:ok, result_two} = E.await(name, two, 2_000)

    for {token, result, text} <- [{one, result_one, "first one"}, {two, result_two, "first two"}] do
      assert E.await(name, token, 0) == {:ok, result}
      assert [{"a", a}, {"b", b}] = result.metadata.pipeline.stages
      assert a.text == text
      assert b.text == result.text
      assert result.metadata.pipeline.total_duration_ms == a.duration_ms + b.duration_ms
    end

    assert E.poll(name, one) == {:ok, :completed, result_one}
    assert E.await(name, one, 0) == {:error, :not_found}
    assert {:ok, entries} = E.inbox(name)
    assert {two, {:ok, result_two}} in entries
    assert {cancelled, {:error, :cancelled}} in entries
    assert E.await(name, two, 0) == {:error, :not_found}
  end

  test "active cancellation fences late completions from the next run", %{name: name} do
    {:ok, pid} = controlled_pipeline(name)
    {:ok, old} = E.tell(name, "old")
    assert_receive {:controlled_prompt, "a", "old", first}
    send(first, {:result, "partial"})
    assert_receive {:controlled_prompt, "b", "partial", _}
    [{ref, {"b", ^old}}] = Map.to_list(:sys.get_state(pid).in_flight)
    {:ok, new} = E.tell(name, "new")
    assert E.cancel(name, old) == {:ok, :cancelled}
    assert_receive {:controlled_prompt, "a", "new", next}
    send(pid, {:gen_agent, :completion, "#{name}/b", ref, {:ok, response("late", 999, %{})}})
    send(pid, {:gen_agent, :completion, "#{name}/b", ref, {:error, :late}})
    finish_controlled(next, "fresh")
    assert {:ok, result} = E.await(name, new, 2_000)

    assert Enum.map(result.metadata.pipeline.stages, fn {_, r} -> r.text end) == [
             "fresh",
             "final fresh"
           ]

    assert E.await(name, old, 0) == {:error, :cancelled}
    assert E.poll(name, old) == {:error, :cancelled}
    assert :sys.get_state(pid).strategy_state.responses == []
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
