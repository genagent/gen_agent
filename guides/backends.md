# Backends

A backend connects one GenAgent process to one LLM session. It
implements the `GenAgent.Backend` behaviour, and the agent's state
machine calls it on boot, on every turn, and on shutdown.

This guide has two parts. "Writing a backend" lists the rules a new
backend must follow and the server code that enforces or relies on
each one. "Choosing a backend" compares the four published backends
as their current code behaves.

The state machine is the internal module GenAgent.Server in
`lib/gen_agent/server.ex`. Functions cited as "in server.ex" below are
functions of that module.

## Writing a backend

### Callbacks

Three callbacks are required:

- `start_session/1` receives the backend options returned from the
  agent's `c:GenAgent.init_agent/1` and returns `{:ok, session}` or
  `{:error, reason}`. The session is an opaque term owned by the
  backend.
- `prompt/2` receives the session and the prompt string and returns
  `{:ok, events, session}` or `{:error, reason}`.
- `terminate_session/1` releases whatever the session holds and
  returns `:ok`.

Four callbacks are optional. The server checks each one with
`function_exported?/3` before calling it:

- `prompt/3` is the same as `prompt/2` plus a context map carrying a
  checkpoint function. `run_prompt/7` in server.ex calls it instead
  of `prompt/2` when it is exported.
- `checkpoint_session/2` applies an acknowledged session identifier to
  the session. Required for `prompt/3` checkpoints to succeed.
- `update_session/2` folds a successful turn's terminal data into the
  session.
- `resume_session/2` is reserved. GenAgent does not call it.

### The event stream

The enumerable returned from `prompt/2` yields `GenAgent.Event` values
built with `GenAgent.Event.new/2`. The kinds are `:text`, `:tool_use`,
`:tool_result`, `:usage`, `:result`, and `:error`. The stream may be a
list or a lazy `Stream`.

The stream must end with exactly one terminal event, `:result` or
`:error` (`GenAgent.Event.terminal?/1`).
`consume_stream/8` in server.ex stops reading at the first terminal
event, so anything after it is never consumed. A stream that ends with
no terminal event fails the turn with `:no_terminal_event`.

The stream is consumed inside a task started by
`Task.Supervisor.async/2` in `dispatch/5` in server.ex, not in the
agent process. It must be safe to enumerate from another process, and
it may block while waiting for the provider.

Two kinds of failure are distinct:

- Return `{:error, reason}` from `prompt/2` when the prompt could not
  be dispatched at all. `run_prompt/7` in server.ex passes `reason`
  to `handle_error/3`, and the session from before the call is kept.
- Emit a terminal `:error` event for failures that occur during the
  turn. The session returned from `prompt/2` is kept.

An exception raised while the stream is consumed crashes the task.
The server's `:DOWN` handler turns that into
`{:task_crashed, reason}`.

### What the server reads from terminal events

`consume_stream/8` and `finish_stream/6` in server.ex read terminal
data with atom keys:

- On `:error`, the reason passed to `handle_error/3` is
  `Map.get(data, :reason, :unknown)`. A string key such as
  `"reason"` is not read, and the turn fails with `:unknown`.
- On `:result`, `Map.get(data, :session_id)` becomes
  `GenAgent.Response.session_id`.
- On `:result`, a binary `:text` value becomes `Response.text` and
  `Response.final_message` (`text_from_capture/2` and
  `final_message_from_capture/3` in `GenAgent.Response`).
  When `:text` is absent, `Response.text` is assembled from the
  turn's `:text` events. A `:text` event with `message_boundary: true`
  starts a separate assistant message after a blank line.
- The last `:usage` event's data becomes `Response.usage`.

The original terminal event is also kept on `Response.terminal`, so a
backend may put provider-specific fields in it.

### How `update_session/2` is called

`maybe_update_session/3` in server.ex calls `update_session/2` once
per turn, only when the terminal event is `:result`, with that event's
`data` map. It runs inside the prompt task, after the terminal event
is read and before the response is built. It is not called for an
`:error` terminal, a synchronous `{:error, reason}`, an interrupt, or
a watchdog timeout.

