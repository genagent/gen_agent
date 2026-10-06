# Workspace

Single agent operating in an isolated git workspace, with
per-turn commits and a completion hook. This is the reference
example for gen_agent v0.2 lifecycle hooks -- all four of them
fire in sequence on the happy path.

## When to reach for this

The agent's work is file-based and needs to be committed
incrementally, rolled back cleanly, or eventually turned into a
PR. You want workspace isolation (the agent cannot stomp the
developer's working tree) and a permanent audit trail (each
turn is its own commit with a reproducible message).

This pattern is the foundation for any "real code agent" use
case: an agent that actually edits files rather than just
describing changes. The lifecycle hooks give you the right
seams -- setup on start, prompt shaping per turn, artifact
materialization after each turn, cleanup summary on halt --
without the agent's core decision logic having to know about
git or files.

## What it exercises in gen_agent

All four v0.2 lifecycle hooks in one pattern:

- **`pre_run/1`** -- creates the temporary workspace (for real
  use, a `git worktree`; for this example a fresh `git init`
  directory). Runs once after `init_agent`, before the first
  turn. Does not block `start_agent/2` from returning.
- **`pre_turn/2`** -- rewrites the prompt to include turn
  context and prior state. Demonstrates prompt rewriting: the
  manager sends a generic "next paragraph" instruction and
  `pre_turn` replaces it with the real grounded prompt.
- **`post_turn/3`** -- writes the response to a file, stages
  it, commits with a descriptive message, and records the SHA
  on state. Runs after each turn regardless of what
  `handle_response/3` decided.
- **`post_run/1`** -- prints the branch and workspace path when
  the agent halts. It prints the checked commit log only for a
  verified `:finished` phase. It does not fire on crashes, stop,
  or supervisor shutdown.

Plus:

- **Self-chaining** via `{:prompt, text, state}` from
  `handle_response/3` to drive multiple turns without manager
  input.
- **`handle_error/3`** to halt cleanly on backend failures so
  `post_run` can still run.

## The pattern

One callback module. The manager just starts the agent and
inspects the workspace after halt.

