# GenAgentClaude

[![CI](https://github.com/genagent/gen_agent/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/gen_agent/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/gen_agent_claude.svg)](https://hex.pm/packages/gen_agent_claude)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/gen_agent_claude)

The package source and new issues live in
[`genagent/gen_agent/integrations/claude`](https://github.com/genagent/gen_agent/tree/main/integrations/claude).
The [former repository](https://github.com/genagent/gen_agent_claude) retains
historical releases and discussions.

Claude backend for [GenAgent](https://github.com/genagent/gen_agent),
built on top of [claude_wrapper](https://hex.pm/packages/claude_wrapper).

Provides `GenAgent.Backends.Claude`, which wraps the `claude` CLI and
translates its stream-json output into the normalized `GenAgent.Event`
values the state machine consumes.

## Prerequisites

The `claude` CLI must be installed and on your `PATH` (or set `CLAUDE_CLI`
to point at it). See the [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code)
for install instructions.

## Installation

```elixir
def deps do
  [
    {:gen_agent, "~> 0.3.0"},
    {:gen_agent_claude, "~> 0.1.0"}
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
      system_prompt: "You are a coding assistant.",
      permission_mode: :accept_edits
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
  backend: GenAgent.Backends.Claude,
  cwd: "/path/to/project"
)

{:ok, response} = GenAgent.ask("my-coder", "What does lib/foo.ex do?")
IO.puts(response.text)
```

## Session continuation

Claude CLI tracks multi-turn state via a server-side `session_id`. The
backend checkpoints it from a raw `system` or terminal event as soon as
the CLI provides it, then threads it through `--resume` on subsequent
turns, including after a failed or interrupted turn. No caller code is
required. If the CLI fails before providing an ID, the next turn starts
without `--resume`.

Claude emits text deltas and tool results as normalized events. A long or
tool-heavy turn can exceed GenAgent's default retained-log budget of 1,000
events and 1,048,576 bytes. With the default `event_retention: :compact`,
the turn continues and the backend receives the terminal session ID;
`response.event_coverage` tells you if `response.events` is incomplete.
Use `event_retention: :lossless` when your application requires every event
in `response.events`; that mode fails the turn on overflow. The limits and
retention mode are GenAgent `start_agent/2` options, not Claude backend
options. See the root README's event capture section for the contract.

```elixir
# Turn 1: fresh conversation
{:ok, r1} = GenAgent.ask("my-coder", "Remember the number 42")
# Turn 2: same thread, same agent
{:ok, r2} = GenAgent.ask("my-coder", "What number did I ask you to remember?")
# r2.text == "42"
```

## Backend options

`start_session/1` accepts `ClaudeWrapper.stream/2` options with one exception:
`no_session_persistence: true` returns
`{:error, {:unsupported_option, :no_session_persistence}}`, because later
turns resume the CLI session. If `:session_id` or `:continue_session` is
supplied for the first turn, the backend omits it once `--resume` is used.

**Config:**
- `:binary`, `:working_dir` (aliased as `:cwd`), `:env`, `:timeout`,
  `:verbose`, `:debug`

**Query:**
- `:model`, `:system_prompt`, `:append_system_prompt`, `:max_turns`,
  `:max_budget_usd`, `:permission_mode`, `:dangerously_skip_permissions`,
  `:effort`, `:json_schema`, `:agent`, `:brief`,
  `:include_partial_messages` (enabled by default)

**Backend-only:**
- `:stream_fn` -- a 2-arity function `(prompt, opts) -> Enumerable.t()`
  that replaces the default `&ClaudeWrapper.stream/2`. Intended for tests
  that want to stub out the subprocess.

See `GenAgent.Backends.Claude` for the full module docs.

## Event translation

Claude CLI's stream-json output is translated into `GenAgent.Event`
values by `GenAgent.Backends.Claude.EventTranslator`:

| Claude event | GenAgent event |
|---|---|
| `"system"` | filtered |
| `"assistant"` | `:text` and `:tool_use` from ordered content blocks |
| `"user"` | `:tool_result` from tool-result content blocks |
| `"stream_event"` with text delta | immediate `:text`; completed assistant text is deduplicated |
| `"content_block_delta"` | `:text` (from delta text) |
| `"tool_use"` | `:tool_use` |
| `"tool_result"` | `:tool_result` |
| successful `"result"` | `:usage` + terminal `:result` |
| failed `"result"` | `:usage` + terminal `:error` with subtype, message, cost, session and usage evidence |
| `"error"` | terminal `:error` |
| anything else | filtered |

Token counts from `data["usage"]` are pulled out into a separate
`:usage` event so `GenAgent.Response.usage` is populated.
Failed results reach `handle_error/3` and return `{:error, reason}` from
`ask/3` or `poll/3`. They are not retried automatically. Tool calls
are emitted from completed assistant blocks so full input is retained;
partial tool-input JSON is not emitted on its own.

## Testing

```bash
# Unit tests only (default, no CLI invocation)
mix test

# Run live tests that actually call the claude CLI
mix test --only live
```

Live tests are tagged `:live` so they do not run by
default. They burn real tokens -- keep them cheap.

## License

MIT. See [LICENSE](LICENSE).
