defmodule GenAgent.Backends.Codex.EventTranslatorTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.JsonLineEvent
  alias GenAgent.Backends.Codex.EventTranslator
  alias GenAgent.CodexTranscripts, as: Transcripts
  alias GenAgent.Event
  alias GenAgent.Response

  defp event(type, data), do: %JsonLineEvent{event_type: type, data: data, raw: ""}

  for recording <- Transcripts.names() do
    @tag recording: recording
    test "translates recorded #{recording} exactly", %{recording: recording} do
      recording
      |> Transcripts.load()
      |> EventTranslator.translate()
      |> Transcripts.assert_events(recording)
    end
  end

  test "recorded command lifecycle emits a small start marker and one full completion" do
    events = Transcripts.load("command")
    started = Enum.at(events, 3)
    completed = Enum.at(events, 4)
    assert started.event_type == "item.started"
    assert started.data["item"]["status"] == "in_progress"
    assert started.data["item"]["aggregated_output"] == ""
    assert started.data["item"]["exit_code"] == nil
    assert completed.event_type == "item.completed"
    assert completed.data["item"]["id"] == started.data["item"]["id"]

    assert [%Event{kind: :tool_use, data: %{"id" => "item_1", "type" => "command_execution"}}] =
             EventTranslator.translate([started])

    assert [%Event{kind: :tool_result, data: item}] = EventTranslator.translate([completed])
    assert item == completed.data["item"]
  end

  test "recorded error item and notification do not terminate before turn.failed" do
    events = Transcripts.load("failure")

    assert Enum.map(events, & &1.event_type) ==
             ["thread.started", "item.completed", "turn.started", "error", "turn.failed"]

    assert Enum.at(events, 1).data["item"]["type"] == "error"

    assert [%Event{kind: :tool_result, data: %{"type" => "error"}}] =
             EventTranslator.translate(Enum.take(events, 3))

    observer = self()

    stream =
      Stream.map(events, fn event ->
        if event.event_type == "turn.failed", do: send(observer, :reached_turn_failed)
        event
      end)

    assert [%Event{kind: :tool_result, data: %{"type" => "error"}}, terminal] =
             EventTranslator.translate_stream(stream) |> Enum.to_list()

    assert_receive :reached_turn_failed
    assert terminal.kind == :error
    assert terminal.data == %{reason: Transcripts.failure(), data: List.last(events).data}
  end

  describe "thread_id capture" do
    test "injects thread_id from thread.started into the :result event as session_id" do
      events = [
        event("thread.started", %{"thread_id" => "thread-abc", "type" => "thread.started"}),
        event("turn.started", %{"type" => "turn.started"}),
        event("item.completed", %{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => "hi"}
        }),
        event("turn.completed", %{
          "type" => "turn.completed",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
        })
      ]

      translated = EventTranslator.translate(events)

      assert [
               %Event{kind: :text, data: %{text: "hi"}},
               %Event{kind: :usage, data: %{input_tokens: 10, output_tokens: 2}},
               %Event{kind: :result, data: %{session_id: "thread-abc"}}
             ] = translated
    end

    test "emits a :result event with nil session_id when thread.started is missing" do
      events = [
        event("turn.completed", %{"usage" => %{"input_tokens" => 1, "output_tokens" => 1}})
      ]

      translated = EventTranslator.translate(events)

      assert [
               %Event{kind: :usage},
               %Event{kind: :result, data: data}
             ] = translated

      refute Map.has_key?(data, :session_id)
    end
  end

  describe "item.completed translation" do
    test "agent_message becomes :text" do
      events = [
        event("item.completed", %{
          "item" => %{"type" => "agent_message", "text" => "hello world"}
        }),
        event("turn.completed", %{})
      ]

      assert [%Event{kind: :text, data: %{text: "hello world"}}, %Event{kind: :result}] =
               EventTranslator.translate(events)
    end

    test "separate completed agent messages stay distinct in the response" do
      events = [
        event("item.completed", %{
          "item" => %{"type" => "agent_message", "text" => "I will inspect the file."}
        }),
        event("item.completed", %{
          "item" => %{"type" => "agent_message", "text" => "The file is correct."}
        }),
        event("turn.completed", %{})
      ]

      translated = EventTranslator.translate(events)
      assert [%Event{kind: :text}, %Event{kind: :text}, %Event{kind: :result}] = translated
      assert Enum.all?(Enum.take(translated, 2), &(&1.data.message_boundary == true))

      assert Response.from_events(translated).text ==
               "I will inspect the file.\n\nThe file is correct."
    end

    test "legacy tool_call and tool_result names outside the exec schema are filtered" do
      events = [
        event("item.completed", %{"item" => %{"type" => "tool_call"}}),
        event("item.completed", %{"item" => %{"type" => "tool_result"}}),
        event("turn.completed", %{})
      ]

      assert [%Event{kind: :result}] = EventTranslator.translate(events)
    end

    test "unknown item types are filtered out" do
      events = [
        event("item.completed", %{"item" => %{"type" => "mystery"}}),
        event("turn.completed", %{})
      ]

      assert [%Event{kind: :result}] = EventTranslator.translate(events)
    end

    test "current action item types keep full completion once and compact start markers" do
      items = [
        %{
          "type" => "mcp_tool_call",
          "id" => "call-2",
          "server" => "fixture",
          "tool" => "read",
          "arguments" => %{},
          "result" => %{"content" => []},
          "status" => "completed"
        },
        %{
          "type" => "command_execution",
          "id" => "cmd-1",
          "command" => "echo fixture",
          "aggregated_output" => "fixture",
          "exit_code" => 0,
          "status" => "completed"
        },
        %{
          "type" => "file_change",
          "id" => "edit-1",
          "changes" => [%{"path" => "fixture.txt", "kind" => "add"}],
          "status" => "failed"
        },
        %{
          "type" => "web_search",
          "id" => "search-1",
          "query" => "example",
          "action" => %{"type" => "search"}
        },
        %{
          "type" => "collab_tool_call",
          "id" => "collab-1",
          "tool" => "wait",
          "sender_thread_id" => "t-1",
          "receiver_thread_ids" => ["t-2"],
          "prompt" => nil,
          "agents_states" => %{},
          "status" => "completed"
        }
      ]

      events =
        [event("thread.started", %{"thread_id" => "t-1"})] ++
          Enum.flat_map(items, fn item ->
            if item["type"] == "file_change" do
              [event("item.completed", %{"item" => item})]
            else
              [
                event("item.started", %{"item" => item}),
                event("item.completed", %{"item" => item})
              ]
            end
          end) ++
          [event("turn.completed", %{})]

      translated = EventTranslator.translate(events)

      assert Enum.map(translated, & &1.kind) ==
               [
                 :tool_use,
                 :tool_result,
                 :tool_use,
                 :tool_result,
                 :tool_result,
                 :tool_use,
                 :tool_result,
                 :tool_use,
                 :tool_result,
                 :result
               ]

      assert Enum.at(translated, 1).data["id"] == "call-2"
      assert Enum.at(translated, 3).data["aggregated_output"] == "fixture"
      assert Enum.at(translated, 4).data["status"] == "failed"
      assert Enum.at(translated, 6).data["query"] == "example"
      assert Enum.at(translated, 8).data["receiver_thread_ids"] == ["t-2"]
      assert List.last(translated).data.session_id == "t-1"
    end

    test "started and updated actions do not duplicate the full completion" do
      item = %{"type" => "mcp_tool_call", "id" => "call-1", "status" => "completed"}

      events = [
        event("item.started", %{"item" => %{item | "status" => "in_progress"}}),
        event("item.updated", %{"item" => %{item | "status" => "in_progress"}}),
        event("item.completed", %{"item" => item})
      ]

      assert [%Event{kind: :tool_use, data: marker}, %Event{kind: :tool_result, data: ^item}] =
               EventTranslator.translate(events)

      assert marker == %{"id" => "call-1", "type" => "mcp_tool_call"}
    end

    test "reasoning, plan, and non-fatal error items remain activity records" do
      items = [
        %{"id" => "reason-1", "type" => "reasoning", "text" => "Checking..."},
        %{
          "id" => "plan-1",
          "type" => "todo_list",
          "items" => [%{"text" => "Check", "completed" => true}]
        },
        %{"id" => "warning-1", "type" => "error", "message" => "Using fallback metadata"}
      ]

      translated =
        Enum.map(items, &event("item.completed", %{"item" => &1}))
        |> Kernel.++([event("turn.completed", %{})])
        |> EventTranslator.translate()

      assert Enum.map(translated, & &1.kind) == [
               :tool_result,
               :tool_result,
               :tool_result,
               :result
             ]

      assert Enum.map(Enum.take(translated, 3), & &1.data) == items
      assert Response.from_events(translated).text == ""
    end
  end

  test "translate_stream emits events before the turn is complete" do
    parent = self()

    raw =
      Stream.resource(
        fn -> 0 end,
        fn
          0 ->
            {[event("thread.started", %{"thread_id" => "t-stream"})], 1}

          1 ->
            {[
               event("item.completed", %{
                 "item" => %{"type" => "agent_message", "text" => "early"}
               })
             ], 2}

          2 ->
            send(parent, :terminal_read)
            {[event("turn.completed", %{})], 3}

          3 ->
            {:halt, 3}
        end,
        fn _ -> :ok end
      )

    [first | rest] = EventTranslator.translate_stream(raw) |> Enum.to_list()
    assert first.kind == :text
    assert first.data.text == "early"
    assert_receive :terminal_read
    assert [%Event{kind: :result, data: %{session_id: "t-stream"}}] = rest
  end

  describe "turn.completed" do
    test "emits :usage when token counts are present" do
      events = [
        event("turn.completed", %{
          "usage" => %{
            "input_tokens" => 100,
            "output_tokens" => 50,
            "cached_input_tokens" => 80
          }
        })
      ]

      assert [
               %Event{
                 kind: :usage,
                 data: %{input_tokens: 100, output_tokens: 50, cached_input_tokens: 80}
               },
               %Event{kind: :result}
             ] = EventTranslator.translate(events)
    end

    test "skips :usage when no token counts are present" do
      events = [event("turn.completed", %{})]
      assert [%Event{kind: :result, data: data}] = EventTranslator.translate(events)
      assert data.usage_total == %{}
    end
  end

  describe "turn.completed usage" do
    @all_fields %{
      "input_tokens" => 626_594,
      "cached_input_tokens" => 567_936,
      "cache_write_input_tokens" => 7,
      "output_tokens" => 2634,
      "reasoning_output_tokens" => 799
    }

    defp completed(usage), do: [event("turn.completed", %{"usage" => usage})]

    test "first turn preserves all five fields and reports the raw total" do
      total = %{
        input_tokens: 626_594,
        cached_input_tokens: 567_936,
        cache_write_input_tokens: 7,
        output_tokens: 2634,
        reasoning_output_tokens: 799
      }

      assert [
               %Event{kind: :usage, data: ^total},
               %Event{kind: :result, data: %{usage_total: ^total}}
             ] = EventTranslator.translate(completed(@all_fields))

      events = EventTranslator.translate(completed(@all_fields))
      assert Response.from_events(events, []).usage == total
    end

    test "resumed turn reports the delta from the previous completed total" do
      baseline = %{
        input_tokens: 14_956,
        cached_input_tokens: 12_160,
        cache_write_input_tokens: 0,
        output_tokens: 5,
        reasoning_output_tokens: 0
      }

      usage = %{
        "input_tokens" => 29_938,
        "cached_input_tokens" => 24_320,
        "cache_write_input_tokens" => 0,
        "output_tokens" => 10,
        "reasoning_output_tokens" => 0
      }

      assert [%Event{kind: :usage, data: delta}, %Event{kind: :result, data: result}] =
               EventTranslator.translate(completed(usage), usage_baseline: baseline)

      assert delta == %{
               input_tokens: 14_982,
               cached_input_tokens: 12_160,
               cache_write_input_tokens: 0,
               output_tokens: 5,
               reasoning_output_tokens: 0
             }

      assert result.usage_total.input_tokens == 29_938
    end

    test "unknown baseline omits usage but still reports the total" do
      assert [%Event{kind: :result, data: %{usage_total: %{input_tokens: 5}}}] =
               EventTranslator.translate(completed(%{"input_tokens" => 5}), usage_baseline: %{})
    end

    test "missing fields produce no delta and no zeros" do
      baseline = %{input_tokens: 10, output_tokens: 2}

      assert [%Event{kind: :usage, data: data}, %Event{kind: :result}] =
               EventTranslator.translate(
                 completed(%{"input_tokens" => 25, "reasoning_output_tokens" => 3}),
                 usage_baseline: baseline
               )

      assert data == %{input_tokens: 15}
    end

    test "maps with only optional counters are kept, including zeros" do
      assert [%Event{kind: :usage, data: %{reasoning_output_tokens: 0}}, %Event{}] =
               EventTranslator.translate(completed(%{"reasoning_output_tokens" => 0}))
    end

    test "decreased counters are suppressed and never negative" do
      baseline = %{input_tokens: 100, output_tokens: 10}

      assert [%Event{kind: :usage, data: data}, %Event{kind: :result, data: result}] =
               EventTranslator.translate(
                 completed(%{"input_tokens" => 40, "output_tokens" => 15}),
                 usage_baseline: baseline
               )

      assert data == %{output_tokens: 5}
      assert result.usage_total == %{input_tokens: 40, output_tokens: 15}

      assert [%Event{kind: :result}] =
               EventTranslator.translate(completed(%{"input_tokens" => 1}),
                 usage_baseline: baseline
               )
    end

    test "non-integer and negative counters are ignored" do
      usage = %{"input_tokens" => "9", "output_tokens" => 4, "cached_input_tokens" => -1}

      assert [%Event{kind: :usage, data: %{output_tokens: 4}}, %Event{}] =
               EventTranslator.translate(completed(usage))
    end
  end

  describe "error events" do
    test "turn.failed becomes a terminal :error" do
      events = [
        event("thread.started", %{"thread_id" => "t-1"}),
        event("turn.failed", %{"error" => "rate limited"})
      ]

      assert [%Event{kind: :error, data: %{reason: "rate limited"}}] =
               EventTranslator.translate(events)
    end

    test "error notification followed by completion does not fail the turn" do
      events = [
        event("error", %{"message" => "Reconnecting... 1/5"}),
        event("item.completed", %{"item" => %{"type" => "agent_message", "text" => "done"}}),
        event("turn.completed", %{})
      ]

      assert [%Event{kind: :text, data: %{text: "done"}}, %Event{kind: :result}] =
               EventTranslator.translate(events)
    end

    test "turn.failed preserves a structured error" do
      events = [
        event("error", %{"message" => "Reconnecting... 1/5"}),
        event("turn.failed", %{"error" => %{"message" => "connection lost"}})
      ]

      assert [%Event{kind: :error, data: %{reason: %{"message" => "connection lost"}}}] =
               EventTranslator.translate(events)
    end

    test "turn.failed uses the latest notification when it has no reason" do
      events = [
        event("error", %{"message" => "first error"}),
        event("error", %{"message" => "last error"}),
        event("turn.failed", %{})
      ]

      assert [%Event{kind: :error, data: %{reason: "last error"}}] =
               EventTranslator.translate(events)
    end

    test "error notification at end of stream becomes a terminal error" do
      events = [event("error", %{"message" => "network down"})]

      assert [%Event{kind: :error, data: %{reason: "network down"}}] =
               EventTranslator.translate(events)
    end

    test "error notification with neither field falls back to :unknown at end of stream" do
      assert [%Event{kind: :error, data: %{reason: :unknown}}] =
               EventTranslator.translate([event("error", %{})])
    end
  end

  describe "filtered events" do
    test "turn.started is filtered" do
      events = [event("turn.started", %{}), event("turn.completed", %{})]
      assert [%Event{kind: :result}] = EventTranslator.translate(events)
    end

    test "unknown event types are filtered" do
      events = [
        event("mystery.event", %{"foo" => "bar"}),
        event("turn.completed", %{})
      ]

      assert [%Event{kind: :result}] = EventTranslator.translate(events)
    end
  end
end
