# Design Note 007: Per-Turn Options and Normalized Tool Events

Status: Proposed. Design for #192, the last Backend contract decision
before core 1.0. Nothing here is implemented.

## Problem

Two gaps remain in the Backend contract (design note 002).

1. `prompt/2` and `prompt/3` take a session and a binary. Model,
   output schema and attachments are fixed at `start_session/1`. The
   two backends that constrain output use different option names and
   value types (Claude `:json_schema` takes schema text, Codex
   `:output_schema` takes a file path), the HTTP backends have no
   schema option, and Codex re-sends its session `:images` on every
   turn, including `exec resume`.
2. `:tool_use` and `:tool_result` data is documented as
   backend-specific. Claude forwards Anthropic content blocks with
   string keys. Codex emits a compact string-keyed marker on
   `item.started` and the whole completed item as `:tool_result`, and
   also uses `:tool_result` for reasoning, todo lists and non-fatal
   errors. Every other event kind uses atom keys. A consumer that lists
   tool activity needs per-backend parsing.

## Out of scope

- **Executing application-defined tools in the HTTP backends.** Core
  has no tool-call loop. The Anthropic and OpenAI backends keep
  `tools` and `tool_choice` reserved and send no tool definitions. An
  application that needs model-requested calls into its own code
  implements its own `GenAgent.Backend`. The tool event shape below
  gives such a backend a defined way to report what it ran.
- **Tool definitions as a per-turn option.** Same reason.
- **Backend-specific per-turn keys.** Per-turn options are a fixed core
  vocabulary in 1.0. Backend-specific settings stay in `start_session/1`.
  A namespaced escape hatch can be added later without breaking anything.
- **Ensemble.** Ensemble is frozen to contract fixes. Its APIs do not
  accept turn options in 1.0; members use their session options.
- **Host exposure.** Passing turn options through gen_agent_server's
  Ops, CLI and MCP surfaces is a host decision, made on operating
  evidence.

## Per-turn options

### Vocabulary

Core owns three keys. Each value is validated by core at the API
boundary:

| Key | Type | Meaning |
|---|---|---|
| `:model` | non-empty binary | Model for this turn |
| `:output_schema` | map (a JSON Schema document) | Constrain this turn's final answer to the schema |
| `:attachments` | list of `{:image, path}` with a binary local path | Images added to this turn's user message |

An unknown key or a malformed value raises `ArgumentError` in the
caller, the same way `tell_with_completion/5` and
`GenAgent.Client.submit_with_completion/4` treat bad options today.
That is a programming error. Lack of backend support is a runtime
capability question and is returned as an error (below).

### How they reach the backend

Turn options belong to a request. They travel with it through
admission, the queue, `pre_turn/2` and dispatch.

Submission:

- `tell_with_completion/5` and `Client.submit_with_completion/4` accept
  `turn: keyword()` in their existing option lists.
- `ask/4` and `tell/4` gain an options list after the timeout, with the
  same `:turn` key. `ask/3` and `tell/3` are unchanged.
- Callbacks may return `{:prompt, text, state, turn_opts}`, following
  the GenServer convention of extras after the state. The three-element
  `{:prompt, text, state}` stays valid and means no turn options.

Dispatch: the `prompt/3` context gains a `:turn` key, a map that is
always present and empty when the request has no turn options:

```elixir
backend.prompt(session, prompt, %{checkpoint: checkpoint, turn: %{model: "..."}})
```

Existing implementations match `%{checkpoint: checkpoint}` and keep
working. `prompt/2` never receives turn options.

`pre_turn/2` keeps its signature. It can rewrite the text, skip or
halt, and the request's turn options pass through unchanged. A
`pre_turn/3` that can see or rewrite them can be added later if a host
needs policy over them.

### Declared support, and no silent drops

A new optional callback declares which keys a backend applies:

```elixir
@callback turn_options() :: [:model | :output_schema | :attachments]
```

The default is `[]`. A backend that does not export `prompt/3` is
treated as `[]` whatever it declares.

The server checks the request's keys against `backend.turn_options()`
at admission. A key outside the list rejects the request with
`{:unsupported_turn_option, key}` before it is queued:

- `ask` and `tell` return `{:error, {:unsupported_turn_option, key}}`.
- `tell_with_completion` returns the error; `submit_with_completion`
  sends an admission error and nothing else (design note 006,
  "Admission rejection").
