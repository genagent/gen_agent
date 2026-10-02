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
`CodexWrapper.ExecResume.stream/2`. CodexWrapper 0.5.1 closes CLI stdin,
so the earlier Port startup hang is fixed. `handle_stream_event/2`
receives normalized events as they arrive while `ask/3` returns the
completed turn. `thread.started` supplies the ID used by the next
turn's `exec resume` command.

## Backend options

**Config:**
- `:binary`, `:working_dir` (aliased as `:cwd`), `:env`, `:timeout`,
  `:verbose`

**Exec:**
- `:model`, `:sandbox`, `:approval_policy`, `:full_auto`,
  `:dangerously_bypass_approvals_and_sandbox`, `:skip_git_repo_check`,
  `:ephemeral`, `:ignore_user_config`, `:profile`,
  `:config_overrides`, `:enabled_features`, `:disabled_features`,
  `:images`, `:output_schema`

These settings are forwarded where the CLI supports them. Sandbox and
approval policy become supported `-c` overrides on resume.

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
| `turn.completed` | `:usage` + terminal `:result` (with captured `thread_id` as `session_id`) |
| `turn.failed` / `error` | terminal `:error` |
| anything else | filtered |

Unlike Claude, Codex emits `thread_id` in the **first** event of a turn,
not the terminal one. The streaming translator retains it and injects
it into the `:result` event emitted at the end. `item.started` and
`item.updated` are ignored; completed items are reported once. Unknown
item categories are filtered. A stream that ends without a terminal
event returns `:no_terminal_event`; the wrapper stream API does not
report the subprocess exit code.

## Testing

```bash
# Unit tests only (default, no CLI invocation)
mix test

# Include live integration tests that actually call the codex CLI
mix test --only integration
```

Integration tests are tagged `:integration` so they do not run by
default. They burn real tokens -- keep them cheap.

## License

MIT. See [LICENSE](LICENSE).
