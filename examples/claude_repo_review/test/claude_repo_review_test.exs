defmodule ClaudeRepoReviewTest do
  use ExUnit.Case, async: false

  alias ClaudeRepoReview.{Reviewer, Supervisor}

  @fixtures Path.expand("../../../integrations/claude/test/fixtures", __DIR__)
  @recordings Path.join(@fixtures, "claude/2.1.284")

  setup do
    dir = Path.join(System.tmp_dir!(), "claude-review-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    binary = Path.join(dir, "claude_cli.sh")
    File.cp!(Path.join(@fixtures, "claude_cli.sh"), binary)
    File.chmod!(binary, 0o755)
    supervisor = start_supervised!(Supervisor)
    %{dir: dir, binary: binary, supervisor: supervisor}
  end

  for recording <- ["text", "plan"] do
    @tag recording: recording
    test "replays #{recording} and forwards review settings", context do
      assert ClaudeWrapper.Runner.impl() == ClaudeWrapper.Runner.Forcola
      assert {:ok, pid} = Supervisor.start_reviewer(opts(context))
      assert Process.alive?(context.supervisor)

      assert [{:undefined, ^pid, :worker, _}] =
               DynamicSupervisor.which_children(ClaudeRepoReview.AgentSupervisor)

      assert {:ok, text} = Reviewer.review("reviewer")
      assert text == String.trim(result(context.recording)["result"])
      if context.recording == "text", do: assert(text == "pong")

      args = args(context.dir, "fresh")
      assert_sequence(args, ["--permission-mode", "plan"])
      assert_sequence(args, ["--allowed-tools", "Read", "Glob", "Grep"])
      assert_sequence(args, ["--setting-sources", "user"])
      assert_sequence(args, ["--max-turns", "20"])
      assert "--strict-mcp-config" in args
      assert "--exclude-dynamic-system-prompt-sections" in args
      assert "--system-prompt" in args
      refute "--mcp-config" in args
      refute "--dangerously-skip-permissions" in args
      cwd = File.read!(Path.join(context.dir, "fresh.cwd")) |> String.trim()
      assert File.stat!(cwd).inode == File.stat!(context.dir).inode

      monitor = Process.monitor(pid)
      assert :ok = Supervisor.stop_reviewer("reviewer")
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}
      assert DynamicSupervisor.which_children(ClaudeRepoReview.AgentSupervisor) == []
      assert :ok = stop_supervised(Supervisor)
      refute Process.alive?(context.supervisor)
    end
  end

  @tag recording: "text"
  test "resumes a saved session through backend options after restart", context do
    assert {:ok, _} = Supervisor.start_reviewer(opts(context))
    assert {:ok, response} = GenAgent.ask("reviewer", "Review the repository.")
    session_id = response.session_id
    assert session_id == result("text")["session_id"]
    assert :ok = Supervisor.stop_reviewer("reviewer")
    assert {:ok, _} = Supervisor.start_reviewer(opts(context) ++ [resume: session_id])
    assert {:ok, "pong"} = Reviewer.review("reviewer")
    assert_sequence(args(context.dir, "resume"), ["--resume", session_id])
  end

  defp opts(context) do
    [
      name: "reviewer",
      cwd: context.dir,
      binary: context.binary,
      env: [
        {"GEN_AGENT_RECORDING", context.recording},
        {"GEN_AGENT_RECORDING_DIR", @recordings},
        {"GEN_AGENT_RECORDING_EXIT_STATUS", "0"}
      ]
    ]
  end

  defp result(recording) do
    @recordings
    |> Path.join(recording <> ".jsonl")
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["type"] == "result"))
  end

  defp args(dir, mode) do
    dir |> Path.join(mode <> ".args") |> File.read!() |> String.split("\n", trim: true)
  end

  defp assert_sequence(args, expected) do
    assert Enum.chunk_every(args, length(expected), 1, :discard) |> Enum.member?(expected)
  end
end
