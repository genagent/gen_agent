# Design Note 003: Process Lifecycle

Status: Implemented (v0.1.0)
Retroactive. Captures rationale for three entangled decisions:
`trap_exit: true`, `restart: :temporary`, and the three distinct
"stop an agent" primitives.

## `trap_exit: true`

`GenAgent.Server.init/1` calls `Process.flag(:trap_exit, true)`.

Without it, `DynamicSupervisor.terminate_child/2` sends
`exit(pid, :shutdown)`, which kills the process without running
`terminate/3`. Our `terminate/3` is where `terminate_session/1`
(backend cleanup) and `terminate_agent/2` (user cleanup) run. Losing
those means orphaned backend sessions, leaked CLI processes, and
user cleanup code that silently never fires.

Trapping exits converts the shutdown into
`{:EXIT, parent, :shutdown}` -- which `:gen_statem` handles by
calling `terminate/3` before the process dies. That's the fix.

Cost: trapping exits means crashes from linked processes become
messages instead of auto-propagating. We have none of those at the
moment (the prompt task is `async_nolink`), so the cost is zero in
practice, but it's worth knowing.

## `restart: :temporary`

The child_spec sets `restart: :temporary`. Considered: `:transient`
(restart on abnormal exit, not on normal).

Rejected because an agent carries state that cannot be rebuilt
without persistence:

- Backend session id (assigned by the LLM after the first response).
- Self-accumulated message history / conversation context.
- User-defined `agent_state` with whatever the implementation stuffed in.

A `:transient` restart would silently produce a "fresh" agent with
the same name, no memory of prior turns, and no warning. That's
worse than the agent just being dead -- at least a dead agent's
absence is visible.

`:temporary` forces users to explicitly call `start_agent/2` again
when they want a new one. If we add persistence later (snapshot
`agent_state` + `backend_session` to disk between turns), we can
reconsider.

## Three ways to stop an agent

There are three primitives that look superficially similar:

| Primitive | Semantics | Process alive after? |
|-----------|-----------|----------------------|
| `halt` (callback return) | Agent is "done." Goes idle, mailbox freezes. | Yes |
| `interrupt/1` | Kill in-flight turn, deliver `:interrupted` to waiter. | Yes |
| `stop/1` | Tell the DynamicSupervisor to terminate the child. | No |

### `halt` is not `stop`

`{:halt, state}` is the semantic "this agent has finished its job"
signal. The process stays alive because:

- `post_run/1` needs to run on the halted state (design 005).
- The manager may want to read final state via `status/1`.
- `resume/1` can unhalt and drain the queued mailbox.

Using `stop/1` to "finish" an agent would throw away the final
state before anyone observed it.

### `interrupt` is not `halt`

`interrupt/1` cancels an in-flight turn (kills the prompt task,
delivers `{:error, :interrupted}` to the waiting caller), then
returns to idle to drain the next piece of work. The agent is NOT
halted; it just lost one turn.

Users who want "interrupt AND halt" return `{:halt, state}` from
`handle_error/3` in response to the interrupt.

### `stop` is the only one that kills the process

`stop/1` is for "I am done with this agent forever." It routes
through `DynamicSupervisor.terminate_child/2` so the supervisor's
`terminate/3` path runs, which means `terminate_session/1` and
`terminate_agent/2` fire cleanly thanks to `trap_exit`.

## Load-bearing consequences

- If you want an agent to "finish and clean up," use `{:halt, state}`
  then let the manager call `stop/1` after it's observed the final
  state. The two-step separates "work is done" from "resources are
  gone."
- `handle_error/3` seeing `:interrupted` as a reason is the signal
  for "the caller aborted"; the default implementation's
  `{:noreply, state}` keeps the agent alive, which is usually what
  you want.
- A crashed agent is GONE. There is no auto-restart. This is
  intentional (see `:temporary` above).
