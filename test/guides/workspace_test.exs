# Exercise the copyable example, not a duplicate implementation.
guide = Path.expand("../../guides/patterns/workspace.md", __DIR__)
[_, code] = Regex.run(~r/```elixir\n(defmodule Workspace.Agent do.*?)\n```/s, File.read!(guide))
Code.compile_string(code, guide)

defmodule GenAgent.WorkspaceGuideTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  alias Workspace.Agent

  defmodule Backend do
    @behaviour GenAgent.Backend
    def start_session(opts) do
      cwd = Keyword.fetch!(opts, :cwd)
      observer = Process.whereis(GenAgent.WorkspaceGuideTest)
      send(observer, {:session, cwd, File.exists?(cwd)})
      {:ok, {observer, cwd}}
    end

    def prompt({observer, cwd} = session, _prompt) do
      send(observer, {:prompt, File.dir?(Path.join(cwd, ".git"))})
      {:ok, [GenAgent.Event.new(:result, %{text: "A paragraph."})], session}
    end

    def terminate_session(_session), do: :ok
  end

  defmodule GatedBackend do
    @behaviour GenAgent.Backend
    def start_session(opts) do
      send(Process.whereis(GenAgent.WorkspaceGuideTest), {:starting, self(), opts[:cwd]})

      receive do
        :continue -> {:ok, nil}
      after
        5_000 -> {:error, :test_deadline}
      end
    end

    def prompt(_, _), do: {:error, :unexpected_prompt}
    def terminate_session(_), do: :ok
  end

  setup do
    Process.register(self(), __MODULE__)

    root =
      Path.join(
        System.tmp_dir!(),
        "workspace-guide-test-#{Base.encode16(:crypto.strong_rand_bytes(16))}"
      )

    File.mkdir!(root)
    bin = Path.join(root, "bin")
    File.mkdir!(bin)
    real_git = System.find_executable("git")
    env_keys = ["PATH", "WORKSPACE_TEST_FAIL", "WORKSPACE_TEST_SLEEP", "GIT_CONFIG_GLOBAL"]
    previous = Map.new(env_keys, &{&1, System.get_env(&1)})
    shim = Path.join(bin, "git")

    File.write!(shim, """
    #!/bin/sh
    step="$5"
    if [ "$step" = "$WORKSPACE_TEST_SLEEP" ]; then
      exec /bin/sleep 2
    fi
    if [ "$step" = "$WORKSPACE_TEST_FAIL" ]; then
      echo "injected $step failure"
      exit 42
    fi
    exec '#{String.replace(real_git, "'", "'\\''")}' "$@"
    """)

    File.chmod!(shim, 0o755)
    System.put_env("PATH", bin <> ":" <> previous["PATH"])
    System.delete_env("WORKSPACE_TEST_FAIL")
    System.delete_env("WORKSPACE_TEST_SLEEP")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root, real_git: real_git}
  end

  defp init(root, opts \\ []) do
    assert {:ok, backend_opts, state} =
             Agent.init_agent([topic: "octopuses", workspace_root: root] ++ opts)

    assert backend_opts[:cwd] == state.workspace
    state
  end

  defp ready(root, opts \\ []) do
    state = init(root, opts)
    assert {:ok, ^state} = Agent.pre_run(state)
    state
  end

  defp turn(state) do
    assert {:prompt, _, next} = Agent.handle_response(make_ref(), %{text: "A paragraph."}, state)
    assert {:ok, next} = Agent.post_turn({:ok, %{}}, make_ref(), next)
    next
  end

  defp git(ctx, state, args) do
    {out, 0} = System.cmd(ctx.real_git, args, cd: state.workspace)
    String.trim(out)
  end

  defp halted(name, tries \\ 200)
  defp halted(_name, 0), do: flunk("agent did not halt")

  defp halted(name, tries) do
    case GenAgent.status(name) do
      %{halted: true, agent_state: state} ->
        state

      _ ->
        Process.sleep(10)
        halted(name, tries - 1)
    end
  end

  defp start(root, turns) do
    name = "workspace-test-#{Base.encode16(:crypto.strong_rand_bytes(8))}"

    assert {:ok, _pid} =
             GenAgent.start_agent(Agent,
               name: name,
               backend: Backend,
               topic: "octopuses",
               workspace_root: root,
               num_turns: turns
             )

    on_exit(fn -> if GenAgent.whereis(name), do: GenAgent.stop(name) end)
    assert_receive {:session, cwd, false}
    # Status is queued behind pre_run and therefore acts as a setup barrier.
    assert %{agent_state: %{workspace: ^cwd}} = GenAgent.status(name)
    name
  end

  test "runtime supplies cwd before creation and finishes only after commits and log", ctx do
    name = start(ctx.root, 2)

    assert {:ok, _} = GenAgent.tell(name, "begin")
    state = halted(name)
    assert state.phase == :finished
    assert length(state.commits) == 2
    assert state.commit_log =~ "turn 2: paragraph 2"
    assert git(ctx, state, ["rev-list", "--count", "HEAD"]) == "3"
    assert capture_io(fn -> Agent.post_run(state) end) =~ "finished 2 turns"
    assert_receive {:prompt, true}
    assert_receive {:prompt, true}
    refute_receive {:prompt, _}
  end

  for step <- ["add", "commit", "rev-parse"], total <- [1, 3] do
    test "#{step} failure with #{total} requested turns halts without success", ctx do
      name = start(ctx.root, unquote(total))
      System.put_env("WORKSPACE_TEST_FAIL", unquote(step))

      logs =
        capture_log(fn ->
          assert {:ok, _} = GenAgent.tell(name, "begin")
          state = halted(name)
          assert {:failed, {:git_failed, unquote(step), 42, output}} = state.phase
          assert output =~ "injected"
          assert state.turn == 1
          assert state.commits == []
          assert state.commit_log == nil
          refute capture_io(fn -> Agent.post_run(state) end) =~ "finished"
          count = if unquote(step) == "rev-parse", do: "2", else: "1"
          assert git(ctx, state, ["rev-list", "--count", "HEAD"]) == count
        end)

      assert logs =~ unquote(step)
      assert_receive {:prompt, true}
      refute_receive {:prompt, _}
    end
  end

  test "log failure prevents finished phase and post_run success summary", ctx do
    name = start(ctx.root, 1)
    System.put_env("WORKSPACE_TEST_FAIL", "log")

    assert capture_log(fn ->
             assert {:ok, _} = GenAgent.tell(name, "begin")
             state = halted(name)
             assert {:failed, {:git_failed, "log", 42, _}} = state.phase
             assert length(state.commits) == 1
             refute capture_io(fn -> Agent.post_run(state) end) =~ "finished"
           end) =~ "log"
  end

  test "invalid IDs are rejected before any directory is created", ctx do
    base = Path.join(ctx.root, "not-created")

    for id <- [
          "../../outside",
          "/../../outside",
          "/abs",
          "a/b",
          "",
          "UPPER",
          "a\n",
          1,
          nil,
          String.duplicate("a", 64)
        ] do
      assert {:error, {:invalid_session_id, ^id}} =
               Agent.init_agent(topic: "x", workspace_root: base, session_id: id)
    end

    refute File.exists?(base)
  end

  test "repeating an ID across independent initializations cannot reuse an old repository", ctx do
    old = ready(ctx.root, session_id: "same-id") |> turn()
    File.write!(Path.join(old.workspace, "paragraph_99.md"), "old artifact")
    head = git(ctx, old, ["rev-parse", "HEAD"])
    next = init(ctx.root, session_id: "same-id")
    assert {:error, {:workspace_exists, path}} = Agent.pre_run(next)
    assert path == old.workspace
    assert git(ctx, old, ["rev-parse", "HEAD"]) == head
    assert File.read!(Path.join(path, "paragraph_99.md")) == "old artifact"
    assert File.read!(Path.join(path, "paragraph_1.md")) == "A paragraph.\n"
    fresh = ready(ctx.root)
    refute fresh.workspace == old.workspace
    refute File.exists?(Path.join(fresh.workspace, "paragraph_99.md"))
    assert git(ctx, fresh, ["rev-list", "--count", "HEAD"]) == "1"
  end

  test "workspace allocation survives actual VM restarts and rejects a repeated ID", ctx do
    guide = Path.expand("../../guides/patterns/workspace.md", __DIR__)

    [_, code] =
      Regex.run(~r/```elixir\n(defmodule Workspace.Agent do.*?)\n```/s, File.read!(guide))

    source = Path.join(ctx.root, "agent.exs")
    File.write!(source, code)
    result_path = Path.join(ctx.root, "result.etf")

    boot = fn opts ->
      script = """
      Code.require_file(#{inspect(source)})
      {:ok, _, state} = Workspace.Agent.init_agent(#{inspect([topic: "x", workspace_root: ctx.root] ++ opts)})
      result = Workspace.Agent.pre_run(state)
      File.write!(#{inspect(result_path)}, :erlang.term_to_binary(result))
      """

      assert {_, 0} =
               System.cmd("elixir", ["-pa", Path.dirname(:code.which(GenAgent)), "-e", script],
                 stderr_to_stdout: true
               )

      ctx.root |> Path.join("result.etf") |> File.read!() |> :erlang.binary_to_term()
    end

    assert {:ok, first} = boot.([])
    assert {:ok, second} = boot.([])
    refute first.workspace == second.workspace
    assert {:ok, old} = boot.(session_id: "repeated")
    File.write!(Path.join(old.workspace, "paragraph_99.md"), "keep me")
    head = git(ctx, old, ["rev-parse", "HEAD"])
    assert {:error, {:workspace_exists, path}} = boot.(session_id: "repeated")
    assert path == old.workspace
    assert git(ctx, old, ["rev-parse", "HEAD"]) == head
    assert File.read!(Path.join(path, "paragraph_99.md")) == "keep me"
  end

  for step <- ["init", "config", "commit"] do
    test "setup #{step} failure removes its partial workspace", ctx do
      state = init(ctx.root)
      System.put_env("WORKSPACE_TEST_FAIL", unquote(step))
      assert {:error, {:git_failed, unquote(step), 42, _}} = Agent.pre_run(state)
      refute File.exists?(state.workspace)
    end
  end

  test "asynchronous setup failure exposes the documented exit and cleans up", ctx do
    System.put_env("WORKSPACE_TEST_FAIL", "commit")

    task =
      Task.async(fn ->
        GenAgent.start_agent(Agent,
          name: "workspace-setup-failure",
          backend: GatedBackend,
          topic: "x",
          workspace_root: ctx.root
        )
      end)

    assert_receive {:starting, pid, cwd}, 1_000
    monitor = Process.monitor(pid)
    send(pid, :continue)
    assert {:ok, ^pid} = Task.await(task)

    assert_receive {:DOWN, ^monitor, :process, ^pid,
                    {:pre_run_failed, {:git_failed, "commit", 42, _}}},
                   2_000

    refute File.exists?(cwd)
  end

  test "invalid ID startup reports the current runtime error label", ctx do
    assert {:error, {:backend_start_failed, {:invalid_session_id, "../escape"}}} =
             GenAgent.start_agent(Agent,
               name: "workspace-invalid-id",
               backend: Backend,
               topic: "x",
               workspace_root: ctx.root,
               session_id: "../escape"
             )

    refute_receive {:session, _, _}
  end

  test "setup deadline bounds waiting and removes the partial workspace", ctx do
    state = init(ctx.root, git_timeout: 25)
    System.put_env("WORKSPACE_TEST_SLEEP", "init")
    started = System.monotonic_time(:millisecond)
    assert {:error, {:git_failed, "init", :timeout, ""}} = Agent.pre_run(state)
    assert System.monotonic_time(:millisecond) - started < 1_500
    refute File.exists?(state.workspace)
  end

  test "global signing, hooks, and templates cannot alter the repository", ctx do
    hooks = Path.join(ctx.root, "hooks")
    template = Path.join(ctx.root, "template")
    File.mkdir!(hooks)
    File.mkdir!(template)
    File.write!(Path.join(template, "unexpected"), "template contamination")
    hook = Path.join(hooks, "pre-commit")
    File.write!(hook, "#!/bin/sh\nexit 73\n")
    File.chmod!(hook, 0o755)
    config = Path.join(ctx.root, "gitconfig")

    File.write!(config, """
    [commit]
      gpgsign = true
    [gpg]
      program = /nonexistent-workspace-test-signer
    [core]
      hooksPath = #{hooks}
    [init]
      templateDir = #{template}
    """)

    System.put_env("GIT_CONFIG_GLOBAL", config)
    state = ready(ctx.root, num_turns: 1) |> turn()
    assert {:halt, %{phase: :finished}} = Agent.pre_turn("next", state)
    refute File.exists?(Path.join(state.workspace, ".git/unexpected"))
    assert git(ctx, state, ["rev-list", "--count", "HEAD"]) == "2"
  end

  test "variation and cleanup claims agree with the lifecycle" do
    guide = File.read!(Path.expand("../../guides/patterns/workspace.md", __DIR__))
    assert guide =~ "`{:noreply, state}`"
    assert guide =~ "phase: :awaiting_review"
    assert guide =~ "not run after failed initialization or backend startup"
    refute guide =~ "create_worktree/3"
    refute guide =~ "no matter what happens"
  end
end
