# Design Note 002: Backend Protocol

Status: Implemented (v0.1.0)
Retroactive. Captures rationale for decisions already baked into
the codebase.

## Shape

`GenAgent.Backend` is a behaviour with four required callbacks and
two optional:

- `start_session/1` -- once at agent boot.
- `prompt/2` -- per turn. Returns an enumerable of `GenAgent.Event`
  and an updated session.
- `terminate_session/1` -- once at agent shutdown.
- `update_session/2` (optional) -- fold terminal-event data back into
  the session (e.g. capture the session id Claude assigns on first
  response).
- `resume_session/2` (optional) -- future persistence feature; v0.1
  does not call it.

The session is an **opaque term** owned by the backend. The state
machine stores it, passes it back on every call, and replaces it
with whatever `prompt/2` / `update_session/2` return.

## Why opaque term, not a GenServer

Considered: every backend is itself a GenServer, referenced by pid
or name. GenAgent would call it via `GenServer.call` on each turn.

Rejected because:

1. A lot of backends don't need a process -- HTTP-based ones
   (`Anthropic`) just hold a URL, API key, and optional session id.
   Forcing a GenServer is ceremony.
2. Backends that DO need a process (CLI wrappers like `Claude` and
   `Codex`) can store the pid inside the opaque session term and
   manage it themselves. They pay for the process, not everyone.
3. Opaque terms compose cleanly across restarts and persistence --
   a future "resume from disk" feature serializes a term, not a pid.

The cost is that backends must be careful not to mutate external
state the state machine doesn't see. `prompt/2` returning a new
session is the escape hatch for "the backend learned something new
this turn."

## Why a synchronous event stream, not a GenStage / message stream

`prompt/2` returns `{:ok, Enumerable.t(Event.t()), session}`. The
state machine consumes the enumerable inside a `Task`, threading
events through `handle_stream_event/2` until a terminal event
(`:result` or `:error`) arrives.

Considered: push events as messages to the agent process, let the
state machine drive consumption.

Rejected because:

1. Backpressure is free with an enumerable -- the consumer controls
   pull rate, no buffering layer needed.
2. CLI wrappers already expose line-oriented output as lazy streams.
   Matching that shape means the backend can return the stream it
   already has with zero adaptation.
3. Messages would race with the state machine's own mailbox
   (`{:notify, event}`, `{:call, ...}`). Isolating event consumption
   to a task sidesteps the ordering question entirely.

## Why terminal events inline, not out-of-band

Contract: the last element of the stream MUST be a terminal event
(`kind: :result` or `kind: :error`). The state machine stops
consuming after one.

Considered: a separate `await_result/1` callback that the state
machine polls after the stream drains.

Rejected because it forks the happy path into two phases (stream +
wait), and backends that already have terminal data in their
response (HTTP) would have to artificially split it. Making the
terminal event part of the stream keeps backend code single-path.

## Load-bearing consequences

- A backend MUST emit a terminal event. The state machine treats
  "stream ended without terminal" as `{:error, :no_terminal_event}`
  and delivers it to `handle_error/3`.
- `start_session/1` is synchronous and blocks `start_agent/2`. Slow
  setup should go in `pre_run/1` (design note 005), not here.
- `terminate_session/1` runs from `terminate/3` in the server, which
  means it fires on every path including crashes. It must be
  idempotent and must not raise.
