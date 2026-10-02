defmodule GenAgent.Backends.CodexExecutableConformanceTest do
  use GenAgent.Test.BackendConformance, async: false, lifecycle: true

  alias GenAgent.CodexTranscripts, as: Transcripts

  @moduletag capture_log: true

  defp conformance_setup(context) do
    %{
      backend: GenAgent.Backends.Codex,
      agent_opts: [binary: context.binary, working_dir: context.directory],
      first_prompt: "first prompt",
      second_prompt: "follow-up prompt",
      error_prompt: "replay:failure",
      hold_prompt: "hold",
      assert_error: fn reason -> assert reason == Transcripts.failure() end,
      assert_threaded: fn first, _second ->
        resume_args = args(context.directory, :resume)
        assert Enum.take(resume_args, 2) == ["exec", "resume"]
        assert first.session_id in resume_args
        assert first.session_id == Transcripts.thread_id("resume-initial")
      end
    }
  end

  setup do
    previous_runner = Application.get_env(:codex_wrapper, :runner)
    Application.put_env(:codex_wrapper, :runner, CodexWrapper.Runner.Port)

    directory =
      Path.join(System.tmp_dir!(), "gen-agent-codex-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    binary = Path.join(directory, "codex-fixture")
    File.cp!(Path.expand("../../fixtures/codex_cli.sh", __DIR__), binary)
    File.chmod!(binary, 0o755)
    File.mkdir_p!(Path.join(directory, "codex"))
    File.cp_r!(Transcripts.directory(), Path.join(directory, "codex/0.157.1"))

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:codex_wrapper, :runner, previous_runner)
      else
        Application.delete_env(:codex_wrapper, :runner)
      end

      File.rm_rf!(directory)
    end)

    %{binary: binary, directory: directory}
  end

  test "config isolation reaches both CLI calls; profile applies only to fresh", context do
    name = start_agent(context, ignore_user_config: true, profile: "fixture-profile")

    assert {:ok, _first} = GenAgent.ask(name, "first prompt")
    fresh_args = args(context.directory, :fresh)
    assert "--ignore-user-config" in fresh_args

    assert Enum.chunk_every(fresh_args, 2, 1, :discard)
           |> Enum.member?(["--profile", "fixture-profile"])

    assert {:ok, _second} = GenAgent.ask(name, "follow-up prompt")
    resume_args = args(context.directory, :resume)
    assert "--ignore-user-config" in resume_args
    refute "--profile" in resume_args
  end

  defp start_agent(context, opts \\ []) do
    name = "codex-executable-#{System.unique_integer([:positive])}"

    agent_opts =
      [
        name: name,
        backend: GenAgent.Backends.Codex,
        observer: self(),
        binary: context.binary,
        working_dir: context.directory
      ] ++ opts

    assert {:ok, _pid} = GenAgent.start_agent(GenAgent.Test.BackendConformance.Agent, agent_opts)

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    name
  end

  test "real wrapper and Port runner preserve arguments, events, and native identity on resume",
       context do
    assert CodexWrapper.Runner.impl() == CodexWrapper.Runner.Port

    name =
      start_agent(context,
        model: "fixture-model",
        sandbox: :read_only,
        approval_policy: :never,
        config_overrides: ["mcp_servers.fixture.enabled=false"],
        enabled_features: ["fixture_feature"],
        disabled_features: ["other_feature"],
        images: ["/fixture/image.png"],
        output_schema: "/fixture/response.json",
        env: [{"GEN_AGENT_FIXTURE", "configured"}]
      )

    assert {:ok, first} = GenAgent.ask(name, "first prompt")
    assert first.text == "ok"
    assert first.session_id == Transcripts.thread_id("resume-initial")
    Transcripts.assert_events(first.events, "resume-initial")

    fresh_args = args(context.directory, :fresh)
    assert hd(fresh_args) == "exec"
    assert "--json" in fresh_args
    assert "fixture-model" in fresh_args
    assert "read-only" in fresh_args
    assert "first prompt" == List.last(fresh_args)

    assert Enum.chunk_every(fresh_args, 2, 1, :discard)
           |> Enum.member?(["--output-schema", "/fixture/response.json"])

    assert File.read!(Path.join(context.directory, "fresh.env")) == "configured\n"

    assert {:ok, second} = GenAgent.ask(name, "follow-up prompt")
    assert second.text == "42"
    Transcripts.assert_events(second.events, "resume-followup")
    assert second.session_id == first.session_id

    resume_args = args(context.directory, :resume)
    assert Enum.take(resume_args, 2) == ["exec", "resume"]
    assert first.session_id in resume_args
    assert "fixture-model" in resume_args
    assert "fixture_feature" in resume_args
    assert "other_feature" in resume_args
    assert "/fixture/image.png" in resume_args

    assert Enum.chunk_every(resume_args, 2, 1, :discard)
           |> Enum.member?(["--output-schema", "/fixture/response.json"])

    assert "follow-up prompt" == List.last(resume_args)
    assert Enum.any?(resume_args, &String.contains?(&1, "approval_policy"))
    assert Enum.any?(resume_args, &String.contains?(&1, "mcp_servers.fixture.enabled=false"))
    assert File.read!(Path.join(context.directory, "resume.env")) == "configured\n"
  end

  for recording <- Transcripts.names() do
    @tag recording: recording
    test "replays #{recording} through the wrapper and Port runner", context do
      recording = context.recording
      Transcripts.load(recording)
      name = start_agent(context)

      if recording == "failure" do
        reason = Transcripts.failure()
        assert {:error, ^reason} = GenAgent.ask(name, "replay:#{recording}")
        assert GenAgent.status(name).agent_state.errors == [reason]
        assert_receive {:stream_event, :error, _}
        refute_receive {:stream_event, _, _}
      else
        assert {:ok, response} = GenAgent.ask(name, "replay:#{recording}")
        Transcripts.assert_events(response.events, recording)
        assert response.text == Transcripts.text(recording)
      end
    end

    @tag recording: recording
    test "fixture preserves #{recording} stdout and exit status", context do
      recording = context.recording
      {stdout, status} = System.cmd(context.binary, ["exec", "replay:#{recording}"])
      assert stdout == File.read!(Path.join(Transcripts.directory(), "#{recording}.jsonl"))
      assert status == Transcripts.manifest()["scenarios"][recording]["exit_status"]
    end
  end

  defp args(directory, mode) do
    directory
    |> Path.join("#{mode}.args")
    |> File.read!()
    |> String.split("\n", trim: true)
  end
end
