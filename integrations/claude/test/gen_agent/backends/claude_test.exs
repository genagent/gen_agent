defmodule GenAgent.Backends.ClaudeTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.StreamEvent
  alias ClaudeWrapper.ToolPattern
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
    test "rejects disabled session persistence" do
      assert {:error, {:unsupported_option, :no_session_persistence}} =
               Claude.start_session(no_session_persistence: true)

      assert {:ok, _session} = Claude.start_session(no_session_persistence: false)
    end

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

  describe "option validation" do
    test "rejects invalid enum values" do
      assert {:error, {:invalid_option, :permission_mode, :acceptEdits}} =
               Claude.start_session(permission_mode: :acceptEdits)

      assert {:error, {:invalid_option, :effort, :extreme}} =
               Claude.start_session(effort: :extreme)

      assert {:ok, _} = Claude.start_session(permission_mode: :accept_edits, effort: :xhigh)
    end

    test "rejects a non-binary :json_schema" do
      assert {:error, {:invalid_option, :json_schema, %{"type" => "object"}}} =
               Claude.start_session(json_schema: %{"type" => "object"})

      assert {:ok, _} = Claude.start_session(json_schema: ~s({"type":"object"}))
    end

    test "rejects list options given in the wrong shape" do
      for key <- [:allowed_tools, :disallowed_tools, :tools, :add_dir, :mcp_config] do
        assert {:error, {:invalid_option, ^key, 123}} = Claude.start_session([{key, 123}])
      end

      assert {:error, {:invalid_option, :allowed_tools, "Read"}} =
               Claude.start_session(allowed_tools: "Read")

      assert {:error, {:invalid_option, :tools, ["Read", :bash]}} =
               Claude.start_session(tools: ["Read", :bash])

      assert {:ok, _} =
               Claude.start_session(
                 allowed_tools: ["Read"],
                 add_dir: "/tmp",
                 mcp_config: ["a.json", "b.json"]
               )
    end

    test "accepts wrapper tool patterns but rejects malformed pattern structs" do
      pattern = ToolPattern.tool_with_args("Bash", "git status:*")

      assert {:ok, _} =
               Claude.start_session(allowed_tools: [pattern], disallowed_tools: [pattern])

      invalid = %ToolPattern{value: 42}

      assert {:error, {:invalid_option, :allowed_tools, [^invalid]}} =
               Claude.start_session(allowed_tools: [invalid])
    end

    test "rejects unknown and misspelled keys" do
      assert {:error, {:unknown_option, :permision_mode}} =
               Claude.start_session(allowed_tools: ["Read"], permision_mode: :plan)

      assert {:error, {:unknown_option, :sandbox}} = Claude.start_session(sandbox: :read_only)
    end

    test "accepts every option the locked wrapper supports" do
      opts = [
        binary: :bundled,
        working_dir: "/tmp",
        env: [{"KEY", "value"}],
        timeout: 1000,
        verbose: true,
        debug: false,
        settings: ~s({"a":1}),
        append_system_prompt_file: "p.md",
        permission_prompt_tool: "mcp__x__y",
        exclude_dynamic_system_prompt_sections: true,
        max_thinking_tokens: 100,
        agents_json: "{}",
        from_pr: "12",
        debug_filter: "api",
        debug_file: "d.log",
        name: "n",
        output_format: :stream_json,
        input_format: :text,
        fork_session: true,
        tmux: false,
        prompt_suggestions: true,
        replay_user_messages: true,
        bare: true,
        disable_slash_commands: true,
        include_hook_events: true,
        safe_mode: true,
        worktree: "wt",
        files: ["a=b"],
        plugin_dirs: ["/p"],
        plugin_urls: ["https://x"],
        betas: ["b1", "b2"],
        no_session_persistence: false
      ]

      assert {:ok, _} = Claude.start_session(opts)
      assert {:ok, _} = Claude.start_session(env: %{"A" => "b", "C" => false})
    end

    test "rejects malformed env contents" do
      for bad <- [
            %{"FOO" => %{}},
            [{"FOO", 1}],
            ["FOO=bar"],
            [{1, "x"}],
            "FOO=bar",
            URI.parse("https://example.com")
          ] do
        assert {:error, {:invalid_option, :env, ^bad}} = Claude.start_session(env: bad)
      end
    end

    test "rejects non-keyword options" do
      assert {:error, {:invalid_options, [:oops]}} = Claude.start_session([:oops])
    end

    test "resume_session/2 validates through start_session/1" do
      assert {:error, {:invalid_option, :permission_mode, :acceptEdits}} =
               Claude.resume_session("sid", permission_mode: :acceptEdits)

      assert {:error, {:unknown_option, :permision_mode}} =
               Claude.resume_session("sid", permision_mode: :plan)

      assert {:ok, %{session_id: "sid"}} =
               Claude.resume_session("sid", stream_fn: fake_stream([]), cwd: "/tmp")
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

    test "rejects disabled session persistence" do
      assert {:error, {:unsupported_option, :no_session_persistence}} =
               Claude.resume_session("sess-prior", no_session_persistence: true)
    end
  end

  describe "terminate_session/1" do
    test "is a no-op" do
      {:ok, session} = Claude.start_session(stream_fn: fake_stream([]))
      assert :ok = Claude.terminate_session(session)
    end
  end
end