```elixir
defmodule Workspace.Agent do
  use GenAgent
  require Logger

  defmodule State do
    defstruct [
      :topic,
      :num_turns,
      :workspace,
      :branch,
      :session_id,
      :git_timeout,
      :commit_log,
      turn: 0,
      paragraphs: [],
      commits: [],
      phase: :running
    ]
  end

  @impl true
  def init_agent(opts) do
    id =
      Keyword.get_lazy(opts, :session_id, fn ->
        Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      end)

    if is_binary(id) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,62}\z/, id) do
      init_state(opts, id)
    else
      {:error, {:invalid_session_id, id}}
    end
  end

  defp init_state(opts, id) do
    base = Keyword.get(opts, :workspace_root, Path.join(System.tmp_dir!(), "workspace-agent"))

    state = %State{
      topic: Keyword.fetch!(opts, :topic),
      num_turns: Keyword.get(opts, :num_turns, 3),
      session_id: id,
      workspace: Path.expand(Path.join(base, "session-#{id}")),
      branch: "agent/#{id}",
      git_timeout: Keyword.get(opts, :git_timeout, 5_000)
    }

    system = """
    You are a focused writer producing a multi-paragraph essay
    one paragraph at a time. Write exactly one paragraph. No
    preamble. No headings. No meta-commentary.
    """

    {:ok, [system: system, max_tokens: Keyword.get(opts, :max_tokens, 200), cwd: state.workspace],
     state}
  end

  # ---- Lifecycle hooks ----

  @impl true
  def pre_run(%State{} = state) do
    with :ok <- File.mkdir_p(Path.dirname(state.workspace)),
         :ok <- File.mkdir(state.workspace) do
      result =
        with {:ok, _} <-
               git(state, ["init", "--quiet", "--template=", "--initial-branch=#{state.branch}"]),
             {:ok, _} <- git(state, ["config", "user.email", "agent@example.local"]),
             {:ok, _} <- git(state, ["config", "user.name", "Workspace Agent"]),
             {:ok, _} <- git(state, ["commit", "--quiet", "--allow-empty", "-m", "init"]) do
          {:ok, state}
        end

      case result do
        {:ok, _} ->
          result

        {:error, reason} ->
          case File.rm_rf(state.workspace) do
            {:ok, _} -> {:error, reason}
            {:error, cleanup, path} -> {:error, {reason, {:cleanup_failed, cleanup, path}}}
          end
      end
    else
      {:error, :eexist} -> {:error, {:workspace_exists, state.workspace}}
      {:error, reason} -> {:error, {:workspace_create_failed, reason}}
    end
  end

  @impl true
  def pre_turn(_prompt, %State{phase: {:failed, _}} = state), do: {:halt, state}

  # Finalize after post_turn, before claiming success. post_run cannot change state.
  def pre_turn(_prompt, %State{turn: turn, num_turns: total} = state) when turn >= total do
    case git(state, ["log", "--oneline"]) do
      {:ok, log} -> {:halt, %{state | phase: :finished, commit_log: log}}
      {:error, reason} -> {:halt, failed(state, reason)}
    end
  end

  def pre_turn(_prompt, %State{} = state) do
    next_turn = state.turn + 1

    context =
      case state.paragraphs do
        [] ->
          "This is paragraph 1 of #{state.num_turns}."

        paragraphs ->
          prior =
            paragraphs
            |> Enum.with_index(1)
            |> Enum.map_join("\n\n", fn {p, i} -> "Paragraph #{i}: #{p}" end)

          """
          This is paragraph #{next_turn} of #{state.num_turns}.

          Previously written:

          #{prior}

          Now write paragraph #{next_turn}. Do not repeat content.
          """
      end

    rewritten = """
    Topic: #{state.topic}

    #{context}
    """

    {:ok, rewritten, state}
  end

  @impl true
  def post_turn({:ok, _response}, _ref, %State{} = state) do
    case List.last(state.paragraphs) do
      nil ->
        {:ok, state}

      paragraph ->
        filename = "paragraph_#{state.turn}.md"

        with :ok <- File.write(Path.join(state.workspace, filename), paragraph <> "\n"),
             {:ok, _} <- git(state, ["add", filename]),
             {:ok, _} <-
               git(state, [
                 "commit",
                 "--quiet",
                 "-m",
                 "turn #{state.turn}: paragraph #{state.turn}"
               ]),
             {:ok, sha} <- git(state, ["rev-parse", "--short", "HEAD"]) do
          commit = %{turn: state.turn, sha: String.trim(sha), filename: filename}
          {:ok, %{state | commits: state.commits ++ [commit]}}
        else
          {:error, reason} -> {:ok, failed(state, reason)}
        end
    end
  end

  def post_turn({:error, _reason}, _ref, state), do: {:ok, state}

  @impl true
  def post_run(%State{} = state) do
    case state.phase do
      :finished ->
        IO.puts("\n[workspace] finished #{length(state.commits)} turns")
        IO.puts("  log:\n#{String.trim_trailing(state.commit_log)}")

      phase ->
        IO.puts("\n[workspace] #{inspect(phase)}; #{length(state.commits)} recorded commits")
    end

    IO.puts("  workspace: #{state.workspace}")
    IO.puts("  branch:    #{state.branch}")
    :ok
  end

  # ---- Core callbacks ----

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    paragraph = String.trim(response.text)
    new_turn = state.turn + 1
    state = %{state | turn: new_turn, paragraphs: state.paragraphs ++ [paragraph]}

    {:prompt, "next paragraph", state}
  end

  @impl true
  def handle_error(_ref, reason, %State{} = state) do
    {:halt, failed(state, {:backend_failed, reason})}
  end

  defp failed(state, reason) do
    Logger.error("[workspace] #{inspect(reason)}")
    %{state | phase: {:failed, reason}}
  end

  # ---- Git helper ----

  defp git(state, [step | _] = args) do
    task =
      Task.async(fn ->
        try do
          System.cmd(
            "git",
            ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null" | args],
            cd: state.workspace,
            stderr_to_stdout: true,
            env: [
              {"GIT_CONFIG_GLOBAL", "/dev/null"},
              {"GIT_CONFIG_NOSYSTEM", "1"},
              {"GIT_TERMINAL_PROMPT", "0"}
            ]
          )
        rescue
          error -> {Exception.message(error), :exec_failed}
        end
      end)

    case Task.yield(task, state.git_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {:git_failed, step, code, output}}
      nil -> {:error, {:git_failed, step, :timeout, ""}}
    end
  end
end
```

## Using it

```elixir
{:ok, _pid} = GenAgent.start_agent(Workspace.Agent,
  name: "essay",
  backend: GenAgent.Backends.Anthropic,
  topic: "why octopuses are extraordinary",
  num_turns: 3
)

# Kick off the first turn. pre_run has already created the
# workspace by the time this returns.
{:ok, _ref} = GenAgent.tell("essay", "begin")

# The agent will self-chain for 3 turns, committing each
# paragraph, then halt. post_run prints the summary.

# After halt, inspect the artifacts:
%{agent_state: %{workspace: workspace, branch: branch, commits: commits}} =
  GenAgent.status("essay")

IO.puts("workspace: #{workspace}")
IO.puts("branch: #{branch}")
Enum.each(commits, fn c -> IO.puts("  #{c.sha}  #{c.filename}") end)

GenAgent.stop("essay")
```