The session it returns replaces the cached session in `finish_turn/5`
in server.ex. If a checkpoint was acknowledged during the turn,
`restore_checkpoint/3` in server.ex applies `checkpoint_session/2` to
that session again before it is stored.

`update_session/2` receives the session returned from `prompt/2`, so a
backend can change the session in either place. The Anthropic backend appends
the user message in `prompt/2` and the assistant message in
`update_session/2`. The CLI backends change it only in
`update_session/2` and `checkpoint_session/2`.

### Checkpoints with `prompt/3`

A backend that learns its session identifier before the terminal
event can implement `prompt/3` and call `context.checkpoint.(id)` as
soon as it sees the identifier. The call is a synchronous
`:gen_statem.call/2` to the agent, handled by the
`{:checkpoint_session, ref, id}` clause of `dispatch_event/4` in
server.ex:

- The identifier must be a UTF-8 binary of 1 to 1024 bytes with no
  control characters, or the reply is `{:error, :invalid_session_id}`.
- The first identifier wins. Repeating it returns `:ok`. A different
  identifier returns `{:error, :conflicting_session_id}`.
- A backend without `checkpoint_session/2` gets
  `{:error, :unsupported_checkpoint}`.
- The call must come from the active turn's prompt task itself: the
  server matches both the request reference and the caller's pid. A
  call from any other process, including a helper process during the
  active turn, or from a task whose turn has ended, gets
  `{:error, :not_current}`.

On success the server applies `checkpoint_session/2` to its cached
session immediately, so the identifier survives a later failure,
interrupt, or watchdog timeout. The rejections in the list above that
come from the active task (`:unsupported_checkpoint`,
`:invalid_session_id`, `:conflicting_session_id`) are recorded, and the
turn fails with that reason even if the stream later reaches `:result`
(`handle_task_result/3` in server.ex). `{:error, :not_current}` is not
recorded and does not affect any turn. The backend must
also fail its own turn when a checkpoint is rejected. The Claude and
Codex backends raise, which crashes the task.

### Event capture limits

The server bounds the events it retains per turn:

| Option | Default | Set in |
|---|---|---|
| `:max_events_per_turn` | `1_000` | `start_agent/2` or `child_spec/2` |
| `:max_event_bytes_per_turn` | `1_048_576` | `start_agent/2` or `child_spec/2` |
| `:event_retention` | `:compact` | `start_agent/2` or `child_spec/2` |

Bytes are the sum of `:erlang.external_size/1` over retained events.
`init_impl/1` in server.ex raises `ArgumentError` for a limit that is
not a positive integer or a retention mode other than `:compact` or
`:lossless`.

With `:compact` (`capture_compact_event/5` in server.ex), every
event still reaches `handle_stream_event/2` and the stream is read to
its terminal event. Once a limit is reached, later events are left
out of `Response.events`, and `Response.event_coverage` reports the
counts and the first omission. Response text, usage, and the terminal
event are built from the full stream.

With `:lossless` (`capture_event/5` in server.ex), the first event
that would exceed either limit stops consumption and fails the turn
with `{:event_capture_overflow, diagnostics}`. The diagnostics map
carries `:limit`, `:max_events`, `:max_bytes`, `:retained_events`,
`:retained_bytes`, `:rejected_event_kind`, and
`:rejected_event_bytes`.

A backend that emits one event per small delta uses the event budget
faster than one that emits completed messages. Checkpoints are not
events and do not count against either limit.

### Start errors

`init_impl/1` in server.ex calls `start_session/1` after
`init_agent/1`. If it returns `{:error, reason}`, the agent stops
during init and `GenAgent.start_agent/2` returns
`{:error, {:backend_start_failed, reason}}`. If `start_session/1`
raises, `init/1` in server.ex catches it and `start_agent/2`
returns `{:error, {:init_failed, kind, reason_kind}}`, where
`reason_kind` is the exception module, or `:other` for a throw or exit
that is not an exception.

