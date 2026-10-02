defmodule GenAgent.Backends.ClaudeExecutableConformanceTest do
  use GenAgent.Test.BackendConformance, async: false, lifecycle: true

  alias GenAgent.Test.BackendConformance.Agent

  import GenAgent.TestDownAssertions

  @moduletag capture_log: true

  defp conformance_setup(context) do
    %{
      backend: GenAgent.Backends.Claude,
      agent_opts: [binary: context.binary, working_dir: context.directory],
      first_prompt: "first prompt",
      second_prompt: "follow-up prompt",
      error_prompt: "fail",
      hold_prompt: "hold",
      assert_error: fn reason ->
        assert match?(%{provider: :claude, subtype: "error_max_turns"}, reason)
      end,
      assert_threaded: fn first, _second ->
        assert flag_value(args(context.directory, :resume), "--resume") == first.session_id
      end
    }
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

  test "real wrapper executes a CLI path containing spaces", context do
    spaced_dir = Path.join(context.directory, "with space")
    File.mkdir_p!(spaced_dir)
    spaced_binary = Path.join(spaced_dir, "claude fixture")
    File.cp!(context.binary, spaced_binary)
    File.chmod!(spaced_binary, 0o755)

    name = start_agent(%{context | binary: spaced_binary})

    assert {:ok, response} = GenAgent.ask(name, "first prompt")
    assert response.text == "fixture-reply"
    assert response.session_id == "fixture-session"
    assert ["--", "first prompt"] == Enum.take(args(spaced_dir, :fresh), -2)
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

  test "named recordings preserve bytes and recorded exit status", context do
    directory = Path.expand("../../fixtures/claude/2.1.284", __DIR__)
    manifest = directory |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    for {scenario, metadata} <- manifest["scenarios"] do
      assert {output, status} =
               System.cmd(context.binary, metadata["argv"],
                 env: [
                   {"GEN_AGENT_RECORDING_DIR", directory},
                   {"GEN_AGENT_RECORDING", scenario},
                   {"GEN_AGENT_RECORDING_EXIT_STATUS", to_string(metadata["exit_status"])}
                 ]
               )

      assert output == File.read!(Path.join(directory, scenario <> ".jsonl"))
      assert status == metadata["exit_status"]

      name =
        start_agent(context,
          env: [
            {"GEN_AGENT_RECORDING_DIR", directory},
            {"GEN_AGENT_RECORDING", scenario},
            {"GEN_AGENT_RECORDING_EXIT_STATUS", to_string(metadata["exit_status"])}
          ]
        )

      recorded_result =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["type"] == "result"))

      if metadata["exit_status"] == 0 do
        assert {:ok, response} = GenAgent.ask(name, "replay")
        assert response.session_id == recorded_result["session_id"]
        assert response.text == recorded_result["result"]
      else
        # Issue #118: the recorded errors array currently yields message :unknown.
        assert {:error, %{message: :unknown, subtype: "error_max_turns", session_id: session_id}} =
                 GenAgent.ask(name, "replay")

        assert session_id == recorded_result["session_id"]
      end
    end
  end

  for action <- [:interrupt, :watchdog, :stop] do
    @tag action: action
    test "#{action} exits the fixture and child with the Forcola runner", context do
      Application.put_env(:claude_wrapper, :runner, ClaudeWrapper.Runner.Forcola)
      assert ClaudeWrapper.Runner.impl() == ClaudeWrapper.Runner.Forcola
      pid_file = Path.join(context.directory, "process.pids")

      on_exit(fn ->
        if File.exists?(pid_file) do
          for pid <- read_pids(pid_file), os_alive?(pid) do
            System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
          end
        end
      end)

      watchdog_ms = if context.action == :watchdog, do: 2_000, else: 10_000
      name = start_agent(context, watchdog_ms: watchdog_ms)
      assert {:ok, ref} = GenAgent.tell(name, "process-tree")
      assert_receive {:stream_event, :text, task_pid}, 1_000
      task_monitor = Process.monitor(task_pid)
      pids = read_pids(pid_file)
      assert length(pids) == 2
      assert Enum.all?(pids, &os_alive?/1)

      case context.action do
        :interrupt ->
          assert :ok = GenAgent.interrupt(name)
          assert_receive {:failed, ^ref, :interrupted}, 1_000
          assert {:error, :interrupted} = GenAgent.poll(name, ref)

        :watchdog ->
          assert_receive {:failed, ^ref, :timeout}, 3_000
          assert {:error, :timeout} = GenAgent.poll(name, ref)

        :stop ->
          assert :ok = GenAgent.stop(name)
      end

      assert_killed_or_gone(task_monitor, task_pid, 1_000)
      assert_os_exited(pids, System.monotonic_time(:millisecond) + 5_000)
    end
  end

  defp read_pids(path), do: path |> File.read!() |> String.split("\n", trim: true)

  defp os_alive?(pid) do
    {_output, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    status == 0
  end

  defp assert_os_exited(pids, deadline) do
    alive = Enum.filter(pids, &os_alive?/1)

    cond do
      alive == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("OS processes still alive: #{inspect(alive)}")

      true ->
        Process.sleep(20)
        assert_os_exited(alive, deadline)
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