## Lifecycle hook ordering

For one happy-path turn, the callbacks fire in this order:

```
init_agent
  -> backend.start_session (receives cwd)
  -> pre_run
    -> pre_turn   (called before each dispatch)
      -> (backend call)
        -> handle_response OR handle_error
          -> post_turn
            -> transition (idle / self-chain / halt)
              -> post_run   (on halt)
                -> terminate_agent   (on process exit)
```

The final response self-chains once more so `pre_turn/2` can check
the commit log and halt without another backend call. A failed add,
commit, or SHA lookup records a failure in `post_turn/3`; the next
`pre_turn/2` halts with that failure. A failed SHA lookup may occur
after a successful commit; the recorded commit list is then incomplete.
`post_run/1` prints the already checked log only for `:finished`.

`post_run` fires on a clean halt, including a halt with a failed phase.
Gate publishing or other completion actions on `phase == :finished`.
`terminate_agent/2` runs when an initialized server terminates through
its termination callback, including stop and ordinary crashes. It does
not run after failed initialization or backend startup, or on an
untrappable kill/VM exit. Setup cleans up its own partial directory.
Keep successful workspaces for inspection and remove them when done;
production systems also need orphan cleanup outside the agent.
Setup and cleanup callbacks block the agent process. Configure
`shutdown:` above their bounded worst-case duration when starting the
agent; the default is 5 seconds, after which `stop/1` kills a still
blocked agent without running its termination callbacks. Avoid
`:infinity` unless an indefinitely blocked supervisor is acceptable.

This POSIX example requires Git 2.32+ for `GIT_CONFIG_GLOBAL`. It ignores
global/system configuration, disables signing and hooks, and uses an
empty template. Each command has a configurable `:git_timeout` in
milliseconds (default 5,000). The task deadline bounds the agent's wait;
it does not guarantee termination of the OS process or its descendants.
Use a process supervisor with process-group termination when that
guarantee is required.

The default ID uses random bytes, independent of VM restarts. Optional
IDs must be lowercase ASCII letters/digits/hyphens, start with a letter
or digit, and be at most 63 characters. `:workspace_root` is a trusted
application setting. Exclusive directory creation rejects even a
pre-existing empty directory; it never opens or deletes an old repository.

`init_agent/1` rejects bad IDs before filesystem access. Currently
`start_agent/2` reports this as
`{:error, {:backend_start_failed, {:invalid_session_id, id}}}`.
Setup runs asynchronously after startup: a `pre_run/1` error stops
the process with `{:pre_run_failed, reason}`, not a startup error tuple.
Callers should monitor the agent (accounting for it exiting before the
monitor is installed) or use supervisor/telemetry reporting, and handle
a failed `tell/2` if setup failed. Git setup errors include the command,
exit code or `:timeout`, and output; partial directories are removed.

## Variations

- **Real worktrees.** For production use, use `git worktree add`
  instead of `git init`. The workspace shares the object store
  with the source repo, so the agent branch can be pushed to a
  remote and turned into a PR. Implement creation and removal
  against your source repository as application-specific helpers.
- **Tool-use agent.** Swap the backend to `gen_agent_claude`
  using the `cwd` already returned by `init_agent/1`. The path is
  computed before backend session startup and created in `pre_run/1`.
  This requires a backend that defers directory access until prompts.
  The agent gains file access via Claude's Read/Glob/Grep/Bash
  tools. `post_turn`
  then commits whatever the LLM actually wrote rather than
  materializing text from the response.
- **Per-turn markdown artifacts as review input.** Pair this
  with [Checkpointer](checkpointer.md): return `{:noreply, state}`
  with `phase: :awaiting_review` to remain idle after each turn,
  and let the manager inspect the committed markdown, then
  approve/revise. The commits are your review
  history.
- **Create a PR on post_run.** After the last commit, use the
  GitHub API (or `gh pr create`) to open a PR from the agent's
  branch. Put that logic in `post_run/1` so it only runs on
  a verified `:finished` phase after clean completion.
- **Cleanup on terminate_agent.** Symmetric with the above:
  implement `terminate_agent/2` to remove owned workspaces on
  ordinary interrupted runs. Track ownership only after successful
  setup, so a rejected existing directory is never removed. Keep
  finished workspaces for inspection and arrange external orphan
  cleanup for exits that bypass the callback.
