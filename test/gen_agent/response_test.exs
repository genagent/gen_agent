defmodule GenAgent.ResponseTest do
  use ExUnit.Case, async: true

  alias GenAgent.{Event, Response}

  test "manually constructed responses leave final_message unspecified" do
    assert %Response{text: "synthetic"}.final_message == nil
  end

  test "metadata defaults to an empty map for manual and backend responses" do
    assert %Response{}.metadata == %{}
    assert Response.from_events([Event.new(:result, %{text: "done"})]).metadata == %{}
  end

  describe "from_events/2" do
    test "takes text from the :result event when present" do
      events = [
        Event.new(:text, %{text: "hel"}),
        Event.new(:text, %{text: "lo"}),
        Event.new(:result, %{text: "hello"})
      ]

      response = Response.from_events(events)

      assert response.text == "hello"
      assert response.final_message == "hello"
      assert response.events == events
      assert response.terminal == List.last(events)
      assert response.event_coverage.mode == :exact
      assert response.event_coverage.observed_events == 3
      assert response.event_coverage.retained_events == 3
      assert response.event_coverage.omitted_events == 0
    end

    test "falls back to assembling :text deltas when :result has no text" do
      events = [
        Event.new(:text, %{text: "hel"}),
        Event.new(:text, %{text: "lo"}),
        Event.new(:result, %{})
      ]

      assert Response.from_events(events).text == "hello"
    end

    test "separates completed messages without splitting streaming deltas" do
      events = [
        Event.new(:text, %{text: "first ", message_boundary: true}),
        Event.new(:text, %{text: "message"}),
        Event.new(:text, %{text: "second", message_boundary: true}),
        Event.new(:result, %{})
      ]

      response = Response.from_events(events)
      assert response.text == "first message\n\nsecond"
      assert response.final_message == "second"
    end

    test "does not split a single message on its own paragraph break" do
      events = [
        Event.new(:text, %{text: "first paragraph\n\nsecond paragraph", message_boundary: true}),
        Event.new(:result, %{})
      ]

      response = Response.from_events(events)
      assert response.text == "first paragraph\n\nsecond paragraph"
      assert response.final_message == response.text
    end

    test "uses explicit terminal text when it differs from streamed text" do
      events = [
        Event.new(:text, %{text: "draft", message_boundary: true}),
        Event.new(:result, %{text: "final"})
      ]

      response = Response.from_events(events)
      assert response.text == "final"
      assert response.final_message == "final"
    end

    test "extracts usage from the most recent :usage event" do
      events = [
        Event.new(:usage, %{input_tokens: 1, output_tokens: 2}),
        Event.new(:text, %{text: "hi"}),
        Event.new(:usage, %{input_tokens: 3, output_tokens: 4}),
        Event.new(:result, %{text: "hi"})
      ]

      assert Response.from_events(events).usage == %{input_tokens: 3, output_tokens: 4}
    end

    test "usage is nil when no :usage event was emitted" do
      events = [Event.new(:result, %{text: "hi"})]
      assert Response.from_events(events).usage == nil
    end

    test "carries duration_ms and session_id from opts" do
      events = [Event.new(:result, %{text: "hi"})]

      response = Response.from_events(events, duration_ms: 1234, session_id: "sess-abc")

      assert response.duration_ms == 1234
      assert response.session_id == "sess-abc"
    end

    test "defaults duration_ms to 0 and session_id to nil" do
      response = Response.from_events([Event.new(:result, %{text: "hi"})])

      assert response.duration_ms == 0
      assert response.session_id == nil
    end
  end
end
