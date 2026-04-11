defmodule GenAgent.ResponseTest do
  use ExUnit.Case, async: true

  alias GenAgent.{Event, Response}

  describe "from_events/2" do
    test "takes text from the :result event when present" do
      events = [
        Event.new(:text, %{text: "hel"}),
        Event.new(:text, %{text: "lo"}),
        Event.new(:result, %{text: "hello"})
      ]

      response = Response.from_events(events)

      assert response.text == "hello"
      assert response.events == events
    end

    test "falls back to assembling :text deltas when :result has no text" do
      events = [
        Event.new(:text, %{text: "hel"}),
        Event.new(:text, %{text: "lo"}),
        Event.new(:result, %{})
      ]

      assert Response.from_events(events).text == "hello"
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
