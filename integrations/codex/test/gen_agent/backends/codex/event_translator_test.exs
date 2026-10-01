defmodule GenAgent.Backends.Codex.EventTranslatorTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.JsonLineEvent
  alias GenAgent.Backends.Codex.EventTranslator
  alias GenAgent.Event

  defp event(type, data), do: %JsonLineEvent{event_type: type, data: data, raw: ""}

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

    test "tool_call becomes :tool_use with the whole item as data" do
      item = %{"type" => "tool_call", "id" => "t1", "name" => "bash", "input" => %{}}
      events = [event("item.completed", %{"item" => item}), event("turn.completed", %{})]

      assert [%Event{kind: :tool_use, data: ^item}, %Event{kind: :result}] =
               EventTranslator.translate(events)
    end

    test "tool_result becomes :tool_result" do
      item = %{"type" => "tool_result", "output" => "file1\nfile2"}
      events = [event("item.completed", %{"item" => item}), event("turn.completed", %{})]

      assert [%Event{kind: :tool_result, data: ^item}, %Event{kind: :result}] =
               EventTranslator.translate(events)
    end

    test "unknown item types are filtered out" do
      events = [
        event("item.completed", %{"item" => %{"type" => "mystery"}}),
        event("turn.completed", %{})
      ]

      assert [%Event{kind: :result}] = EventTranslator.translate(events)
    end

    test "current MCP, command and file items retain their IDs, results and status" do
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
        }
      ]

      events =
        [event("thread.started", %{"thread_id" => "t-1"})] ++
          Enum.map(items, &event("item.completed", %{"item" => &1})) ++
          [event("turn.completed", %{})]

      translated = EventTranslator.translate(events)

      assert Enum.map(translated, & &1.kind) ==
               [
                 :tool_use,
                 :tool_result,
                 :tool_use,
                 :tool_result,
                 :tool_use,
                 :tool_result,
                 :result
               ]

      assert Enum.at(translated, 1).data["id"] == "call-2"
      assert Enum.at(translated, 3).data["aggregated_output"] == "fixture"
      assert Enum.at(translated, 5).data["status"] == "failed"
      assert List.last(translated).data.session_id == "t-1"
    end

    test "started and updated actions are not counted again" do
      item = %{"type" => "mcp_tool_call", "id" => "call-1", "status" => "completed"}

      events = [
        event("item.started", %{"item" => %{item | "status" => "in_progress"}}),
        event("item.updated", %{"item" => %{item | "status" => "in_progress"}}),
        event("item.completed", %{"item" => item})
      ]

      assert [%Event{kind: :tool_use}, %Event{kind: :tool_result}] =
               EventTranslator.translate(events)
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
      assert [%Event{kind: :result}] = EventTranslator.translate(events)
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

    test "plain error event" do
      events = [event("error", %{"message" => "network down"})]

      assert [%Event{kind: :error, data: %{reason: "network down"}}] =
               EventTranslator.translate(events)
    end

    test "error with neither field falls back to :unknown" do
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
