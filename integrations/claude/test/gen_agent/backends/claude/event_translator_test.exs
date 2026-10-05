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

    test "preserves the parent tool ID on text and tool-use blocks" do
      event =
        stream_event("assistant", %{
          "parent_tool_use_id" => "parent-1",
          "message" => %{
            "content" => [
              %{"type" => "text", "text" => "reading"},
              %{"type" => "tool_use", "id" => "call-1", "name" => "Read", "input" => %{}}
            ]
          }
        })

      assert [
               %Event{kind: :text, data: %{text: "reading", parent_tool_use_id: "parent-1"}},
               %Event{kind: :tool_use, data: %{parent_tool_use_id: "parent-1"}}
             ] = EventTranslator.translate(event)
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

    test "preserves the parent tool ID on a text delta" do
      event =
        stream_event("content_block_delta", %{
          "parent_tool_use_id" => "parent-1",
          "delta" => %{"text" => "chunk"}
        })

      assert [%Event{kind: :text, data: %{text: "chunk", parent_tool_use_id: "parent-1"}}] =
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

    test "preserves the parent tool ID on user tool-result blocks" do
      event =
        stream_event("user", %{
          "parent_tool_use_id" => "parent-1",
          "message" => %{
            "content" => [
              %{"type" => "tool_result", "tool_use_id" => "call-1", "content" => "ok"}
            ]
          }
        })

      assert [%Event{kind: :tool_result, data: %{parent_tool_use_id: "parent-1"}}] =
               EventTranslator.translate(event)
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

    test "omits :text when the result field is missing or empty" do
      for extra <- [%{}, %{"result" => ""}] do
        event = stream_event("result", Map.put(extra, "session_id", "sess-x"))

        assert [%Event{kind: :result, data: data}] = EventTranslator.translate(event)
        assert data.session_id == "sess-x"
        refute Map.has_key?(data, :text)
        assert data.raw == Map.put(extra, "session_id", "sess-x")
      end
    end

    test "keeps the raw result map on success" do
      data = %{
        "result" => "",
        "structured_output" => %{"answer" => 42},
        "stop_reason" => "end_turn",
        "permission_denials" => [%{"tool_name" => "Bash"}],
        "duration_api_ms" => 9
      }

      assert [%Event{kind: :result, data: %{raw: ^data}}] =
               EventTranslator.translate(stream_event("result", data))
    end

    test "stream leaves :text off the result so Response falls back to text events" do
      for result <- [%{"result" => ""}, %{}] do
        events =
          [
            stream_event("assistant", %{"content" => [%{"type" => "text", "text" => "the plan"}]}),
            stream_event("result", result)
          ]
          |> EventTranslator.translate_stream()
          |> Enum.to_list()

        assert %Event{kind: :result, data: data} = List.last(events)
        refute Map.has_key?(data, :text)
        assert data.raw == result
        assert GenAgent.Response.from_events(events).text == "the plan"
      end
    end

    test "stream keeps a nonempty result over assistant text" do
      events =
        [
          stream_event("assistant", %{"content" => [%{"type" => "text", "text" => "draft"}]}),
          stream_event("result", %{"result" => "final"})
        ]
        |> EventTranslator.translate_stream()
        |> Enum.to_list()

      assert %Event{data: %{text: "final"}} = List.last(events)
    end

    test "failed result message uses errors when result is absent or empty" do
      for extra <- [%{}, %{"result" => ""}] do
        data =
          Map.merge(extra, %{
            "subtype" => "error_during_execution",
            "is_error" => true,
            "errors" => ["something broke", "again"],
            "num_turns" => 2,
            "session_id" => "s"
          })

        assert [%Event{kind: :error, data: %{reason: reason}}] =
                 EventTranslator.translate(stream_event("result", data))

        assert reason.message == "something broke; again"
        assert reason.errors == ["something broke", "again"]
        assert reason.num_turns == 2
      end
    end

    test "failed result prefers result string, then falls back from empty errors" do
      with_result = %{"is_error" => true, "result" => "text", "errors" => ["e"]}

      assert [%Event{data: %{reason: %{message: "text"}}}] =
               EventTranslator.translate(stream_event("result", with_result))

      empty = %{"is_error" => true, "errors" => [], "error" => "plain"}

      assert [%Event{data: %{reason: %{message: "plain"} = reason}}] =
               EventTranslator.translate(stream_event("result", empty))

      refute Map.has_key?(reason, :errors)

      assert [%Event{data: %{reason: %{message: :unknown}}}] =
               EventTranslator.translate(stream_event("result", %{"is_error" => true}))
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

    test "interleaved subagent messages do not reset another parent's text deduplication" do
      inputs = [
        stream_event("stream_event", %{
          "event" => %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hello"}
          }
        }),
        stream_event("assistant", %{
          "parent_tool_use_id" => "parent-1",
          "message" => %{"content" => [%{"type" => "text", "text" => "subagent"}]}
        }),
        stream_event("assistant", %{
          "message" => %{"content" => [%{"type" => "text", "text" => "Hello world"}]}
        })
      ]

      assert [
               %Event{kind: :text, data: %{text: "Hello"}},
               %Event{
                 kind: :text,
                 data: %{text: "subagent", parent_tool_use_id: "parent-1"}
               },
               %Event{kind: :text, data: %{text: " world"}}
             ] = Enum.to_list(EventTranslator.translate_stream(inputs))
    end

    test "deduplicates text and calls within each parent only" do
      delta = fn parent ->
        stream_event("stream_event", %{
          "parent_tool_use_id" => parent,
          "event" => %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hi"}
          }
        })
      end

      assistant = fn parent ->
        stream_event("assistant", %{
          "parent_tool_use_id" => parent,
          "message" => %{
            "content" => [
              %{"type" => "text", "text" => "Hi"},
              %{"type" => "tool_use", "id" => "shared-call", "name" => "Read", "input" => %{}}
            ]
          }
        })
      end

      events =
        [delta.("parent-1"), delta.("parent-2"), assistant.("parent-1"), assistant.("parent-2")]
        |> EventTranslator.translate_stream()
        |> Enum.to_list()

      assert Enum.map(events, & &1.kind) == [:text, :text, :tool_use, :tool_use]

      assert Enum.map(events, & &1.data.parent_tool_use_id) ==
               ["parent-1", "parent-2", "parent-1", "parent-2"]
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
