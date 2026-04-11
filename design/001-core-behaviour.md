# Design Note 001: Core Behaviour

Status: Implemented (v0.1.0)
Retroactive. Captures rationale for decisions already baked into
the codebase.

## Shape

`GenAgent` is a **behaviour**, not a GenServer wrapper. Users
`use GenAgent` and implement callbacks; the state machine lives in
`GenAgent.Server` as a `:gen_statem` with two states: `:idle` and
`:processing`. A prompt is a "turn": idle -> processing -> (decision
callback) -> idle.

The core callback is `handle_response/3`, which receives the turn's
`Response` and returns one of:

- `{:noreply, state}` -- go back to idle, wait for next input.
- `{:prompt, text, state}` -- self-chain another turn without a caller.
- `{:halt, state}` -- go idle but freeze the mailbox.

## Why a behaviour, not a GenServer

Considered: a `GenAgent.Session` GenServer that users wrap / configure.

Rejected because an agent has enough unique mechanics (mailbox with
queueing, current-request tracking, watchdog, halt/resume, streaming
events, self-chain) that wrapping GenServer would mean either
reimplementing those mechanics in every user's agent module, or
exposing a giant callback surface that is just a worse GenServer.

A dedicated behaviour lets the framework own all the mechanics and
gives the user a small semantic callback surface. The trade is that
GenAgent has to ship its own supervision + registry (`GenAgent.Application`,
`GenAgent.AgentSupervisor`, `GenAgent.Registry`) instead of piggybacking
on user-provided ones.

## Why `:gen_statem`, not `GenServer`

Two states with explicit transitions, a watchdog per state (`state_timeout`),
and a need for on-entry side effects (draining self-chain / mailbox)
are what `:gen_statem` exists for. Modeling the same thing in GenServer
would mean hand-rolling a state field and a bunch of `if data.state
== :idle` branches -- ugly and easy to get wrong when the number of
transition paths grows (which it did: pre_run, halt, interrupt, etc.).

`callback_mode: [:handle_event_function, :state_enter]` is the flavor
used -- one function, state as an argument, enter callbacks for
transition-side-effects.

## Why three return shapes, not more

`{:noreply | :prompt | :halt}` covers the three things a callback can
want to do: wait, continue immediately, stop. A fourth shape for
"wait N seconds then continue" was considered and rejected -- users
can achieve it with a self-sent notify or an external timer, and
adding it would bloat the contract.

The same return type is reused for `handle_error/3` and `handle_event/2`
so users only memorize one vocabulary.

## Load-bearing consequences

- `handle_stream_event/2` runs inside the prompt task, not the agent
  process, so it can update state mid-turn but must not call back into
  GenAgent API (would deadlock on self-call).
- `handle_response/3` is mandatory; everything else optional.
- The `agent_state()` is an opaque term owned by the implementation.
  The state machine does not inspect it.
