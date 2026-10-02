defmodule GenAgent.Backends.CodexExecutableConformanceTest do
  use ExUnit.Case, async: false

  import GenAgent.TestDownAssertions

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
    previous_runner = Application.get_env(:codex_wrapper, :runner)
    Application.put_env(:codex_wrapper, :runner, CodexWrapper.Runner.Port)

    directory =
      Path.join(System.tmp_dir!(), "gen-agent-codex-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    binary = Path.join(directory, "codex-fixture")
    File.cp!(Path.expand("../../fixtures/codex_cli.sh", __DIR__), binary)
    File.chmod!(binary, 0o755)

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

    assert {:ok, _pid} = GenAgent.start_agent(Agent, agent_opts)

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
    assert first.text == "fixture-fresh"
    assert first.session_id == "fixture-thread"
    assert first.usage == %{input_tokens: 3, output_tokens: 2}

    assert Enum.map(first.events, & &1.kind) ==
             [
               :tool_use,
               :tool_result,
               :tool_use,
               :tool_result,
               :tool_use,
               :tool_result,
               :text,
               :usage,
               :result
             ]

    assert Enum.map(Enum.take(first.events, 6), & &1.data["id"]) ==
             ["call-1", "call-1", "cmd-1", "cmd-1", "file-1", "file-1"]

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
    assert second.text == "fixture-resume"
    assert second.session_id == "fixture-thread"

    resume_args = args(context.directory, :resume)
    assert Enum.take(resume_args, 2) == ["exec", "resume"]
    assert "fixture-thread" in resume_args
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

  test "terminal failure from the executable reaches GenAgent as an error", context do
    name = start_agent(context)
    assert {:error, "fixture failure"} = GenAgent.ask(name, "fail")
    assert GenAgent.status(name).agent_state.errors == ["fixture failure"]
    assert "fail" == List.last(args(context.directory, :fresh))
  end

  test "structured CLI failure reaches GenAgent without flattening its fields", context do
    name = start_agent(context)

    assert {:error, %{"code" => "fixture_error", "message" => "typed fixture failure"}} =
             GenAgent.ask(name, "typed-fail")

    assert [%{"code" => "fixture_error"}] = GenAgent.status(name).agent_state.errors
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

      assert_killed_or_gone(task_monitor, task_pid, 1_000)
    end
  end

  defp args(directory, mode) do
    directory
    |> Path.join("#{mode}.args")
    |> File.read!()
    |> String.split("\n", trim: true)
  end
end