Validate options and credentials in `start_session/1` when they can be
checked without network access, so that misconfiguration fails at
start rather than on the first prompt.

### `terminate_session/1`

`terminate/3` in server.ex calls `terminate_session/1` after it has
killed any active prompt task and called `terminate_agent/2`. The call
goes through `safely_call/3` in server.ex, which ignores raises and
exits. It runs on a normal stop and on crashes that reach `terminate/3`.
It does not run when the agent is killed with `:kill`. Make it
idempotent and do not depend on it for cleanup that must happen.

### Interruption, the watchdog, and stop

Three paths end an active turn early. All of them call
`cleanup_task/1` in server.ex, which sends `Process.exit(pid, :kill)`
to the prompt task:

| Path | Trigger | Error delivered |
|---|---|---|
| Interrupt | `GenAgent.interrupt/1` or `GenAgent.interrupt_request/3` | `:interrupted` |
| Watchdog | `:state_timeout` after `:watchdog_ms` (default 10 minutes) | `:timeout` |
| Stop | `GenAgent.stop/2`, through `terminate/3` in server.ex | none; the agent exits |

The task is killed, so `after` blocks and stream cleanup functions in
the prompt task do not run. On stop, `terminate_session/1` runs after
the task is killed, but not after `:kill`. The
session from the killed turn is discarded, except for identifiers
already applied through checkpoints.

Killing the BEAM task does not stop an operating system process or a
remote request. If the backend starts a subprocess, it is responsible
for making sure that subprocess exits when the task dies, for example
with a runner that kills the process group. The `GenAgent.Backend`
moduledoc states the same rule under "Cancellation and cleanup".

### Skeleton

A backend that echoes the prompt. It implements the three required
callbacks and `update_session/2`:

```elixir
defmodule MyApp.Backends.Echo do
  @behaviour GenAgent.Backend

  alias GenAgent.Event

  defstruct [:prefix, turns: 0]

  @impl GenAgent.Backend
  def start_session(opts) do
    case Keyword.get(opts, :prefix, "") do
      prefix when is_binary(prefix) -> {:ok, %__MODULE__{prefix: prefix}}
      other -> {:error, {:invalid_option, :prefix, other}}
    end
  end

  @impl GenAgent.Backend
  def prompt(%__MODULE__{} = session, prompt) when is_binary(prompt) do
    text = session.prefix <> prompt

    events = [
      Event.new(:text, %{text: text}),
      Event.new(:usage, %{input_tokens: 0, output_tokens: 0}),
      Event.new(:result, %{text: text, session_id: "echo"})
    ]

    {:ok, events, session}
  end

  @impl GenAgent.Backend
  def update_session(%__MODULE__{} = session, _result_data) do
    %{session | turns: session.turns + 1}
  end

  @impl GenAgent.Backend
  def terminate_session(%__MODULE__{}), do: :ok
end
```

The agent supplies backend options from `init_agent/1`:

```elixir
@impl true
def init_agent(opts) do
  {:ok, [prefix: Keyword.get(opts, :prefix, "echo: ")], %{}}
end
```

```elixir
{:ok, _pid} = GenAgent.start_agent(MyAgent, name: "echo", backend: MyApp.Backends.Echo)
{:ok, response} = GenAgent.ask("echo", "hello")
response.text
# => "echo: hello"
```

## Choosing a backend

The table reflects the current code of each backend module and the
wrapper it calls. "Not documented" means the code in this repository
does not establish the value.

