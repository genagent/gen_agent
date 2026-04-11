# Design Note 004: Notify Deferral During `:processing`

Status: Implemented (PR #1, merged into main before v0.1.1)
Retroactive. Captures the bug and the design choice behind the fix.

## The bug

Before the fix, notify events delivered via `GenAgent.notify/2` while
the agent was in `:processing` had their `handle_event/2` callback
invoked immediately from the agent process. The callback could
mutate `data.agent_state` freely.

That mutation was silently overwritten when the in-flight prompt's
task result arrived. `finish_turn/5` took `new_agent_state` from the
task (which had been threaded through `handle_stream_event/2`
against the state **as it was at dispatch time**, not the current
`data.agent_state`) and wrote it over everything the notify had
just set.

First surfaced in `Playground.Watcher`, where an event-driven agent
would visibly lose counter mutations. Post-hoc analysis confirmed
`Switchboard`'s summary-update and ack-inbox paths were also latently
vulnerable; `Supervisor` had a narrow race on `worker_result`
notifies. Research/Debate/Pipeline/Retry/Pool happened not to mutate
state in `handle_event` or had no events arriving during turns, so
they never hit it.

## Options considered

### A. Defer notifies during `:processing`

Buffer incoming notifies in a `pending_events` queue on Data. When
the turn finishes, drain the queue synchronously against the
post-decision state before transitioning to `:idle`.

Pro: preserves ordering (events are processed in arrival order,
just deferred). No contract change for `handle_event/2`. No data
loss.

Con: notifies are no longer "instant" -- a notify arriving 1ms into
a 10s turn waits 10s. Users reading the API might expect `notify/2`
to fire the callback right away.

### B. Snapshot state at dispatch, merge at turn end

Take a deep copy of `agent_state` at dispatch, let notifies mutate
the current state freely, then at turn end three-way merge: original
+ task's result + notify mutations.

Pro: notifies stay "instant."

Con: three-way merge on an opaque user-owned term is impossible
without a merge function. We'd need a new callback `merge_state/3`.
Huge surface area for a bug we can fix without it.

### C. Serialize the task's result reconciliation through the agent

Make `handle_stream_event/2` return `{:continue, state} | {:abort,
reason}` and re-run it against the current `data.agent_state` inside
the agent process at turn end, instead of building state up inside
the task.

Pro: no deferral, no merge, state mutations are re-applied in order.

Con: `handle_stream_event/2` would have to run twice (once in the
task for streaming UI effects, once in the agent for state). Double
the callback invocations, double the places for user bugs, and a
contract change.

## Decision

**Option A** -- defer during `:processing`, drain synchronously
before `:idle`.

The "instant notify" expectation is documentation, not a contract
anyone was actually relying on. Deferral is the simplest fix that
preserves both ordering and all state mutations. The cost is one
extra queue field on Data and a small drain loop in `finish_turn`
and `finish_error`.

## Load-bearing consequences

- `drain_pending_events/1` runs BEFORE the `:idle` transition, so
  by the time the next `process_next` fires, all buffered events
  have had their callbacks run and their state mutations written.
- Events that return `{:prompt, text, state}` during drain enqueue
  the prompt to the mailbox (not the self_chain slot) so they
  dispatch AFTER the currently-draining event set finishes.
- Events that return `{:halt, state}` set `halted: true` but drain
  CONTINUES -- subsequent events still get their callbacks called
  so their state mutations aren't lost. This matters for audit/log
  style callbacks that shouldn't be silenced by an unrelated halt.
- `safely_handle_event/3` wraps user callback in try/rescue so a
  buggy `handle_event/2` doesn't crash the drain loop and lose
  subsequent events.

## Related

- Regression tests in `test/gen_agent/server_test.exs` under
  "notify deferral during :processing" (6 cases covering each
  return-shape path and the drain-on-error case).
- The `post_turn` hook added in design 005 runs AFTER the decision
  callback and BEFORE `drain_pending_events`, so a commit hook sees
  the turn's own state, not the state after buffered notifies are
  drained. This ordering is deliberate.
