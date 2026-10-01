defmodule GenAgent.Backends.ClaudeExecutableConformanceTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      {observer, backend_opts} = Keyword.pop!(opts, :observer)
      {:ok, backend_opts, %{observer: observer, responses: [], errors: []}}
    end

    @impl true
    def handle_stream_event(event, state) do
      send(state.observer, {:stream_event, event.kind, self()})
      state
    end

    @impl true
    def handle_response(ref, response, state) do
      send(state.observer, {:completed, ref})
      {:noreply, %{state | responses: [response | state.responses]}}
    end

    @impl true
    def handle_error(ref, reason, state) do
      send(state.observer, {:failed, ref, reason})
      {:noreply, %{state | errors: [reason | state.errors]}}
    end
  end

  setup do
    previous_runner = Application.get_env(:claude_wrapper, :runner)
    Application.put_env(:claude_wrapper, :runner, ClaudeWrapper.Runner.Port)

    directory =
      Path.join(System.tmp_dir!(), "gen-agent-claude-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    binary = Path.join(directory, "claude-fixture")
    File.cp!(Path.expand("../../fixtures/claude_cli.sh", __DIR__), binary)
    File.chmod!(binary, 0o755)

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:claude_wrapper, :runner, previous_runner)
      else
        Application.delete_env(:claude_wrapper, :runner)
      end

      File.rm_rf!(directory)
    end)

    %{binary: binary, directory: directory}
  end

  defp start_agent(context, opts \\ []) do
    name = "claude-executable-#{System.unique_integer([:positive])}"

    agent_opts =
      [
        name: name,
        backend: GenAgent.Backends.Claude,
        observer: self(),
        binary: context.binary,
        working_dir: context.directory
      ] ++ opts

    assert {:ok, _pid} = GenAgent.start_agent(Agent, agent_opts)

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    name
  end

  test "real wrapper and Port runner preserve arguments, events, and native identity on resume",
       context do
    assert ClaudeWrapper.Runner.impl() == ClaudeWrapper.Runner.Port

    name =
      start_agent(context,
        model: "fixture-model",
        system_prompt: "fixture system",
        max_turns: 2,
        permission_mode: :plan,
        env: [{"GEN_AGENT_FIXTURE", "configured"}]
      )

    assert {:ok, first} = GenAgent.ask(name, "first prompt")
    assert first.text == "fixture-reply"
    assert first.session_id == "fixture-session"
    assert first.usage == %{input_tokens: 3, output_tokens: 2}

    assert Enum.map(first.events, & &1.kind) ==
             [:text, :text, :tool_use, :tool_result, :usage, :result]

    assert Enum.at(first.events, 2).data["id"] == "call-1"
    assert Enum.at(first.events, 3).data["tool_use_id"] == "call-1"

    fresh_args = args(context.directory, :fresh)
    assert "--print" in fresh_args
    assert "--output-format" in fresh_args
    assert "stream-json" in fresh_args
    assert "--include-partial-messages" in fresh_args
    assert ["--", "first prompt"] == Enum.take(fresh_args, -2)
    refute "--resume" in fresh_args
    assert "fixture-model" in fresh_args
    assert "fixture system" in fresh_args
    assert "2" in fresh_args
    assert "plan" in fresh_args

    assert context.directory |> Path.basename() ==
             context.directory
             |> Path.join("fresh.cwd")
             |> File.read!()
             |> String.trim()
             |> Path.basename()

    assert File.read!(Path.join(context.directory, "fresh.env")) == "configured\n"

    assert {:ok, second} = GenAgent.ask(name, "follow-up prompt")
    assert second.session_id == "fixture-session"
    resume_args = args(context.directory, :resume)
    assert ["--", "follow-up prompt"] == Enum.take(resume_args, -2)

    assert Enum.chunk_every(resume_args, 2, 1, :discard)
           |> Enum.member?(["--resume", "fixture-session"])

    assert File.read!(Path.join(context.directory, "resume.env")) == "configured\n"
  end

  test "typed CLI failure and truncated stream reach GenAgent as errors", context do
    name = start_agent(context)

    assert {:error,
            %{provider: :claude, subtype: "error_max_turns", session_id: "fixture-session"}} =
             GenAgent.ask(name, "fail")

    assert {:error, "stream_truncated"} = GenAgent.ask(name, "truncated")
    assert length(GenAgent.status(name).agent_state.errors) == 2
  end

  test "session-id applies to the first turn and resume replaces it later", context do
    session_id = "11111111-1111-4111-8111-111111111111"
    name = start_agent(context, session_id: session_id)

    assert {:ok, _} = GenAgent.ask(name, "first prompt")
    fresh_args = args(context.directory, :fresh)
    assert flag_value(fresh_args, "--session-id") == session_id
    refute "--resume" in fresh_args

    assert {:ok, _} = GenAgent.ask(name, "second prompt")
    resume_args = args(context.directory, :resume)
    assert flag_value(resume_args, "--resume") == "fixture-session"
    refute "--session-id" in resume_args
  end

  test "continue applies to the first turn and resume replaces it later", context do
    name = start_agent(context, continue_session: true)

    assert {:ok, _} = GenAgent.ask(name, "first prompt")
    assert "--continue" in args(context.directory, :fresh)

    assert {:ok, _} = GenAgent.ask(name, "second prompt")
    resume_args = args(context.directory, :resume)
    assert flag_value(resume_args, "--resume") == "fixture-session"
    refute "--continue" in resume_args
  end

  test "disabled session persistence is rejected before invoking the CLI", context do
    assert {:error, {:backend_start_failed, {:unsupported_option, :no_session_persistence}}} =
             GenAgent.start_agent(Agent,
               name: "claude-no-persistence-#{System.unique_integer([:positive])}",
               backend: GenAgent.Backends.Claude,
               observer: self(),
               binary: context.binary,
               working_dir: context.directory,
               no_session_persistence: true
             )

    refute File.exists?(Path.join(context.directory, "fresh.args"))
    refute File.exists?(Path.join(context.directory, "resume.args"))
  end

  for action <- [:interrupt, :watchdog, :stop, :kill] do
    @tag action: action
    test "#{action} stops the BEAM task on the executable streaming path", context do
      action = context.action
      watchdog_ms = if action == :watchdog, do: 500, else: 5_000
      name = start_agent(context, watchdog_ms: watchdog_ms)
      assert {:ok, ref} = GenAgent.tell(name, "hold")
      assert_receive {:stream_event, :text, task_pid}, 1_000
      task_monitor = Process.monitor(task_pid)

      case action do
        :interrupt ->
          assert :ok = GenAgent.interrupt(name)
          assert_receive {:failed, ^ref, :interrupted}, 1_000
          assert {:error, :interrupted} = GenAgent.poll(name, ref)

        :watchdog ->
          assert_receive {:failed, ^ref, :timeout}, 1_000
          assert {:error, :timeout} = GenAgent.poll(name, ref)

        :stop ->
          assert :ok = GenAgent.stop(name)

        :kill ->
          Process.exit(GenAgent.whereis(name), :kill)
      end

      assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :killed}, 1_000
    end
  end

  defp args(directory, mode) do
    directory
    |> Path.join("#{mode}.args")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp flag_value(args, flag) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^flag, value] -> value
      _ -> nil
    end)
  end
end
