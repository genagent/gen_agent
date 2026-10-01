defmodule GenAgent.Backends.ClaudeTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.StreamEvent
  alias GenAgent.Backends.Claude

  defp stream_event(type, data), do: %StreamEvent{type: type, data: data, raw: ""}

  defp fake_stream(events) do
    fn _prompt, _opts -> events end
  end

  defp recording_stream(ref, events) do
    test_pid = self()

    fn prompt, opts ->
      send(test_pid, {ref, prompt, opts})
      events
    end
  end

  describe "start_session/1" do
    test "builds a session with the given opts" do
      {:ok, session} =
        Claude.start_session(
          stream_fn: fake_stream([]),
          working_dir: "/tmp",
          model: "sonnet"
        )

      assert session.opts[:working_dir] == "/tmp"
      assert session.opts[:model] == "sonnet"
      assert session.session_id == nil
      refute Keyword.has_key?(session.opts, :stream_fn)
    end

    test "aliases :cwd to :working_dir for ergonomics" do
      {:ok, session} = Claude.start_session(stream_fn: fake_stream([]), cwd: "/home/me")

      assert session.opts[:working_dir] == "/home/me"
      refute Keyword.has_key?(session.opts, :cwd)
    end

    test "does not override an explicit :working_dir with :cwd" do
      {:ok, session} =
        Claude.start_session(
          stream_fn: fake_stream([]),
          cwd: "/ignored",
          working_dir: "/kept"
        )

      assert session.opts[:working_dir] == "/kept"
    end
  end

  describe "prompt/2" do
    test "forwards prompt and opts to the injected stream_fn" do
      ref = make_ref()
      events = [stream_event("result", %{"result" => "ok"})]

      {:ok, session} =
        Claude.start_session(
          stream_fn: recording_stream(ref, events),
          working_dir: "/tmp",
          model: "sonnet"
        )

      {:ok, _stream, ^session} = Claude.prompt(session, "hello")

      assert_receive {^ref, "hello", opts}
      assert opts[:working_dir] == "/tmp"
      assert opts[:model] == "sonnet"
      refute Keyword.has_key?(opts, :resume)
    end

    test "translates the stream into GenAgent.Event values" do
      events = [
        stream_event("system", %{}),
        stream_event("assistant", %{"content" => [%{"type" => "text", "text" => "hi"}]}),
        stream_event("result", %{"result" => "done", "session_id" => "sess-1"})
      ]

      {:ok, session} = Claude.start_session(stream_fn: fake_stream(events))
      {:ok, stream, _session} = Claude.prompt(session, "go")

      translated = Enum.to_list(stream)
      assert Enum.map(translated, & &1.kind) == [:text, :result]
      assert List.last(translated).data.session_id == "sess-1"
    end

    test "passes :resume on the second turn after update_session captures session_id" do
      ref = make_ref()
      events = [stream_event("result", %{"result" => "ok", "session_id" => "sess-42"})]

      {:ok, session} =
        Claude.start_session(
          stream_fn: recording_stream(ref, events),
          working_dir: "/tmp"
        )

      {:ok, stream, session} = Claude.prompt(session, "first")
      _ = Enum.to_list(stream)

      # simulate what GenAgent.Server does when it sees the :result event
      session = Claude.update_session(session, %{session_id: "sess-42"})

      {:ok, _stream, _session} = Claude.prompt(session, "second")

      assert_receive {^ref, "first", first_opts}
      refute Keyword.has_key?(first_opts, :resume)

      assert_receive {^ref, "second", second_opts}
      assert second_opts[:resume] == "sess-42"
    end

    test "wraps a raising stream_fn in {:error, ...}" do
      raising = fn _prompt, _opts -> raise "boom" end

      {:ok, session} = Claude.start_session(stream_fn: raising)

      assert {:error, {:stream_fn_raised, _}} = Claude.prompt(session, "anything")
    end
  end

  describe "update_session/2" do
    test "captures session_id from a terminal event data map" do
      {:ok, session} = Claude.start_session(stream_fn: fake_stream([]))

      session = Claude.update_session(session, %{session_id: "sess-xyz"})
      assert session.session_id == "sess-xyz"
    end

    test "ignores data without a session_id" do
      {:ok, session} = Claude.start_session(stream_fn: fake_stream([]), session_id: nil)

      session = Claude.update_session(session, %{text: "no id here"})
      assert session.session_id == nil
    end
  end

  describe "resume_session/2" do
    test "builds a session pre-loaded with the given session_id" do
      {:ok, session} =
        Claude.resume_session("sess-prior",
          stream_fn: fake_stream([]),
          working_dir: "/tmp"
        )

      assert session.session_id == "sess-prior"
      assert session.opts[:working_dir] == "/tmp"
    end
  end

  describe "terminate_session/1" do
    test "is a no-op" do
      {:ok, session} = Claude.start_session(stream_fn: fake_stream([]))
      assert :ok = Claude.terminate_session(session)
    end
  end
end
