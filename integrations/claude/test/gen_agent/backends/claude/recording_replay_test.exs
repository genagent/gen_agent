defmodule GenAgent.Backends.Claude.RecordingReplayTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.StreamEvent
  alias GenAgent.Backends.Claude.EventTranslator

  @directory Path.expand("../../../fixtures/claude/2.1.284", __DIR__)
  @external_resource Path.join(@directory, "manifest.json")
  @manifest @directory |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
  @kinds %{
    "text" => [:session, :text, :usage, :result],
    "tool-partial" =>
      [:session, :tool_use, :tool_result] ++ List.duplicate(:text, 6) ++ [:usage, :result],
    "subagent" => [:session, :text, :tool_use, :tool_result, :text, :usage, :result],
    "plan" => [:session, :tool_use, :tool_result, :text, :usage, :result],
    "error-max-turns" => [:session, :tool_use, :tool_result, :usage, :error],
    "json-schema" => [:session, :tool_use, :tool_result, :usage, :result]
  }

  for {scenario, metadata} <- @manifest["scenarios"] do
    @tag scenario: scenario, metadata: metadata
    test "CLI 2.1.284 #{scenario} recording translates", context do
      lines =
        File.read!(Path.join(@directory, context.scenario <> ".jsonl"))
        |> String.split("\n", trim: true)

      assert length(lines) == context.metadata["lines"]

      parsed =
        Enum.map(lines, fn line ->
          assert {:ok, %StreamEvent{} = event} = StreamEvent.parse(line)
          event
        end)

      init = Enum.find(parsed, &(&1.type == "system" and &1.data["subtype"] == "init"))
      assert init.data["claude_code_version"] == @manifest["cli_version"]
      result = Enum.find(parsed, &(&1.type == "result"))
      assert result.data["session_id"] == init.data["session_id"]
      events = parsed |> EventTranslator.translate_stream() |> Enum.to_list()
      assert Enum.map(events, & &1.kind) == @kinds[context.scenario]
      assert hd(events).data.model == init.data["model"]

      rate_limits = Enum.filter(parsed, &(&1.type == "rate_limit_event"))
      assert rate_limits != []
      assert rate_limits |> EventTranslator.translate_stream() |> Enum.to_list() == []

      assert parsed
             |> Enum.reject(&(&1.type == "rate_limit_event"))
             |> EventTranslator.translate_stream()
             |> Enum.map(&{&1.kind, &1.data}) == Enum.map(events, &{&1.kind, &1.data})

      blocks =
        Enum.flat_map(parsed, fn event -> get_in(event.data, ["message", "content"]) || [] end)

      expected_tools = Enum.filter(blocks, &(&1["type"] in ["tool_use", "tool_result"]))
      tools = Enum.filter(events, &(&1.kind in [:tool_use, :tool_result]))
      # These recordings contain no parent-bearing tool blocks, so their raw payloads stay intact.
      assert Enum.map(tools, & &1.data) == expected_tools

      texts = events |> Enum.filter(&(&1.kind == :text)) |> Enum.map(& &1.data.text)

      expected_texts =
        parsed
        |> Enum.filter(&(&1.type == "assistant"))
        |> Enum.flat_map(&(get_in(&1.data, ["message", "content"]) || []))
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map(& &1["text"])

      assert Enum.join(texts) == Enum.join(expected_texts)
      assert_scenario(context.scenario, parsed, events, texts)

      # Normalized usage omits the recorded cache token fields.
      usage = %{
        input_tokens: result.data["usage"]["input_tokens"],
        output_tokens: result.data["usage"]["output_tokens"]
      }

      assert Enum.at(events, -2).data == usage
      assert is_integer(result.data["usage"]["cache_read_input_tokens"])
      assert is_integer(result.data["usage"]["cache_creation_input_tokens"])
      assert_terminal(List.last(events), result.data, usage, init.data["model"])
    end
  end

  defp assert_terminal(%{kind: :error, data: data}, raw, usage, model) do
    assert raw["errors"] == ["Reached maximum number of turns (1)"]
    refute Map.has_key?(raw, "result")

    expected_reason = %{
      provider: :claude,
      subtype: "error_max_turns",
      message: "Reached maximum number of turns (1)",
      errors: raw["errors"],
      num_turns: raw["num_turns"],
      session_id: raw["session_id"],
      cost_usd: raw["total_cost_usd"],
      usage: usage
    }

    assert data == %{
             data: raw,
             model: model,
             reason: GenAgent.ClaudeErrors.expected(expected_reason)
           }
  end

  defp assert_terminal(%{kind: :result, data: data}, raw, _usage, model) do
    expected = %{
      session_id: raw["session_id"],
      cost_usd: raw["total_cost_usd"],
      duration_ms: raw["duration_ms"],
      num_turns: raw["num_turns"],
      is_error: false,
      raw: raw
    }

    expected = Map.put(expected, :model, model)

    expected =
      if raw["result"] in [nil, ""], do: expected, else: Map.put(expected, :text, raw["result"])

    assert data == expected
  end

  defp assert_scenario("text", _parsed, _events, texts), do: assert(texts == ["pong"])

  defp assert_scenario("tool-partial", _parsed, _events, texts) do
    assert texts == ["The", " output", " is:", " `claude-fixture", " .", "`"]
  end

  defp assert_scenario("subagent", parsed, events, _texts) do
    nested = Enum.filter(parsed, &(&1.data["parent_tool_use_id"] != nil))
    assert nested != []
    assert Enum.all?(nested, &(&1.type == "user"))
    # User text is filtered; the Agent call and return survive.
    assert nested |> EventTranslator.translate_stream() |> Enum.to_list() == []
    assert Enum.find(events, &(&1.kind == :tool_use)).data["name"] == "Agent"
  end

  defp assert_scenario("json-schema", parsed, events, texts) do
    assert texts == []

    assert Enum.find(parsed, &(&1.type == "result")).data["structured_output"] == %{
             "answer" => "4"
           }

    assert List.last(events).data.text == ~s({"answer":"4"})
    refute Map.has_key?(List.last(events).data, :structured_output)
  end

  defp assert_scenario("plan", parsed, _events, _texts) do
    assert Enum.find(parsed, &(&1.data["subtype"] == "init")).data["permissionMode"] == "plan"
  end

  defp assert_scenario("error-max-turns", _parsed, _events, texts), do: assert(texts == [])
end
