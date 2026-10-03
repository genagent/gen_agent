# GenAgentCodex

[![CI](https://github.com/genagent/gen_agent/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/gen_agent/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/gen_agent_codex.svg)](https://hex.pm/packages/gen_agent_codex)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/gen_agent_codex)

The package source and new issues live in
[`genagent/gen_agent/integrations/codex`](https://github.com/genagent/gen_agent/tree/main/integrations/codex).
The [former repository](https://github.com/genagent/gen_agent_codex) retains
historical releases and discussions.

Codex backend for [GenAgent](https://github.com/genagent/gen_agent),
built on top of [codex_wrapper](https://hex.pm/packages/codex_wrapper).

Provides `GenAgent.Backends.Codex`, which wraps the `codex` CLI and
translates its NDJSON event output into the normalized `GenAgent.Event`
values the state machine consumes.

## Prerequisites

The `codex` CLI must be installed and on your `PATH`. See the
[Codex docs](https://github.com/openai/codex) for install instructions.

The default CodexWrapper runner starts the CLI through `/bin/sh` and
redirects stdin from `/dev/null`, so it needs both on the host. The optional
Forcola runner (see [Cancellation](#cancellation)) is POSIX-only.

## Installation

```elixir
def deps do
  [
    {:gen_agent, "~> 0.3.0"},
    {:gen_agent_codex, "~> 0.2.0"}
  ]
end
```

## Quick start

```elixir
defmodule MyApp.Coder do
  use GenAgent

  defmodule State do
    defstruct [:path, responses: []]
  end

  @impl true
  def init_agent(opts) do
    path = Keyword.fetch!(opts, :cwd)

    backend_opts = [
      cwd: path,
      sandbox: :read_only,
      skip_git_repo_check: true
    ]

    {:ok, backend_opts, %State{path: path}}
  end

  @impl true
  def handle_response(_ref, response, state) do
    {:noreply, %{state | responses: state.responses ++ [response.text]}}
  end
end

{:ok, _pid} = GenAgent.start_agent(MyApp.Coder,
  name: "my-coder",
  backend: GenAgent.Backends.Codex,
  cwd: "/path/to/project"
)

{:ok, response} = GenAgent.ask("my-coder", "What does lib/foo.ex do?")
IO.puts(response.text)
```

## Session continuation

Codex tracks conversation state via a server-side `thread_id`. The backend
captures it from the first `thread.started` event of a turn and threads it
through `codex exec resume` on subsequent turns -- transparently, no caller
code required.

```elixir
{:ok, r1} = GenAgent.ask("my-coder", "Remember the number 42")
{:ok, r2} = GenAgent.ask("my-coder", "What number did I ask you to remember?")
# r2.text == "42"
```

## Streaming

The backend uses `CodexWrapper.Exec.stream/2` and
`CodexWrapper.ExecResume.stream/2`. Both runners close CLI stdin, so the
CLI does not wait for input. `handle_stream_event/2`
receives normalized events as they arrive while `ask/3` returns the
completed turn. `thread.started` supplies the ID used by the next
turn's `exec resume` command.

## Backend options

**Config:**
- `:binary`, `:working_dir` (aliased as `:cwd`), `:env`, `:timeout`,
  `:idle_timeout_ms`. `:timeout` bounds the whole turn; `:idle_timeout_ms`
  bounds gaps between output frames (default 300,000 ms).

**Exec:**
- `:model`, `:sandbox`, `:approval_policy`, `:full_auto`,
  `:dangerously_bypass_approvals_and_sandbox`, `:skip_git_repo_check`,
  `:ignore_user_config`, `:profile`,
  `:config_overrides`, `:enabled_features`, `:disabled_features`,
  `:images`, `:output_schema`

These settings are forwarded where the CLI supports them. Sandbox and
approval policy become supported `-c` overrides on resume.
The backend rejects `ephemeral: true` because its sessions must be resumable,
and rejects `verbose: true` because the CLI has no such global flag. Explicit
`false` values remain accepted as no-ops.

| Configuration option | Fresh turn | Resumed turn |
| --- | --- | --- |
| `ignore_user_config: true` | Skips the host's Codex configuration | Skips the host's Codex configuration |
| `profile: "name"` | Selects a named configuration profile | Not supported by `codex exec resume` |

`:working_dir` / `:cwd` remains the subprocess directory on both turns.
Options that the resume command cannot preserve (`:cd`, `:add_dirs`,
`:search`) fail at session startup with
`{:error, {:unsupported_resume_option, option}}`.
Other unrecognized options fail on both start and resume with
`{:error, {:unsupported_option, option}}`. Generic callback options such as
`:system`, `:system_prompt`, and `:max_tokens` are not Codex backend options;
an agent's `init_agent/1` must return options accepted by its selected backend.

**Backend-only:**
- `:exec_fn` -- a 2-arity function `(prompt, session) -> {:ok, enumerable} | {:error, term()}`
  that replaces the default `Exec`/`ExecResume` dispatch. Intended for tests.

Codex has no equivalent of Claude's `--system-prompt`; if you need
system-level instructions, pass them via `AGENTS.md` in the working
directory or through Codex's configuration layer.

### Sandbox and approvals

The backend adds no sandbox or approval flag unless you set one. With no
`:sandbox`, `:approval_policy`, `:full_auto`, or
`:dangerously_bypass_approvals_and_sandbox`, the `codex` CLI applies its own
configuration: the host's Codex config and its default sandbox and approval
behavior. The backend does not choose a posture for you.

The sandbox limits what commands can touch. The approval policy decides when
the CLI asks before running something. They are set separately.

- `sandbox: :read_only` -- commands cannot write. The quick start uses it.
- `sandbox: :workspace_write` -- commands can write inside the workspace.
- `sandbox: :danger_full_access` -- no sandbox.
- `approval_policy: :untrusted | :on_request | :never` -- when the CLI asks
  before acting.
- `full_auto: true` -- the wrapper emits `--sandbox workspace-write`, unless
  an explicit `:sandbox` is given, which wins.
- `dangerously_bypass_approvals_and_sandbox: true` -- skips both. Use it only
  in an environment you already trust the agent with.

### Environment and working directory

The subprocess inherits the BEAM's full environment and current directory.
`:env` overrides individual variables on top of the inherited environment;
it does not replace or sanitize the rest. Set `:cwd` (or `:working_dir`) to
run the CLI in a specific directory instead of the BEAM's.

### Stderr

Streaming turns parse NDJSON from the CLI's stdout, so the wrapper does not
merge stderr into it. With the default Port runner, CLI stderr flows to the
BEAM's own stderr. It does not appear in the `GenAgent.Event` stream and is
not part of the response.

### Cancellation

On interrupt, watchdog, and stop, GenAgent cancels its prompt task. With
the default Port runner this closes the pipes but does not guarantee that
the CLI and the MCP servers it spawned have exited. To terminate the whole
process group, add `forcola` and select its runner:

```elixir
# mix.exs
{:forcola, "~> 0.4.0"}

# config/config.exs
config :codex_wrapper, runner: CodexWrapper.Runner.Forcola
```

See `CodexWrapper.Runner` for details.

### Timeouts

Two timeouts apply to a turn, and they are independent:

- GenAgent's `:watchdog_ms` (default 600,000 ms) is a `:state_timeout` on the
  agent. When it fires, GenAgent cancels the prompt task with `:timeout`, as
  described above.
- The backend's `:timeout` is passed to the wrapper's runner for the
  streaming command. Its meaning depends on the runner. The Port runner
  treats it as an idle bound: the wait for the next output line, not the
  whole run (default 300,000 ms when unset). The Forcola runner treats it as
  a bound on the whole run; when unset it uses
  `config :codex_wrapper, forcola_default_timeout_ms:` (default 300,000 ms).

Because of the Port runner's idle semantics, a long turn that keeps emitting
events is limited only by `:watchdog_ms`.

See `GenAgent.Backends.Codex` for the full module docs.

## Event translation

Codex CLI's NDJSON output is translated into `GenAgent.Event` values by
`GenAgent.Backends.Codex.EventTranslator`:

| Codex event | GenAgent event |
|---|---|
| `thread.started` | captured for `thread_id`, then filtered |
| `turn.started` | filtered |
| `item.completed` (`agent_message`) | `:text` |
| `item.completed` (`tool_call`) | `:tool_use` |
| `item.completed` (`tool_result`) | `:tool_result` |
| `item.completed` (`mcp_tool_call`, `command_execution`, `file_change`) | `:tool_use` + `:tool_result`, carrying the complete item including ID, status and output |
| `turn.completed` | `:usage` (increase since the previous completed turn) + terminal `:result` (with captured `thread_id` as `session_id`) |
| `turn.failed` | terminal `:error`; the reason falls back to the most recent `error` event when the failure carries none |
| `error` | retained, not emitted; becomes a terminal `:error` only if the stream ends without `turn.completed` or `turn.failed` |
| anything else | filtered |

Unlike Claude, Codex emits `thread_id` in the **first** event of a turn,
not the terminal one. The streaming translator retains it and injects
it into the `:result` event emitted at the end. The backend also
checkpoints this raw ID immediately, so a failed or interrupted turn
can resume the same thread. `item.started` and
`item.updated` are ignored; completed items are reported once. Unknown
item categories are filtered. A stream that ends with no turn outcome
and no retained `error` event returns `:no_terminal_event`; the wrapper
stream API does not report the subprocess exit code.

## Usage

Codex reports `turn.completed.usage` as the thread's running total, so a
resumed turn reports the whole thread so far. The backend stores the previous
completed total on the session and `response.usage` holds the increase since
then. All five counters Codex emits are kept: `input_tokens`, `output_tokens`,
`cached_input_tokens`, `cache_write_input_tokens`, `reasoning_output_tokens`.

  * A session from `start_session/1` starts from zero, so the first turn
    reports its full usage.
  * A session from `resume_session/2` has no known earlier total. The first
    completed turn reports no usage and records the total; later turns report
    deltas.
  * A counter that is missing from either completed total, or that decreased
    (a thread reset), has no delta for that turn. The new total becomes the
    baseline. Negative values are never emitted.
  * A failed or interrupted turn does not update the baseline. Tokens it used
    are included in the next successful turn's delta, because completion
    totals cannot separate them.

## Testing

```bash
# Unit tests only (default, no CLI invocation)
mix test

# Run live tests that actually call the codex CLI
mix test --only live
```

Live tests are tagged `:live` so they do not run by
default. They burn real tokens -- keep them cheap.

## License

MIT. See [LICENSE](LICENSE).
