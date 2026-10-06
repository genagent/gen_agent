defmodule GenAgent.Backends.MockTest do
  use ExUnit.Case, async: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgent.Support.TestAgent

  defmodule ApplicationAgent do
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, opts, %{}}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

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

    test "can fail startup without creating a session" do
      assert {:error, :refused} = Mock.start_session(start_error: :refused)
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
      assert Mock.history(session) == ["nope"]
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

  test "public API runs a gated turn and reads its history by name" do
    name = "mock-public-#{System.unique_integer([:positive])}"
    events = [Event.new(:result, %{text: "released"})]

    {:ok, pid} =
      GenAgent.start_agent(ApplicationAgent,
        name: name,
        backend: Mock,
        scripts: [Mock.gate(:first, events)]
      )

    on_exit(fn -> if Process.alive?(pid), do: GenAgent.stop(name) end)

    {:ok, ref} = GenAgent.tell_with_completion(name, "work")
    assert_receive {:mock_blocked, :first, turn_pid}
    assert Mock.history(name) == ["work"]
    assert GenAgent.runtime_snapshot(name).phase == :processing

    send(turn_pid, {:mock_release, :first})
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, response}}
    assert response.text == "released"

    assert :ok = GenAgent.stop(name)
    assert Mock.history(name) == {:error, :not_found}
  end

  test "a scripted startup failure propagates through start_agent/2" do
    assert {:error, {:backend_start_failed, :refused}} =
             GenAgent.start_agent(ApplicationAgent,
               name: "mock-start-error-#{System.unique_integer([:positive])}",
               backend: Mock,
               start_error: :refused
             )
  end

  test "the test agent can observe stream and termination callbacks" do
    name = "mock-hook-#{System.unique_integer([:positive])}"
    observer = self()

    {:ok, pid} =
      GenAgent.start_agent(TestAgent,
        name: name,
        backend: Mock,
        scripts: [[Event.new(:result, %{text: "done"})]],
        stream_event_handler: fn event, state ->
          send(observer, {:stream_hook, event.kind})
          state
        end,
        terminate_handler: fn reason, _state -> send(observer, {:terminate_hook, reason}) end
      )

    on_exit(fn -> if Process.alive?(pid), do: GenAgent.stop(name) end)

    assert {:ok, _} = GenAgent.ask(name, "work")
    assert_receive {:stream_hook, :result}
    assert :ok = GenAgent.stop(name)
    assert_receive {:terminate_hook, :shutdown}
  end
end