- A callback-generated prompt with an unsupported key goes to
  `handle_error/3` with the same reason, as a rejected generated prompt
  does today.

A declared key whose value the backend cannot use for this turn (an
unreadable image path, an image type the provider does not accept) is
returned synchronously from `prompt/3` as
`{:error, {:invalid_turn_option, key, reason}}`, before any provider
call. That reaches `handle_error/3` and the caller like any synchronous
dispatch error.

Considered: widen the `prompt/3` context and require each backend to
reject what it does not apply. Rejected because a backend written
against 0.11 that ignores `:turn` would drop options silently, which is
the failure #192 exists to remove. The static list lets core enforce
rejection for every backend, lets a host see support before submitting,
and fails at admission rather than after queueing.

Considered: a new callback that applies turn options to the session and
returns a turn-scoped session. Rejected because `prompt/3` returns the
session the server caches for the next turn, so turn values would leak
into later turns unless every backend cleared them.

### Precedence and persistence

- A turn value replaces the session value for the same concept, for
  that turn only. Values are not merged: a turn schema replaces the
  session schema, it does not combine with it.
- The session `prompt/3` returns must not retain turn values. The next
  turn without turn options runs with the session values.
- The same concept under a backend-specific session name is overridden
  too: a turn `:output_schema` overrides Claude's session
  `:json_schema` and Codex's session `:output_schema` path. For the HTTP
  backends it overrides a `request_fields` entry that sets the
  provider's response-format field.
- Attachments are part of the turn's user message, not configuration.
  They stay in the conversation the way each provider keeps history:
  in the Codex thread, in OpenAI's stored response chain, or in the
  locally retained history of Anthropic and OpenAI `store: false`
  (subject to `:max_history_turns`). They are attached once, on the
  turn that carries them, and are never re-attached by the backend.

### Retries and follow-ups

Turn options belong to the request reference:

- A `handle_error/3` retry of an ask or tell keeps the original request
  reference, so a three-element `{:prompt, text, state}` retry keeps the
  request's turn options. A four-element return replaces them.
- A follow-up with a new request reference (`handle_response/3`, events,
  self-chains, a prompt returned after interruption) starts with no turn
  options unless it returns the four-element form.

### Queue, status and telemetry

- `:erlang.external_size/1` of the turn options counts toward the
  serialized prompt-byte budget for queued work, so large schemas are
  bounded the same way large prompts are.
