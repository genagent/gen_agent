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
- **`post_run/1`** -- prints the branch, commit log, and
  workspace path when the agent halts cleanly. Does NOT fire on
  crashes, stop, or supervisor shutdown.

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

  defmodule State do
    defstruct [
      :topic,
      :num_turns,
      :workspace,
      :branch,
      :session_id,
      turn: 0,
      paragraphs: [],
      commits: [],
      phase: :running
    ]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      topic: Keyword.fetch!(opts, :topic),
      num_turns: Keyword.get(opts, :num_turns, 3),
      session_id: Keyword.fetch!(opts, :session_id)
    }

    system = """
    You are a focused writer producing a multi-paragraph essay
    one paragraph at a time. Write exactly one paragraph. No
    preamble. No headings. No meta-commentary.
    """

    {:ok, [system: system, max_tokens: Keyword.get(opts, :max_tokens, 200)], state}
  end

  # ---- Lifecycle hooks ----

  @impl true
  def pre_run(%State{} = state) do
    base = Path.join(System.tmp_dir!(), "workspace-agent")
    File.mkdir_p!(base)

    workspace = Path.join(base, "session-#{state.session_id}")
    File.mkdir_p!(workspace)
    branch = "agent/#{state.session_id}"

    with {_, 0} <- git(workspace, ["init", "--quiet", "--initial-branch=#{branch}"]),
         {_, 0} <- git(workspace, ["config", "user.email", "agent@example.local"]),
         {_, 0} <- git(workspace, ["config", "user.name", "Workspace Agent"]),
         {_, 0} <- git(workspace, ["commit", "--quiet", "--allow-empty", "-m", "init"]) do
      {:ok, %{state | workspace: workspace, branch: branch}}
    else
      {output, code} -> {:error, {:git_init_failed, code, output}}
    end
  end

  @impl true
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
        File.write!(Path.join(state.workspace, filename), paragraph <> "\n")

        with {_, 0} <- git(state.workspace, ["add", filename]),
             {_, 0} <-
               git(state.workspace, [
                 "commit", "--quiet", "-m",
                 "turn #{state.turn}: paragraph #{state.turn}"
               ]),
             {sha, 0} <- git(state.workspace, ["rev-parse", "--short", "HEAD"]) do
          commit = %{turn: state.turn, sha: String.trim(sha), filename: filename}
          {:ok, %{state | commits: state.commits ++ [commit]}}
        else
          _ -> {:ok, state}
        end
    end
  end

  def post_turn({:error, _reason}, _ref, state), do: {:ok, state}

  @impl true
  def post_run(%State{} = state) do
    {log, _} = git(state.workspace, ["log", "--oneline"])
    IO.puts("\n[workspace] finished #{length(state.commits)} turns")
    IO.puts("  workspace: #{state.workspace}")
    IO.puts("  branch:    #{state.branch}")
    IO.puts("  log:\n#{String.trim_trailing(log)}")
    :ok
  end

  # ---- Core callbacks ----

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    paragraph = String.trim(response.text)
    new_turn = state.turn + 1
    state = %{state | turn: new_turn, paragraphs: state.paragraphs ++ [paragraph]}

    if new_turn >= state.num_turns do
      {:halt, %{state | phase: :finished}}
    else
      {:prompt, "next paragraph", state}
    end
  end

  @impl true
  def handle_error(_ref, _reason, %State{} = state) do
    {:halt, %{state | phase: :failed}}
  end

  # ---- Git helper ----

  defp git(cwd, args) do
    System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  end
end
```

## Using it

```elixir
{:ok, _pid} = GenAgent.start_agent(Workspace.Agent,
  name: "essay",
  backend: GenAgent.Backends.Anthropic,
  topic: "why octopuses are extraordinary",
  num_turns: 3,
  session_id: System.unique_integer([:positive])
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
  -> pre_run
    -> pre_turn   (called before each dispatch)
      -> (backend call)
        -> handle_response OR handle_error
          -> post_turn
            -> transition (idle / self-chain / halt)
              -> post_run   (only on clean halt)
                -> terminate_agent   (on process exit)
```

The important distinction: `post_run` fires when a callback
returns `{:halt, state}` -- a clean completion signal.
`terminate_agent` fires on any termination (crash, stop,
supervisor shutdown). If you want "create a PR on clean
completion but not on crash," `post_run` is where that goes. If
you want "always clean up the workspace directory no matter
what happens," `terminate_agent` is where that goes.

## Variations

- **Real worktrees.** For production use, use `git worktree add`
  instead of `git init`. The workspace shares the object store
  with the source repo, so the agent branch can be pushed to a
  remote and turned into a PR. The [Workspace helper
  module](https://github.com/joshrotenberg/gen_agent) (once
  extracted) has `create_worktree/3` and `remove_worktree/2`
  wrapping this.
- **Tool-use agent.** Swap the backend to `gen_agent_claude`
  with `cwd: state.workspace` and the agent gains real file
  access via Claude's Read/Glob/Grep/Bash tools. `post_turn`
  then commits whatever the LLM actually wrote rather than
  materializing text from the response.
- **Per-turn markdown artifacts as review input.** Pair this
  with [Checkpointer](checkpointer.md): after each turn, halt
  in `:awaiting_review`, let the manager inspect the committed
  markdown, then approve/revise. The commits are your review
  history.
- **Create a PR on post_run.** After the last commit, use the
  GitHub API (or `gh pr create`) to open a PR from the agent's
  branch. Put that logic in `post_run/1` so it only runs on
  clean completion, never on crashes.
- **Cleanup on terminate_agent.** Symmetric with the above:
  `terminate_agent/2` removes the worktree directory so
  interrupted agents don't leave orphans behind. Keep the
  workspace for inspection if `phase: :finished`, tear it down
  otherwise.
