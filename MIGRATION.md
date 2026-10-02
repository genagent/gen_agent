# Upgrading GenAgent

## Runtime changes since 0.2.0

The core package and its integrations have separate versions. Check the
version of **`gen_agent`**, as well as the version of the adapter you use,
before changing an application's dependency requirements.

| Core version | Change to account for |
| --- | --- |
| 0.2.2 | A turn that exceeds the retained-event count or byte limit fails with `{:error, {:event_capture_overflow, diagnostics}}`. |
| 0.3.0 | Pending prompts and notifications have bounded queues. `ask/3` and `tell/3` can reject admission with `{:error, {:overloaded, info}}`; `tell_with_completion/4` adds request-scoped completion messages. |
| 0.5.0 | Queued tells can be cancelled by ref with `cancel_request/3`. |
| 0.6.0 | Compact event retention is the default: long turns can succeed while `Response.events` contains only a prefix. Check `Response.event_coverage`; choose `event_retention: :lossless` for the earlier overflow contract. Claude and Codex checkpoint session IDs during a turn, so an interrupted or failed turn can retain its conversation ID. |

### Event evidence and long turns

From 0.2.2 through 0.5.0, the default limits are 1,000 normalized events
and 1,048,576 bytes of retained event terms per turn. An event that does not
fit fails the turn with `{:event_capture_overflow, diagnostics}`; the rejected
event is not passed to `handle_stream_event/2`. Both limits can be changed
with positive integers in `start_agent/2` or `child_spec/2`:

```elixir
GenAgent.start_agent(MyApp.Agent,
  name: "worker",
  backend: GenAgent.Backends.Codex,
  max_events_per_turn: 5_000,
  max_event_bytes_per_turn: 8_388_608
)
```

In 0.6.0, compact retention still calls
`handle_stream_event/2` for every normalized event, but retains only the
prefix that fits. The terminal result, full response text, latest usage, and
session ID remain separate from that prefix. A consumer that treats
`Response.events` as a complete trace must check coverage first:

```elixir
case GenAgent.ask("worker", "Inspect the project") do
  {:ok, %{event_coverage: %{mode: :exact}} = response} ->
    {:complete_log, response.events}

  {:ok, %{event_coverage: %{mode: :compact}} = response} ->
    {:partial_log, response.events, response.event_coverage, response.terminal}

  {:error, reason} ->
    {:error, reason}
end
```

For callers that require the previous fail-on-truncation behavior, set
`event_retention: :lossless` when starting the agent and handle
`{:error, {:event_capture_overflow, diagnostics}}`. If a full log must be
stored, raise the limits to suit the workload or persist events as they
arrive in `handle_stream_event/2`; neither mode makes provider output or
callback state unbounded-memory safe. See [Event capture bounds](README.md#event-capture-bounds)
for the precise retention and callback contract.

### Admission and return shapes

Since 0.3.0, each agent has separate pending-prompt and deferred-notification
queues. Each defaults to 1,000 items and 1,048,576 bytes of queued payloads.
The active prompt and notifications handled while idle do not count as
pending. Set `:max_pending_prompts`, `:max_pending_prompt_bytes`,
`:max_pending_notifications`, and `:max_pending_notification_bytes` at agent
startup; zero disables the corresponding pending queue. These are admission
limits, not total BEAM mailbox or process-memory limits.

Replace success-only matches with handling for rejection. An overloaded
`tell/3` returns **no ref** to poll or cancel:

```elixir
case GenAgent.tell("worker", "Review the diff") do
  {:ok, ref} ->
    {:accepted, ref}

  {:error, {:overloaded, %{queue: :prompts} = info}} ->
    {:rejected, info}

  {:error, reason} ->
    {:error, reason}
end
```

`ask/3` can return the same overload shape before accepting a turn. The
caller must decide whether to retry after capacity returns; rejected tells
have no corresponding result to poll. The
`info` map includes `:limit` (`:count` or `:bytes`), current count and bytes,
incoming bytes, and configured maxima. `notify/2` still returns `:ok` for a
cast even if the agent later rejects it; use `notify_ack/3` for an immediate
in-memory admission result. Admission is not durable delivery. See
[Pending input bounds](README.md#pending-input-bounds).

### Codex backend options

The Codex adapter validates the options returned by an agent's
`init_agent/1`. An unknown option such as `:system`, `:system_prompt`, or
`:max_tokens` causes agent startup to return
`{:error, {:backend_start_failed, {:unsupported_option, option}}}`.
Options such as `:cd`, `:add_dirs`, and `:search` cannot be preserved across
`codex exec resume` and return `{:unsupported_resume_option, option}` inside
the startup error. Use `:cwd` or `:working_dir` for the persistent directory;
put Codex instructions in `AGENTS.md` or Codex configuration. For example,
an agent's callback can return `{:ok, [cwd: path, sandbox: :read_only], state}`.
See [Codex backend options](https://github.com/genagent/gen_agent/tree/main/integrations/codex#backend-options)
for the accepted keys; Claude and Codex do not share one option schema.

### Dependency requirements

An application requirement such as `{:gen_agent, "~> 0.2.0"}` excludes
0.3.0 and later; update it deliberately after adapting the return shapes.
The four adapter Mix projects accept core 0.2 through 0.6 through an explicit
`or` requirement, rather than pinning only 0.2. For core 0.6.0, use the
compatible adapter release lines: Claude 0.2.0, Codex 0.4.0, Anthropic 0.3.0,
or OpenAI 0.3.0. Ensemble 0.3.0 accepts core 0.3 through 0.6. Earlier
published adapter and Ensemble releases may exclude 0.6. Run `mix deps.get`
and your application tests after updating both core and integration
requirements.

## Source repository migration

The public Hex package and Elixir module names are unchanged. Applications
using published packages do not need a new dependency name. Update local
source paths and repository links when moving to this checkout:

| Package | New source | Previous repository |
| --- | --- | --- |
| `gen_agent_claude` | [`integrations/claude`](https://github.com/genagent/gen_agent/tree/main/integrations/claude) | [`gen_agent_claude`](https://github.com/genagent/gen_agent_claude) |
| `gen_agent_codex` | [`integrations/codex`](https://github.com/genagent/gen_agent/tree/main/integrations/codex) | [`gen_agent_codex`](https://github.com/genagent/gen_agent_codex) |
| `gen_agent_anthropic` | [`integrations/anthropic`](https://github.com/genagent/gen_agent/tree/main/integrations/anthropic) | [`gen_agent_anthropic`](https://github.com/genagent/gen_agent_anthropic) |
| `gen_agent_openai` | [`integrations/openai`](https://github.com/genagent/gen_agent/tree/main/integrations/openai) | [`gen_agent_openai`](https://github.com/genagent/gen_agent_openai) |
| `gen_agent_ensemble` | [`extensions/ensemble`](https://github.com/genagent/gen_agent/tree/main/extensions/ensemble) | [`gen_agent_ensemble`](https://github.com/genagent/gen_agent_ensemble) |

The previous repositories retain their historical issues, pull requests, and
tags. File new source issues and pull requests in
[`gen_agent`](https://github.com/genagent/gen_agent). The
[`claude_wrapper`](https://github.com/genagent/claude_wrapper_ex) and
[`codex_wrapper`](https://github.com/genagent/codex_wrapper_ex) repositories
remain independent.

For local development, use this repository and run Mix from the package
directory. The sibling Mix projects resolve core and each other by path.
For a publishable archive, set `GEN_AGENT_HEX=1` so the dependencies resolve
from Hex instead. See [RELEASING.md](https://github.com/genagent/gen_agent/blob/main/RELEASING.md)
for release order and tags.
