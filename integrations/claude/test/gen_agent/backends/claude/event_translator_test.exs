defmodule GenAgent.Backends.Claude.EventTranslatorTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.StreamEvent
  alias GenAgent.Backends.Claude.EventTranslator
  alias GenAgent.Event

  defp stream_event(type, data) do
    %StreamEvent{type: type, data: data, raw: ""}
  end

  describe "translate/1 -- system events" do
    test "are filtered out" do
      assert EventTranslator.translate(stream_event("system", %{"info" => "init"})) == []
    end
  end

  describe "translate/1 -- assistant events" do
    test "with content as a list of text blocks" do
      event =
        stream_event("assistant", %{
          "content" => [
            %{"type" => "text", "text" => "hello"},
            %{"type" => "text", "text" => " world"}
          ]
        })

      assert [%Event{kind: :text, data: %{text: "hello world"}}] =
               EventTranslator.translate(event)
    end

    test "with content as a plain string" do
      event = stream_event("assistant", %{"content" => "just a string"})

      assert [%Event{kind: :text, data: %{text: "just a string"}}] =
               EventTranslator.translate(event)
    end

    test "with a wrapping :message key" do
      event =
        stream_event("assistant", %{
          "message" => %{"content" => [%{"text" => "nested"}]}
        })

      assert [%Event{kind: :text, data: %{text: "nested"}}] =
               EventTranslator.translate(event)
    end

    test "with no text or tool content is filtered out" do
      event = stream_event("assistant", %{"content" => [%{"type" => "image"}]})
      assert EventTranslator.translate(event) == []
    end
  end

  describe "translate/1 -- content_block_delta events" do
    test "with text delta" do
      event = stream_event("content_block_delta", %{"delta" => %{"text" => "chunk"}})

      assert [%Event{kind: :text, data: %{text: "chunk"}}] =
               EventTranslator.translate(event)
    end

    test "without text delta is filtered out" do
      event = stream_event("content_block_delta", %{"delta" => %{"other" => "thing"}})
      assert EventTranslator.translate(event) == []
    end
  end

  describe "translate/1 -- tool events" do
    test "tool_use passes data through" do
      data = %{"name" => "bash", "input" => %{"cmd" => "ls"}}
      event = stream_event("tool_use", data)

      assert [%Event{kind: :tool_use, data: ^data}] = EventTranslator.translate(event)
    end

    test "tool_result passes data through" do
      data = %{"tool_use_id" => "abc", "content" => "file1\nfile2"}
      event = stream_event("tool_result", data)

      assert [%Event{kind: :tool_result, data: ^data}] = EventTranslator.translate(event)
    end
  end

  describe "translate/1 -- result events" do
    test "extracts text, session_id, and metadata" do
      event =
        stream_event("result", %{
          "result" => "all done",
          "session_id" => "sess-123",
          "total_cost_usd" => 0.02,
          "duration_ms" => 1500,
          "num_turns" => 2,
          "is_error" => false
        })

      assert [
               %Event{
                 kind: :result,
                 data: %{
                   text: "all done",
                   session_id: "sess-123",
                   cost_usd: 0.02,
                   duration_ms: 1500,
                   num_turns: 2,
                   is_error: false
                 }
               }
             ] = EventTranslator.translate(event)
    end

    test "emits a :usage event ahead of the :result event when token counts are present" do
      event =
        stream_event("result", %{
          "result" => "done",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 3}
        })

      assert [
               %Event{kind: :usage, data: %{input_tokens: 10, output_tokens: 3}},
               %Event{kind: :result}
             ] = EventTranslator.translate(event)
    end

    test "does not emit a :usage event when token counts are absent" do
      event = stream_event("result", %{"result" => "done", "usage" => %{"other" => 1}})
      assert [%Event{kind: :result}] = EventTranslator.translate(event)
    end

    test "drops nil metadata fields" do
      event = stream_event("result", %{"result" => "ok"})

      assert [%Event{kind: :result, data: data}] = EventTranslator.translate(event)
      refute Map.has_key?(data, :session_id)
      refute Map.has_key?(data, :cost_usd)
      assert data.text == "ok"
      assert data.is_error == false
    end

    test "defaults empty text when :result field is missing" do
      event = stream_event("result", %{"session_id" => "sess-x"})

      assert [%Event{kind: :result, data: %{text: "", session_id: "sess-x"}}] =
               EventTranslator.translate(event)
    end

    test "falls back to cost_usd when total_cost_usd is absent" do
      event = stream_event("result", %{"result" => "ok", "cost_usd" => 0.05})

      assert [%Event{kind: :result, data: %{cost_usd: 0.05}}] =
               EventTranslator.translate(event)
    end
  end

  describe "translate/1 -- error events" do
    test "extracts reason from data[\"error\"]" do
      event = stream_event("error", %{"error" => "auth failed", "code" => 401})

      assert [%Event{kind: :error, data: %{reason: "auth failed"}}] =
               EventTranslator.translate(event)
    end

    test "falls back to data[\"message\"]" do
      event = stream_event("error", %{"message" => "network unreachable"})

      assert [%Event{kind: :error, data: %{reason: "network unreachable"}}] =
               EventTranslator.translate(event)
    end

    test "uses :unknown when neither field is present" do
      event = stream_event("error", %{})
      assert [%Event{kind: :error, data: %{reason: :unknown}}] = EventTranslator.translate(event)
    end
  end

  describe "translate/1 -- unknown events" do
    test "are filtered out" do
      assert EventTranslator.translate(stream_event("what_even", %{})) == []
      assert EventTranslator.translate(stream_event(nil, %{})) == []
    end
  end

  describe "translate_stream/1" do
    test "flattens a mixed stream into a GenAgent.Event stream" do
      inputs = [
        stream_event("system", %{}),
        stream_event("assistant", %{"content" => [%{"text" => "hi"}]}),
        stream_event("tool_use", %{"name" => "bash"}),
        stream_event("result", %{"result" => "done"})
      ]

      outputs = inputs |> EventTranslator.translate_stream() |> Enum.to_list()

      assert Enum.map(outputs, & &1.kind) == [:text, :tool_use, :result]
    end

    test "parses nested tool calls and returns while avoiding streamed text duplication" do
      lines = [
        ~s({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}),
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Hello"},{"type":"tool_use","id":"call-1","name":"mcp__fixture__read","input":{"path":"README.md"}},{"type":"text","text":" world"}]}}),
        ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"call-1","content":"ok","is_error":false}]}}),
        ~s({"type":"result","result":"Hello world","session_id":"s-1","usage":{"input_tokens":2,"output_tokens":3}})
      ]

      events =
        lines
        |> Enum.map(fn line ->
          {:ok, event} = StreamEvent.parse(line)
          event
        end)
        |> EventTranslator.translate_stream()
        |> Enum.to_list()

      assert Enum.map(events, & &1.kind) == [
               :text,
               :tool_use,
               :text,
               :tool_result,
               :usage,
               :result
             ]

      assert Enum.at(events, 0).data.text == "Hello"
      assert Enum.at(events, 1).data["input"] == %{"path" => "README.md"}
      assert Enum.at(events, 2).data.text == " world"
      assert Enum.at(events, 3).data["tool_use_id"] == "call-1"
    end
  end

  test "failed result envelope is terminal error with subtype and usage" do
    {:ok, event} =
      StreamEvent.parse(
        ~s({"type":"result","subtype":"error_max_turns","is_error":true,"result":"Turn limit reached","session_id":"s-2","total_cost_usd":0.02,"usage":{"input_tokens":10,"output_tokens":1}})
      )

    assert [
             %Event{kind: :usage, data: %{input_tokens: 10}},
             %Event{kind: :error, data: %{reason: reason}}
           ] = EventTranslator.translate(event)

    assert reason.subtype == "error_max_turns"
    assert reason.message == "Turn limit reached"
    assert reason.session_id == "s-2"
    assert reason.cost_usd == 0.02
  end

  test "failure subtype remains an error even if is_error is absent" do
    assert [%Event{kind: :error}] =
             EventTranslator.translate(
               stream_event("result", %{"subtype" => "error_max_budget_usd"})
             )
  end
end