- Values are not exposed in status or telemetry metadata. Schemas and
  attachment paths can carry sensitive data (#176). Turn start metadata
  may carry the list of keys.
- `Response.model` already comes from the terminal event. A backend
  that falls back to the requested model (Codex) uses the turn model
  when one was given.

### Output schema results

For a turn with `:output_schema`, `Response.text` is the JSON document
on every backend that declares the key. Core does not decode it;
decoding stays with the caller.

- Claude: when the raw result carries `structured_output`, the
  terminal `:text` is that value encoded as JSON; otherwise the result
  text.
- Codex: the turn uses `response_text: :final_message` semantics, so
  earlier narration does not break parsing. The session's
  `:response_text` setting is unchanged for other turns.
- Anthropic and OpenAI: the answer text, which the provider constrains
  to the schema.

### Per backend

| Backend | `:model` | `:output_schema` | `:attachments` |
|---|---|---|---|
| Claude | Yes. Replaces `--model` for the call, including `--resume` turns | Yes. JSON-encoded into `--json-schema` | No. The CLI backend sends text; images would need `input_format: :stream_json` |
| Codex | Yes. `exec` and `exec resume` both take `--model` | Yes. Written to a content-addressed file (below) | Yes. `--image` on this turn only |
| Anthropic | Yes. Request `model` | Yes. The provider's JSON-schema output field | Yes. Base64 image content blocks in the user message |
| OpenAI | Yes. Request `model`; `previous_response_id` allows a different model | Yes. The provider's JSON-schema `text` format | Yes. `input_image` content in the user input |

The provider field names for schema output on the HTTP backends are
checked against the provider documentation in the implementation PR.
Both HTTP backends also gain a session-level `:output_schema` (map),
since they have none today. Claude and Codex keep their existing
session names; only the turn vocabulary is normalized.

A model switch mid-conversation can fail at the provider, for example
Anthropic thinking blocks retained under `request_fields.thinking` or
OpenAI reasoning items resent with `store: false`. The backend reports
the provider's error; it does not rewrite history.

Codex schema files: Codex takes a schema path. The backend writes the
encoded schema once to `gen_agent_codex/schema-<sha256>.json` under
`System.tmp_dir!/0` and reuses the file for identical schemas. It does
not delete the file after the turn. Per-turn deletion would depend on a
stream finalizer, which does not run after an abrupt exit (design note
002), so files would leak on interruption anyway. Content addressing
bounds the files by the number of distinct schemas.

### Codex session `:images` on resumed turns

Today `build_exec_resume/3` re-attaches every session image on every
`exec resume`, so each turn re-sends images the thread already holds.
In the Codex release that adds turn options, session `:images` applies
to a fresh `exec` only (the first turn, and the first turn after
`reset_session/1`), as `:profile` already does. It is deprecated with a
warning in favor of turn `:attachments`, and removed in the Codex
release that requires core 1.0. On a first turn with both, session
images are attached before turn attachments.

## Normalized tool events

### Shape

```elixir
@type tool_use_data :: %{
        required(:id) => String.t() | nil,
        required(:name) => String.t(),
        required(:input) => map(),
        required(:raw) => map(),
        optional(:server) => String.t(),
        optional(:parent_tool_use_id) => String.t()
      }

@type tool_result_data :: %{
        required(:id) => String.t() | nil,
        required(:name) => String.t() | nil,
        required(:output) => term(),
        required(:is_error) => boolean(),
        required(:raw) => map(),
        optional(:server) => String.t(),
        optional(:parent_tool_use_id) => String.t()
      }
```

- Top-level keys are atoms, like every other event kind. Provider data
  inside `:input`, `:output` and `:raw` keeps its provider keys.
- `:raw` is the provider map unmodified: the content block (Claude) or
  the item (Codex). It is the started item on `:tool_use` and the
  completed item on `:tool_result`.
- `:input` is always a map, `%{}` when the provider reports none.
- `:server` is present when the provider reports an MCP server
  separately from the tool name.
- `:parent_tool_use_id` keeps its current meaning on Claude subagent
  output.

Ordering and pairing: a `:tool_result` with a non-nil `:id` follows a
`:tool_use` with the same `:id` in the same turn. A backend whose
provider reports only completion synthesizes the `:tool_use` from the
completed item immediately before the `:tool_result`.

The shape lives in `GenAgent.Event` as typespecs and moduledoc. Core
does not validate event data at runtime; the translators' tests do.

Considered: strip fields lifted into `:input` or `:output` from `:raw`
to avoid counting large values twice (Codex `aggregated_output`).
Rejected because a consumer reading `:raw` expects the provider's map
as sent. The duplicated bytes count toward the existing per-turn event
and byte caps (`Response.event_coverage` reports any omission).

### Claude mapping

| Field | `:tool_use` (block `"type" => "tool_use"`) | `:tool_result` (block `"type" => "tool_result"`) |
|---|---|---|
| `:id` | `"id"` | `"tool_use_id"` |
| `:name` | `"name"` | name of the turn's earlier `:tool_use` with that id, else `nil` |
| `:input` / `:output` | `"input"` | `"content"` (string or list of blocks) |
| `:is_error` | n/a | `"is_error" == true` |

The top-level `"tool_use"` and `"tool_result"` stream event types map
the same way. `translate_stream/1` already carries per-turn state for
deduplication; it adds an id-to-name map for the result lookup and
deduplicates on the normalized `:id`.

### Codex mapping

Codex reports actions as items. `item.started` becomes `:tool_use`
with input from the started item. `item.completed` becomes
`:tool_result`. When a completed action item has no earlier
`item.started` in the turn (`file_change` today), the translator emits
the synthesized `:tool_use` and the `:tool_result` together from the
completed item. `item.updated` stays ignored. The translator tracks
started ids per turn and drops each id on completion.

| Item type | `:name` | `:input` | `:output` |
|---|---|---|---|
| `command_execution` | `"command_execution"` | `%{"command" => command}` | `"aggregated_output"` |
| `file_change` | `"file_change"` | `%{"changes" => changes}` | `nil` |
| `mcp_tool_call` | `"tool"`, with `:server` from `"server"` | `"arguments"` | `"result"`, or `"error"` when present |
| `collab_tool_call` | `"tool"` | `"prompt"` and `"receiver_thread_ids"` | `"agents_states"` |
| `web_search` | `"web_search"` | `%{"query" => query}` | `nil` |

`:id` is the item `"id"`. `:is_error` is true when `"status"` is
`"failed"` or `"declined"`, when an MCP item carries `"error"`, or when
a command's `"exit_code"` is nonzero.

Completed `reasoning`, `todo_list` and non-fatal `error` items are not
tool calls. They move from `:tool_result` to a new nonterminal kind,
`:activity`, with `%{type: item_type, raw: item}`. `GenAgent.Event`
documents `:activity` as an optional kind; `GenAgent.Response` ignores
it, as it ignores tool events.

`guides/backends.md` still says the Codex translator ignores
`item.started`; the Codex implementation PR corrects it.

### HTTP backends

The Anthropic and OpenAI backends send no tool definitions and emit no
tool events. The shape is defined for custom backends that run their
own loop.

### Compatibility for current consumers

Consumers read tool data as string-keyed maps today
(`event.data["name"]`, `event.data["tool_use_id"]`). A switch straight
to atom keys would return `nil` from those reads without an error.
Migration is in two steps:

1. **Transitional** (the Claude and Codex minors that adopt this note):
   event data is the provider map's top-level string keys merged with
   the normalized atom keys, including `:raw`. Both `data["name"]` and
   `data.name` / `data.raw["name"]` work. The provider map is counted
   twice in event bytes during this window.
2. **Final** (the backend releases that require core 1.0): the
   top-level string keys are dropped. Only the normalized keys and
   `:raw` remain.

Code written against the final shape works in both steps. The Codex
move of activity items to `:activity` happens in step 1, since it
cannot be made compatible and these are 0.x minors.

## Migration and versioning

Current releases: core 0.11.0 (with `GenAgent.list/0` unreleased on
main), gen_agent_claude 0.5.0, gen_agent_codex 0.8.0,
gen_agent_anthropic 0.6.0, gen_agent_openai 0.6.0.

1. **Core 0.12.0, additive.** `turn_options/0`, the `:turn` context
   key, `turn:` on the submission APIs, `ask/4` and `tell/4`, the
   four-element `{:prompt, ...}` return, admission rejection, queue byte
   accounting, the tool data typespecs, and the `:activity` kind. With
   no turn options, behavior is unchanged for every existing backend
   and caller.
2. **Backend minors requiring core `~> 0.12`.** Claude and Codex:
   `turn_options/0`, turn option handling, the transitional tool shape;
   Codex also activity items, schema files and the session `:images`
   change. Anthropic and OpenAI: `turn_options/0`, turn option
   handling, session `:output_schema`. Each is a separate PR with its
   own tests.
3. **Operate** gen_agent_server on these releases, as #71 step 2 did
   for 0.11, and record what hurts before freezing.
4. **Core 1.0.0.** No new surface. The Backend behaviour, the event
   kinds, the tool data shape and the turn option vocabulary become the
   stable contract. Release-please needs a `Release-As: 1.0.0` footer,
   because `bump-minor-pre-major` turns a breaking change under 1.0
   into a minor bump. Backend releases requiring `~> 1.0` drop the
   transitional string keys and Codex session `:images`. Whether the
   backends also move to 1.0 is decided at that release.

## Tests the implementation adds

Core:

- `ArgumentError` for an unknown turn key and for each malformed value.
- Admission rejection with `{:unsupported_turn_option, key}` on `ask`,
  `tell`, `tell_with_completion` and `submit_with_completion`, and
  `handle_error/3` for a generated prompt; a backend without
  `prompt/3` rejects any turn option.
- `prompt/3` receives `turn: %{}` without options and the given map
  with them; the next turn without options receives `%{}`.
- A `handle_error/3` retry keeps the request's turn options; a
  four-element retry replaces them; a `handle_response/3` follow-up
  starts empty.
- Turn option bytes count toward the queued prompt-byte budget.
- Status and telemetry do not contain turn option values.

Backends:

- Each declared option on a fresh turn and on a resumed turn, and the
  session value restored on the following turn.
- Claude rejects `:attachments` at admission.
- Codex: session `:images` on `exec` only, never on `exec resume`; turn
  attachments on their turn only; identical schemas share one file.
- `Response.text` is the JSON document for a schema turn on each
  backend (recorded or stubbed responses).
- Tool events: every Claude block type and every Codex item type in the
  tables, pairing ids, the synthesized `:tool_use` for completion-only
  items, the Claude name lookup, `:is_error` cases, the transitional
  keys in step 1 and their absence in step 4, and Codex activity items
  as `:activity`.
