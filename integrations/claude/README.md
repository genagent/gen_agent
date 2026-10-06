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
      working_dir: path,
      system_prompt: "You are a coding assistant.",
      permission_mode: :plan
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

Claude CLI tracks multi-turn state through a `session_id`. The
backend checkpoints it from a raw `system` or terminal event as soon as
the CLI provides it, then threads it through `--resume` on subsequent
turns, including after a failed or interrupted turn. No caller code is
required. If the CLI fails before providing an ID, the next turn starts
without `--resume`.

The conversation behind a session ID is not stored by a server. The CLI
writes it as a local transcript file under
`~/.claude/projects/<slug derived from the working directory>/<session_id>.jsonl`
in the home directory of the user that runs the CLI. A saved ID can be
resumed when the CLI runs as the same user, on the same host, with the same
working directory, and the transcript file still exists. This backend
rejects `no_session_persistence: true` for this reason (see
[Backend options](#backend-options)).

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

### Resuming after an agent restart

GenAgent does not call `resume_session/2`; every agent start calls
`start_session/1` with the options returned from `init_agent/1`. To continue
a prior conversation after the agent process restarts, save
`response.session_id` and pass it back as `:resume` in those options, with
the same working directory as before:

```elixir
defmodule MyApp.Reviewer do
  use GenAgent

  @impl true
  def init_agent(opts) do
    cwd = Keyword.fetch!(opts, :cwd)

    backend_opts =
      case MyApp.SessionStore.get("reviewer") do
        nil -> [working_dir: cwd]
        saved_id -> [working_dir: cwd, resume: saved_id]
      end

    {:ok, backend_opts, %{}}
  end

  @impl true
  def handle_response(_ref, response, state) do
    if response.session_id, do: MyApp.SessionStore.put("reviewer", response.session_id)
    {:noreply, state}
  end
end
```

`MyApp.SessionStore` stands for whatever storage the application uses.
The first turn after the restart runs with `--resume <saved_id>`. Once the
CLI reports a session ID, the backend uses that ID for later turns in place
of the one you supplied. Resume needs the CLI's saved transcript for that
session, which lives under the user's home directory, so the CLI must run as
the same user on the same machine; if the transcript is missing, the turn
returns an error. Keep `:cwd` the same across restarts: the backend forwards
`:resume` unchanged, and the CLI's own documentation describes how it finds
a session's transcript.

## Backend options

`start_session/1` accepts `ClaudeWrapper.stream/2` options with one exception:
`no_session_persistence: true` returns
`{:error, {:unsupported_option, :no_session_persistence}}`, because later
turns resume the CLI session. If `:session_id` or `:continue_session` is
supplied for the first turn, the backend omits it once `--resume` is used.

Options are passed to `ClaudeWrapper.stream/2` unchanged, except that `:cwd`
is renamed to `:working_dir` and `:include_partial_messages` defaults to
`true`. `start_session/1` (and `resume_session/2`) validates the options
before any turn runs: an unsupported key returns
`{:error, {:unknown_option, key}}`, and a malformed value (a bad
`:permission_mode` or `:effort`, a non-binary `:json_schema`, a non-list
`:allowed_tools`, `:disallowed_tools`, or `:tools`, and so on) returns
`{:error, {:invalid_option, key, value}}`. A `nil` value is treated as unset.
The lists below cover common options; the backend also accepts the other
options handled by `ClaudeWrapper.Query.apply_opts/2` in its supported wrapper
version.

**Process:**
- `:binary` -- path to the `claude` executable.
- `:working_dir` (deprecated alias `:cwd`) -- directory the CLI runs in.
- `:env` -- environment variables set on top of the inherited environment.
  See [Environment and working directory](#environment-and-working-directory).
- `:debug` -- passes `--debug` to the CLI.

**Model and prompt:**
- `:model` -- model name or alias, for example `"sonnet"`.
- `:fallback_model` -- model the CLI falls back to when the primary model
  is unavailable (`--fallback-model`).
- `:system_prompt` -- replaces the default system prompt.
- `:system_prompt_file` -- reads the system prompt from a file
  (`--system-prompt-file`), which avoids passing a large prompt in argv.
- `:append_system_prompt` -- text appended to the default system prompt.
- `:effort` -- `:low`, `:medium`, `:high`, `:xhigh`, or `:max`.
- `:max_turns` -- cap on agentic turns per prompt.
- `:max_budget_usd` -- cap on spend per prompt.
- `:json_schema` -- JSON schema string for structured output.
- `:agent` -- name of a Claude Code agent to run as.
- `:brief` -- enables the `SendUserMessage` tool (`--brief`).

**Tools and permissions:**
- `:tools` -- list of built-in tools the agent can use (`--tools`). Tools
  not in the list are not available to the agent. An empty list is not a
  restriction: the wrapper omits `--tools` entirely for `[]`, so the CLI's
  default tools stay available.
- `:allowed_tools` -- list of tools or tool patterns, such as
  `"Bash(git log:*)"`, that run without a permission prompt
  (`--allowed-tools`). This does not remove other tools.
- `:disallowed_tools` -- list of tools or tool patterns the agent may not
  use (`--disallowed-tools`).
- `:permission_mode`, `:dangerously_skip_permissions` -- see
  [Permissions](#permissions).
- `:add_dir` -- directory or list of directories tools may access in
  addition to the working directory (`--add-dir`).

**MCP:**
- `:mcp_config` -- path or list of paths to MCP server config files
  (`--mcp-config`).
- `:strict_mcp_config` -- `true` uses only the servers from `:mcp_config`
  and ignores MCP servers configured in Claude settings
  (`--strict-mcp-config`).

**Settings isolation:**
- `:setting_sources` -- comma-separated string of the settings sources the
  CLI loads, from `"user"`, `"project"`, and `"local"`
  (`--setting-sources`). An empty string loads none of them.
- `:hermetic` -- a preset over three flags. `true` or `:full` sets
  `--setting-sources ""`, which drops user, project, and local settings
  (hooks, MCP servers, and permission rules from `~/.claude` and the
  project's `.claude` directory). `:project` sets `--setting-sources user`,
  which drops project and local settings and keeps the user's `~/.claude`
  settings. Both scopes also set `--strict-mcp-config` and
  `--exclude-dynamic-system-prompt-sections`. An explicit
  `:setting_sources` takes precedence over the scope's value. `:hermetic`
  does not change authentication, the inherited environment, or where the
  CLI stores session transcripts.

**Session:**
- `:resume` -- session ID to resume on the first turn. See
  [Resuming after an agent restart](#resuming-after-an-agent-restart).
- `:session_id`, `:continue_session` -- applied to the first turn only.

**Streaming:**
- `:include_partial_messages` -- streams text deltas as they arrive.
  Enabled by default.

**No effect on the default streamed turn:**
- `:timeout` -- `ClaudeWrapper.stream/2` does not apply it. Each turn is
  bounded by a fixed idle deadline instead; see
  [Cancellation and timeouts](#cancellation-and-timeouts). It reaches a
  custom `:stream_fn`, which can read it.
- `:verbose` -- `ClaudeWrapper.stream/2` always passes `--verbose`, which
  stream-json output requires.
- `:output_format` -- `ClaudeWrapper.stream/2` always uses `stream-json`.

**Backend-only:**
- `:stream_fn` -- a 2-arity function `(prompt, opts) -> Enumerable.t()`
  that replaces the default `&ClaudeWrapper.stream/2`. Intended for tests
  that want to stub out the subprocess.

### Read-only agent

`:tools` limits the tools the agent has. `:allowed_tools` lets the listed
tools run without a permission prompt. Setting both gives an agent that can
read the project and cannot edit files or run shell commands:

```elixir
@impl true
def init_agent(opts) do
  backend_opts = [
    working_dir: Keyword.fetch!(opts, :cwd),
    system_prompt: "You review code. Do not modify files.",
    tools: ["Read", "Grep", "Glob"],
    allowed_tools: ["Read", "Grep", "Glob"],
    hermetic: :project
  ]

  {:ok, backend_opts, %{}}
end
```

`hermetic: :project` keeps the project's `.claude` settings, hooks, and MCP
servers out of the run. Use `hermetic: true` to also drop the user's
`~/.claude` settings.

### Permissions

The backend adds no permission flag unless you set one. With no
`:permission_mode` and no `:dangerously_skip_permissions`, the `claude` CLI
applies its own configuration: the host's Claude settings files and its
default permission mode. The backend does not choose a posture for you, so
what the agent can do depends on that host configuration.

- `permission_mode: :plan` -- the agent plans instead of editing project
  files. The quick start uses it because it only asks a question. Plan mode
  is a CLI permission mode, not a filesystem sandbox: in non-interactive use
  the CLI can still run shell commands (for example a test runner that writes
  build output), and it writes its plan file under `~/.claude/plans`. The
  CLI also ignores `:model` in plan mode and uses its configured model.
- `permission_mode: :accept_edits` -- file edits are approved automatically.
  Use it only for agents that are meant to change files.
- `permission_mode: :bypass_permissions` and
  `dangerously_skip_permissions: true` -- skip permission checks. Use them
  only in an environment you already trust the agent with.
- `:default`, `:dont_ask`, and `:auto` are also accepted and are passed to
  the CLI as given.

### Environment and working directory

The subprocess inherits the BEAM's full environment and current directory.
`:env` overrides individual variables on top of the inherited environment;
it does not replace or sanitize the rest. Set `:cwd` (or `:working_dir`) to
run the CLI in a specific directory instead of the BEAM's.

### Cancellation and timeouts

Two independent bounds apply to a turn:

- `ClaudeWrapper`'s runner ends the stream when the CLI writes no output
  line for 300,000 ms (5 minutes). The deadline resets on each line and is
  the same under the Port and Forcola runners. It is not configurable
  through backend options; `:timeout` does not change it. The turn then
  fails with reason `"stream_truncated"`. A tool call that runs longer than
  five minutes without the CLI emitting output can end the turn this way.
- GenAgent's `:watchdog_ms` (a `start_agent/2` option, default ten
  minutes) bounds the whole turn. A watchdog longer than five minutes does
  not extend the idle deadline.

On interrupt, watchdog, and stop, GenAgent cancels its prompt task. With
the default Port runner this closes the pipes but does not guarantee that
the CLI and the MCP servers it spawned have exited. The same applies when
the idle deadline ends the stream. To terminate the whole
process group, add `forcola` and select its runner:

```elixir
# mix.exs
{:forcola, "~> 0.4.0"}

# config/config.exs
config :claude_wrapper, runner: ClaudeWrapper.Runner.Forcola
```

See `ClaudeWrapper.Runner` for details.

See `GenAgent.Backends.Claude` for the full module docs.

## Event translation

Claude CLI's stream-json output is translated into `GenAgent.Event`
values by `GenAgent.Backends.Claude.EventTranslator`:

| Claude event | GenAgent event |
|---|---|
| `"system"` init | `:session` with model, permission mode, and tool names; later system events are filtered |
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

### Event data

`event.data` for each kind the translator emits. `:text`, `:usage`,
`:result`, and `:error` carry atom-keyed maps. `:tool_use` and
`:tool_result` carry the CLI's content block unchanged, with string keys,
so one turn's events mix both key types.

- `:text` -- `%{text: String.t()}`.
- `:session` -- `%{model: String.t(), permission_mode: String.t(), tools: [String.t()]}` from the CLI's init event. Missing fields are omitted; unrelated raw fields are not forwarded.
- `:tool_use` -- the raw block, for example
  `%{"type" => "tool_use", "id" => "toolu_...", "name" => "Read", "input" => %{"file_path" => "lib/foo.ex"}}`.
  `"input"` is the tool's argument map. Other fields the CLI includes, such
  as `"caller"`, are kept.
- `:tool_result` -- the raw block, for example
  `%{"type" => "tool_result", "tool_use_id" => "toolu_...", "content" => "..."}`.
  `"content"` is a string or a list of content blocks. `"is_error"` is
  present only when the CLI includes it.
- `:usage` -- `%{input_tokens: integer, output_tokens: integer}`. A count
  the CLI omits is omitted. Cache token counts are not included.
- `:result` -- `%{text: String.t(), session_id: String.t(), model: String.t(), cost_usd: number, duration_ms: integer, num_turns: integer, is_error: false, raw: map}`.
  The reported init model is also available as `Response.model`, even with compact event retention.
  Fields the CLI omits are omitted, except `:is_error`. `:raw` is the string-keyed result event, so
  `structured_output` (with `:json_schema`), `stop_reason`,
  `permission_denials`, `duration_api_ms` and extended usage are read from
  `raw`. When the result text is empty or absent, `:text` is omitted, so
  `Response.text` is assembled from the turn's `:text` events; a nonempty
  result text is always used as given. The original empty or missing value
  stays in `raw`. Tool inputs are never used as
  text: a plan passed to `ExitPlanMode` is read from that `:tool_use` event's
  `"input"`. The fallback is covered by synthetic stream tests; the CLI
  output of a plan-mode turn that ends in `ExitPlanMode` with an empty result
  has not been recorded.
- `:error` from a failed `"result"` -- `%{reason: reason, data: raw}`,
  where `raw` is the string-keyed result event and `reason` is
  `%{provider: :claude, subtype: String.t(), message: term, errors: [term], num_turns: integer, session_id: String.t(), cost_usd: number, usage: map}`
  with absent fields omitted. `:message` is the first of: a nonempty
  `"result"` string, the nonempty `"errors"` list joined with `"; "`, a
  nonempty `"error"` string, or `:unknown`. `:errors` keeps the list. The
  recorded CLI 2.1.284 max-turns failure carries only `"errors"`, so its
  `:message` is that text. Other failure subtypes have not been recorded.
- `:error` from an `"error"` event -- `%{reason: reason, data: raw}`, where
  `reason` is the event's `"error"` or `"message"` field, or `:unknown`.
  When the CLI exits without a terminal result (idle deadline, non-zero
  exit, or spawn failure), `reason` is `"stream_truncated"`.

The translator emits nothing for:

- thinking content: `"thinking"` blocks in assistant messages, and
  `thinking_delta` and `signature_delta` stream deltas
- partial tool-input JSON (`input_json_delta`) and other non-text stream
  deltas, message start and stop events, and content block start and stop
  events
- later `"system"` subtypes such as `status`, `thinking_tokens`, and task
  progress. The backend still reads `session_id` from them for checkpointing.
- `"rate_limit_event"` and any other unrecognized event type

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
