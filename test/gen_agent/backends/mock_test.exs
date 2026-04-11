defmodule GenAgent.Backends.MockTest do
  use ExUnit.Case, async: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event

  describe "start_session/1" do
    test "starts with no scripts by default" do
      {:ok, session} = Mock.start_session([])
      assert Mock.remaining(session) == 0
      assert Mock.history(session) == []
    end

    test "accepts an initial session_id" do
      {:ok, session} = Mock.start_session(session_id: "seed-1")
      assert session.session_id == "seed-1"
    end
  end

  describe "prompt/2 with a static event list script" do
    test "returns the events and records the prompt" do
      events = [Event.new(:text, %{text: "hi"}), Event.new(:result, %{text: "hi"})]
      {:ok, session} = Mock.start_session(scripts: [events])

      {:ok, stream, session} = Mock.prompt(session, "hello")

      assert Enum.to_list(stream) == events
      assert Mock.history(session) == ["hello"]
      assert Mock.remaining(session) == 0
    end

    test "consumes scripts in order across multiple prompts" do
      script_a = [Event.new(:result, %{text: "a"})]
      script_b = [Event.new(:result, %{text: "b"})]

      {:ok, session} = Mock.start_session(scripts: [script_a, script_b])

      {:ok, stream_a, session} = Mock.prompt(session, "first")
      assert Enum.to_list(stream_a) == script_a

      {:ok, stream_b, session} = Mock.prompt(session, "second")
      assert Enum.to_list(stream_b) == script_b

      assert Mock.history(session) == ["first", "second"]
    end

    test "returns :no_script when the script list is exhausted" do
      {:ok, session} = Mock.start_session(scripts: [])
      assert {:error, :no_script} = Mock.prompt(session, "nope")
    end
  end

  describe "prompt/2 with a function script" do
    test "passes the prompt into the function" do
      script = fn prompt ->
        [Event.new(:result, %{text: "you said: #{prompt}"})]
      end

      {:ok, session} = Mock.start_session(scripts: [script])

      {:ok, stream, _} = Mock.prompt(session, "ping")
      [event] = Enum.to_list(stream)

      assert event.kind == :result
      assert event.data.text == "you said: ping"
    end
  end

  describe "prompt/2 with {:error, reason} script" do
    test "returns the error synchronously" do
      {:ok, session} = Mock.start_session(scripts: [{:error, :boom}])
      assert {:error, :boom} = Mock.prompt(session, "go")
    end
  end

  describe "prompt/2 with {:raise, reason} script" do
    test "returns a stream that raises on consumption" do
      {:ok, session} = Mock.start_session(scripts: [{:raise, :exploded}])
      {:ok, stream, _} = Mock.prompt(session, "go")

      assert_raise RuntimeError, ~r/mock backend raised/, fn ->
        Enum.to_list(stream)
      end
    end
  end

  describe "update_session/2" do
    test "captures session_id from event data" do
      {:ok, session} = Mock.start_session([])
      assert session.session_id == nil

      session = Mock.update_session(session, %{session_id: "sess-xyz"})
      assert session.session_id == "sess-xyz"
    end

    test "ignores event data without a session_id" do
      {:ok, session} = Mock.start_session(session_id: "keep")
      assert Mock.update_session(session, %{text: "ignored"}).session_id == "keep"
    end
  end

  describe "terminate_session/1" do
    test "stops the backing agent process" do
      {:ok, session} = Mock.start_session([])
      agent_pid = session.agent

      assert Process.alive?(agent_pid)
      assert :ok = Mock.terminate_session(session)
      refute Process.alive?(agent_pid)
    end

    test "is idempotent when the agent is already down" do
      {:ok, session} = Mock.start_session([])
      Mock.terminate_session(session)
      assert :ok = Mock.terminate_session(session)
    end
  end
end
