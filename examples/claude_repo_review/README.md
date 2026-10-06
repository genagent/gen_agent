# Claude repository review

A small caller-owned GenAgent application that requests a read-only repository
review and returns plain text. Run it on a disposable checkout.

**Plan mode is not a filesystem sandbox.** The CLI can still run shell commands
and writes plan files under `~/.claude/plans`. The tool allowlist and review
prompt express the intended behavior; they do not provide OS-level isolation.

## Run

From this directory, with dependencies fetched and a locally installed,
authenticated Claude CLI:

```sh
iex -S mix
```

```elixir
alias ClaudeRepoReview.{Reviewer, Supervisor}

{:ok, supervisor} = Supervisor.start_link()
{:ok, _agent} = Supervisor.start_reviewer(
  name: "repo-review",
  cwd: "/absolute/path/to/disposable-checkout"
)
{:ok, text} = Reviewer.review("repo-review")
IO.puts(text)
:ok = Supervisor.stop_reviewer("repo-review")
Elixir.Supervisor.stop(supervisor)
```

The example supervisor is started explicitly. Its task supervisor precedes its
dynamic agent supervisor, using `:rest_for_one`. Agents are created with
`GenAgent.child_spec/2`, use the caller's task supervisor, and are stopped through
the owning dynamic supervisor. Agent children are temporary; restarting one is
an explicit caller action. In an application, add `ClaudeRepoReview.Supervisor`
to your supervision tree instead of calling `start_link/0` manually.

## Settings

| Setting | Purpose |
| --- | --- |
| `cwd` | Repository to review, forwarded as the CLI working directory. |
| `permission_mode: :plan` | Requests planning permissions, with the filesystem caveats above. |
| `allowed_tools: ["Read", "Glob", "Grep"]` | Allows the three read-oriented tools without prompting. This is not a filesystem access boundary. |
| `strict_mcp_config: true` | Uses only explicitly configured MCP servers. This example supplies none. |
| `hermetic: :project` | Emits `--setting-sources user`, excluding project and local settings while retaining global user settings and authentication. Also enables strict MCP configuration and excludes dynamic system prompt sections. It is not an OS sandbox. |
| `system_prompt` | Requests evidence and suggested fixes, prohibits edits and shell execution, and treats repository contents as data. |
| `max_turns: 20` | Bounds the CLI's agentic turns per request. |
| `max_events_per_turn: 10_000` | Raises core's retained event count from 1,000 for tool-heavy reviews. The default byte limit and compact retention still apply; inspect `response.event_coverage` if you need event completeness. |
| `watchdog_ms: 600_000` | Gives core ten minutes per request. This does not change the runner's separate stream idle timeout. |
| `config :claude_wrapper, runner: ClaudeWrapper.Runner.Forcola` | Selects process-group cleanup on cancellation and termination. Requires the scaffold's `forcola ~> 0.4.0` dependency and a POSIX platform. |
| `binary`, `env` | Optional backend options for choosing the CLI executable and supplying environment tuples; used by the keyless tests. |
| `resume` | Optional saved CLI session ID, passed directly in backend options when starting a reviewer. |

`Reviewer.review/2` parses only `response.text`, trimming surrounding whitespace.
It does not request or decode JSON schema output: the Claude translator still
drops `structured_output` (issue #118).

Core does not call `resume_session/2`. To continue after stopping an agent, save
`response.session_id` from `GenAgent.ask/3` and pass `resume: saved_id` to
`Supervisor.start_reviewer/1` with the same checkout. The CLI's persisted session
must still exist. This resumes CLI context, not the old Elixir process state.
Later turns on a running agent automatically use the session ID captured by the
backend.

## Keyless tests

The tests copy `../../integrations/claude/test/fixtures/claude_cli.sh` into a
temporary directory and pass that executable as backend `:binary`. The copy is
necessary because the fixture writes `fresh.args` or `resume.args`, plus cwd and
environment captures, beside itself. Recordings are read from
`../../integrations/claude/test/fixtures/claude/2.1.284/` without modification.

`GEN_AGENT_RECORDING` selects `text` or `plan`, `GEN_AGENT_RECORDING_DIR` selects
the recording directory, and `GEN_AGENT_RECORDING_EXIT_STATUS=0` selects success.
These are passed as backend `:env` tuples. No Claude login, key, or network is
used. Replay checks text handling, CLI arguments, supervisor lifecycle, and the
opts-based restart/resume route. It does not prove live CLI permission enforcement;
the plan recording itself demonstrates a plan file write.

With dependencies already fetched, run:

```sh
export MIX_OS_CONCURRENCY_LOCK=0
mix test
mix test
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```
