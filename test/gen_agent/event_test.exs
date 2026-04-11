defmodule GenAgent.EventTest do
  use ExUnit.Case, async: true

  alias GenAgent.Event

  describe "new/2" do
    test "builds an event with the given kind and data" do
      event = Event.new(:text, %{text: "hello"})

      assert %Event{kind: :text, data: %{text: "hello"}} = event
      assert is_integer(event.timestamp)
    end

    test "defaults data to an empty map" do
      assert %Event{kind: :result, data: %{}} = Event.new(:result)
    end

    test "stamps a monotonic timestamp" do
      e1 = Event.new(:text, %{text: "a"})
      Process.sleep(2)
      e2 = Event.new(:text, %{text: "b"})

      assert e2.timestamp >= e1.timestamp
    end
  end

  describe "terminal?/1" do
    test "is true for :result" do
      assert Event.terminal?(Event.new(:result, %{text: "done"}))
    end

    test "is true for :error" do
      assert Event.terminal?(Event.new(:error, %{reason: :boom}))
    end

    test "is false for intermediate events" do
      refute Event.terminal?(Event.new(:text, %{text: "chunk"}))
      refute Event.terminal?(Event.new(:tool_use, %{name: "bash"}))
      refute Event.terminal?(Event.new(:tool_result, %{}))
      refute Event.terminal?(Event.new(:usage, %{input_tokens: 10}))
    end
  end
end