| | Claude | Codex | Anthropic | OpenAI |
|---|---|---|---|---|
| Module | `GenAgent.Backends.Claude` | `GenAgent.Backends.Codex` | `GenAgent.Backends.Anthropic` | `GenAgent.Backends.OpenAI` |
| Transport | `claude` CLI, stream-json, via `ClaudeWrapper.stream/2` | `codex exec` NDJSON via `CodexWrapper.Exec` and `ExecResume` | `POST /v1/messages` via `Req` | `POST /v1/responses` via `Req` |
| System prompt option | `:system_prompt` (also `:append_system_prompt`) | None. Use `AGENTS.md` or Codex configuration | `:system` | `:instructions`, resent every turn |
| Default model | Not set by the backend; CLI default not documented | Not set by the backend; CLI default not documented | `"claude-sonnet-4-5"` | `"gpt-5"` |
| Output token option | None | None | `:max_tokens`, default `1024` | `:max_output_tokens`, default unset |
| Session continuity | CLI `session_id`, passed as `--resume` on later turns | Codex `thread_id`, continued with `codex exec resume` | Full messages array kept in the session and resent each turn | `previous_response_id` with `store: true` (default); local input/output history resent with `store: false` |
| Checkpoints (`prompt/3`) | Yes, from `system`, `result`, or `error` events | Yes, from `thread.started`, `turn.completed`, `turn.failed`, and `error` events | No | No |
| Text as deltas | Yes, with `:include_partial_messages` (on by default) | No. One `:text` per completed message, with `message_boundary: true` | No. Text only on `:result` | No. Text only on `:result` |
| Tool events | `:tool_use` and `:tool_result` from CLI content blocks | `:tool_use` and `:tool_result` from completed items | None | None |
| Usage keys | `:input_tokens`, `:output_tokens` | `:input_tokens`, `:output_tokens`, `:cached_input_tokens` | `:input_tokens`, `:output_tokens` | `:input_tokens`, `:output_tokens`, `:total_tokens`, `:reasoning_tokens` |
| Unknown options | Ignored by the wrapper; `no_session_persistence: true` is rejected | Rejected with `{:unsupported_option, key}` | Ignored | Ignored |
| Credentials at start | Not checked | Not checked | `{:error, :missing_api_key}` without a key, unless a one-arity `:http_fn` is set | `{:error, :missing_api_key}` without a key, unless a one-arity `:http_fn` is set |
| Cancellation of the underlying process | Default Port runner closes pipes and sends no signal; `ClaudeWrapper.Runner.Forcola` kills the process group | Default Port runner closes the port and sends no signal; `CodexWrapper.Runner.Forcola` kills the process group | Request runs in the prompt task; provider-side cancellation not documented | Request runs in the prompt task; provider-side cancellation not documented |

### Notes on the table

- **Transport.** `GenAgent.Backends.Claude.prompt/2` calls the
  `:stream_fn` option, default `&ClaudeWrapper.stream/2`.
  `GenAgent.Backends.Codex` dispatches through `:exec_fn`, default
  `Exec.stream/2` on the first turn and `ExecResume.stream/2` after a
  thread ID is known. The HTTP backends call `Req.post/2` with
  `retry: false` and a `:receive_timeout` default of `60_000`, through
  the replaceable `:http_fn` option.
- **System prompt.** The Claude backend forwards query options to
  `ClaudeWrapper.Query.apply_opts/2`. The Codex moduledoc states it
  has no equivalent of `--system-prompt`. `GenAgent.Backends.Anthropic`
  puts `:system` in the request body.
  `GenAgent.Backends.OpenAI.build_request/2` puts `:instructions` on
  every request. The Responses API does not carry instructions across
  `previous_response_id`, and stateless requests replay conversation
  items while resending the configured instructions.
- **Default model.** The CLI backends add `--model` only when
  `:model` is set (`ClaudeWrapper.Query`, `CodexWrapper.Exec`). The
  HTTP defaults are the `@default_model` attributes.
- **Output tokens.** Neither CLI backend lists an output token option.
  On Codex, passing one is an unknown option and is rejected.
