defmodule GenAgent.Backends.CodexTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.JsonLineEvent
  alias GenAgent.Backends.Codex

  defp event(type, data), do: %JsonLineEvent{event_type: type, data: data, raw: ""}

  defp fake_exec(json_events) do
    fn _prompt, _session -> {:ok, json_events} end
  end

  defp recording_exec(ref, json_events) do
    test_pid = self()

    fn prompt, session ->
      send(test_pid, {ref, prompt, session.thread_id})
      {:ok, json_events}
    end
  end

  describe "start_session/1" do
    test "builds a session with exec_opts and empty thread_id" do
      {:ok, session} =
        Codex.start_session(
          exec_fn: fake_exec([]),
          sandbox: :read_only,
          skip_git_repo_check: true,
          model: "gpt-5"
        )

      assert session.thread_id == nil
      assert session.exec_opts[:sandbox] == :read_only
      assert session.exec_opts[:skip_git_repo_check] == true
      assert session.exec_opts[:model] == "gpt-5"
      refute Keyword.has_key?(session.exec_opts, :exec_fn)
    end

    test "splits config options out of exec_opts" do
      {:ok, session} =
        Codex.start_session(
          exec_fn: fake_exec([]),
          working_dir: "/tmp",
          model: "gpt-5"
        )

      refute Keyword.has_key?(session.exec_opts, :working_dir)
      assert session.exec_opts[:model] == "gpt-5"
    end

    test "aliases :cwd to :working_dir" do
      {:ok, session} = Codex.start_session(exec_fn: fake_exec([]), cwd: "/home/me")

      refute Keyword.has_key?(session.exec_opts, :cwd)
      refute Keyword.has_key?(session.exec_opts, :working_dir)
    end

    test "rejects invalid sandbox modes before a prompt" do
      for value <- [:invalid, "read-only", 123] do
        assert {:error, {:invalid_option, :sandbox, ^value}} =
                 Codex.start_session(sandbox: value)

        assert {:error, {:invalid_option, :sandbox, ^value}} =
                 Codex.resume_session("thread-id", sandbox: value)
      end

      for mode <- [:read_only, :workspace_write, :danger_full_access] do
        assert {:ok, _session} = Codex.start_session(sandbox: mode)
      end
    end

    test "rejects invalid working directories, including the :cwd alias" do
      for value <- [:invalid, 123] do
        assert {:error, {:invalid_option, :working_dir, ^value}} =
                 Codex.start_session(working_dir: value)

        assert {:error, {:invalid_option, :working_dir, ^value}} =
                 Codex.start_session(cwd: value)

        assert {:error, {:invalid_option, :working_dir, ^value}} =
                 Codex.resume_session("thread-id", working_dir: value)
      end
    end
  end

  describe "usage deltas across turns" do
    defp completed_turn(input, output) do
      [
        event("thread.started", %{"thread_id" => "thread-u"}),
        event("turn.completed", %{
          "usage" => %{"input_tokens" => input, "output_tokens" => output}
        })
      ]
    end

    # Runs one turn and applies the terminal :result like GenAgent.Server.
    defp run_turn(session, events) do
      {:ok, stream, session} = Codex.prompt(%{session | exec_fn: fake_exec(events)}, "go")
      translated = Enum.to_list(stream)
      result = List.last(translated)

      usage =
        Enum.find_value(translated, fn
          %{kind: :usage, data: data} -> data
          _ -> nil
        end)

      session =
        if result.kind == :result, do: Codex.update_session(session, result.data), else: session

      {session, usage}
    end

    test "first turn reports the full total, resumed turn reports the delta" do
      {:ok, session} = Codex.start_session(exec_fn: fake_exec([]))

      {session, first} = run_turn(session, completed_turn(14_956, 5))
      assert first == %{input_tokens: 14_956, output_tokens: 5}

      {session, second} = run_turn(session, completed_turn(29_938, 15))
      assert second == %{input_tokens: 14_982, output_tokens: 10}

      {_session, third} = run_turn(session, completed_turn(29_938, 15))
      assert third == %{input_tokens: 0, output_tokens: 0}
    end

    test "externally resumed session omits usage on the first turn, then reports deltas" do
      {:ok, session} = Codex.resume_session("thread-u", exec_fn: fake_exec([]))

      {session, first} = run_turn(session, completed_turn(31_279, 11))
      assert first == nil
      assert session.usage_total == %{input_tokens: 31_279, output_tokens: 11}

      {_session, second} = run_turn(session, completed_turn(40_000, 20))
      assert second == %{input_tokens: 8721, output_tokens: 9}
    end

    test "a failed turn keeps the baseline so the next delta includes it" do
      {:ok, session} = Codex.start_session(exec_fn: fake_exec([]))
      {session, _} = run_turn(session, completed_turn(100, 10))

      failed = [
        event("thread.started", %{"thread_id" => "thread-u"}),
        event("turn.failed", %{"error" => "boom"})
      ]

      {session, nil} = run_turn(session, failed)
      assert session.usage_total.input_tokens == 100

      {_session, usage} = run_turn(session, completed_turn(180, 16))
      assert usage == %{input_tokens: 80, output_tokens: 6}
    end

    test "checkpoint_session keeps the usage baseline" do
      {:ok, session} = Codex.start_session(exec_fn: fake_exec([]))
      {session, _} = run_turn(session, completed_turn(100, 10))
      session = Codex.checkpoint_session(session, "thread-u")

      {_session, usage} = run_turn(session, completed_turn(130, 12))
      assert usage == %{input_tokens: 30, output_tokens: 2}
    end

    test "a reset total suppresses the delta and rebaselines" do
      {:ok, session} = Codex.start_session(exec_fn: fake_exec([]))
      {session, _} = run_turn(session, completed_turn(1000, 100))

      {session, reset} = run_turn(session, completed_turn(50, 5))
      assert reset == nil
      assert session.usage_total == %{input_tokens: 50, output_tokens: 5}

      {_session, usage} = run_turn(session, completed_turn(70, 9))
      assert usage == %{input_tokens: 20, output_tokens: 4}
    end

    test "a turn without usage clears the baseline instead of leaving it stale" do
      {:ok, session} = Codex.start_session(exec_fn: fake_exec([]))
      {session, _} = run_turn(session, completed_turn(100, 10))

      {session, nil} = run_turn(session, [event("turn.completed", %{})])
      assert session.usage_total == %{}

      {_session, nil} = run_turn(session, completed_turn(300, 30))
    end
  end

  describe "prompt/2" do
    test "forwards prompt and session to the exec_fn" do
      ref = make_ref()

      events = [
        event("thread.started", %{"thread_id" => "thread-1"}),
        event("turn.completed", %{})
      ]

      {:ok, session} = Codex.start_session(exec_fn: recording_exec(ref, events))

      {:ok, _stream, ^session} = Codex.prompt(session, "hello")

      assert_receive {^ref, "hello", nil}
    end

    test "translates JsonLineEvents into GenAgent.Events" do
      events = [
        event("thread.started", %{"thread_id" => "thread-xyz"}),
        event("turn.started", %{}),
        event("item.completed", %{
          "item" => %{"type" => "agent_message", "text" => "hi"}
        }),
        event("turn.completed", %{
          "usage" => %{"input_tokens" => 5, "output_tokens" => 1}
        })
      ]

      {:ok, session} = Codex.start_session(exec_fn: fake_exec(events))
      {:ok, stream, _} = Codex.prompt(session, "go")

      translated = Enum.to_list(stream)

      assert Enum.map(translated, & &1.kind) == [:text, :usage, :result]
      assert List.last(translated).data.session_id == "thread-xyz"
    end

    test "passes the captured thread_id to the exec_fn on the second turn" do
      ref = make_ref()

      events = [
        event("thread.started", %{"thread_id" => "thread-resume"}),
        event("turn.completed", %{})
      ]

      {:ok, session} = Codex.start_session(exec_fn: recording_exec(ref, events))

      {:ok, stream, session} = Codex.prompt(session, "first")
      _ = Enum.to_list(stream)

      # Simulate what GenAgent.Server does when it sees the terminal :result.
      session = Codex.update_session(session, %{session_id: "thread-resume"})

      {:ok, _stream, _} = Codex.prompt(session, "second")

      assert_receive {^ref, "first", nil}
      assert_receive {^ref, "second", "thread-resume"}
    end

    test "propagates an error from the exec_fn" do
      failing = fn _prompt, _session -> {:error, :codex_missing} end
      {:ok, session} = Codex.start_session(exec_fn: failing)

      assert {:error, :codex_missing} = Codex.prompt(session, "anything")
    end

    test "wraps a raising exec_fn" do
      raising = fn _prompt, _session -> raise "kaboom" end
      {:ok, session} = Codex.start_session(exec_fn: raising)

      assert {:error, {:exec_fn_raised, _}} = Codex.prompt(session, "go")
    end
  end

  describe "update_session/2" do
    test "captures thread_id from a terminal event" do
      {:ok, session} = Codex.start_session(exec_fn: fake_exec([]))

      session = Codex.update_session(session, %{session_id: "thread-new"})
      assert session.thread_id == "thread-new"
    end

    test "ignores data without session_id" do
      {:ok, session} = Codex.start_session(exec_fn: fake_exec([]))

      session = Codex.update_session(session, %{text: "irrelevant"})
      assert session.thread_id == nil
    end
  end

  describe "resume_session/2" do
    test "returns a session pre-loaded with the given thread_id" do
      {:ok, session} =
        Codex.resume_session("thread-prior",
          exec_fn: fake_exec([]),
          sandbox: :read_only
        )

      assert session.thread_id == "thread-prior"
      assert session.exec_opts[:sandbox] == :read_only
    end
  end

  describe "terminate_session/1" do
    test "is a no-op" do
      {:ok, session} = Codex.start_session(exec_fn: fake_exec([]))
      assert :ok = Codex.terminate_session(session)
    end
  end
end