- **Session continuity.** `GenAgent.Backends.Claude.update_session/2`
  and `checkpoint_session/2` store `session_id`; the next turn drops
  `:session_id` and `:continue_session` and sets `:resume`.
  `GenAgent.Backends.Codex.EventTranslator` copies `thread_id` from
  `thread.started` into the `:result` as `:session_id`. The Anthropic
  `:result` carries a client-generated `session_id` beginning with
  `"anthropic-"`; history lives in `session.messages`, and
  `update_session/2` removes the unanswered user message on an empty
  or refused reply. The OpenAI `:result` carries a client-generated
  `session_id` beginning with `"openai-"` and a `:response_id`. With
  `store: true`, `update_session/2` saves the response ID for the next
  request. With `store: false`, it adds the completed input and output
  items to local history; the next request resends them without a
  `previous_response_id`.
- **Text.** `GenAgent.Backends.Claude.EventTranslator` turns stream
  deltas into `:text` events and drops text from the completed
  assistant message that was already streamed. The Codex translator
  emits `:text` for each completed `agent_message` item, and its
  `:result` has no `:text`, so `Response.text` is assembled from those
  events. The HTTP backends return a list of at most two events
  (`:usage`, then the terminal), so `handle_stream_event/2` sees no
  text before the turn ends.
- **Tool events.** The Claude translator dedupes tool events by ID.
  The Codex translator emits both `:tool_use` and `:tool_result` for
  completed `mcp_tool_call`, `command_execution`, and `file_change`
  items, and ignores `item.started` and `item.updated`. Neither HTTP
  backend sends tool definitions.
- **Usage.** On Claude, cost is on the `:result` data as `:cost_usd`,
  not on the `:usage` event. On OpenAI, `:reasoning_tokens` comes from
  `usage.output_tokens_details.reasoning_tokens`.
- **Errors.** Claude emits `:error` for CLI `error` events and for
  `result` events with `is_error` or an `error` subtype. Only the
  failed `result` case builds a map reason with `:provider`, `:subtype`,
  `:message`, and related fields. A CLI `error` event passes its raw
  `error` or `message` value through, for example the string
  `"stream_truncated"` from the wrapper, so handlers must not assume a
  map.
  Codex emits `:error` for `turn.failed`, or for an `error`
  notification when the stream ends without a turn outcome. OpenAI
  emits `:error` with `{:response_failed, _}`,
  `{:response_incomplete, _}`, `{:refusal, _}`, or
  `{:unexpected_response_status, _}`. Anthropic does not emit
  `:error`; a refusal is a `:result` with `stop_reason: "refusal"`.
  Both HTTP backends return `{:error, {:http_error, status, body}}`
  from `prompt/2` for a non-200 response.
- **Unknown options.** `GenAgent.Backends.Claude.start_session/1`
  rejects `:no_session_persistence` when it is enabled (truthy) with
  `{:error, {:unsupported_option, :no_session_persistence}}`. Other
  keys reach `ClaudeWrapper.Query.apply_opts/2`, whose final clause
  ignores unrecognized keys; some recognized enum options raise
  `ArgumentError` for invalid values when the command is built.
  `GenAgent.Backends.Codex.validate_exec_opts/1` returns
  `{:unsupported_resume_option, key}` for `:cd`, `:add_dirs`, and
  `:search`, `{:unsupported_option, key}` for any other key outside
  its list, and `{:invalid_approval_policy, value}` for a policy other
  than `:untrusted`, `:on_request`, or `:never`. The HTTP backends read
  their options with `Keyword.get/3` and ignore the rest.
- **Credentials.** The CLI backends take no credential option and do
  not check authentication in `start_session/1`. The HTTP backends read
  `:api_key`, then `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`, and treat a
  blank string as missing.
- **Cancellation.** Both CLI backends' `terminate_session/1` return
  `:ok` with nothing to close. The Port runner behaviour is described
  in `ClaudeWrapper.Runner.Port` and `CodexWrapper.Runner.Port`, and the
  Forcola runner is selected with
  `config :claude_wrapper, runner: ClaudeWrapper.Runner.Forcola` or
  `config :codex_wrapper, runner: CodexWrapper.Runner.Forcola`. The
  HTTP backends' `terminate_session/1` also return `:ok`.
