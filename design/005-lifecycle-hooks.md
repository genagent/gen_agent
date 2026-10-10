# Design Note 005: Lifecycle Hooks

Status: Implemented (PR #2)
Original target: gen_agent v0.2

The motivation and resolved questions record the original proposal.
The callback contracts and failure behavior below describe the current
implementation in [GenAgent](../lib/gen_agent.ex) and
[GenAgent.Server](../lib/gen_agent/server.ex).

## Problem

Users building real agents on top of gen_agent need to run setup and
teardown logic at specific points in an agent's life, in a way that is
decoupled from the core `handle_response` / `handle_error` decision
logic. Before these hooks, workarounds either (a) stuff everything into
`init_agent` / `terminate_agent`, or (b) copy the same side-effect code
into every `handle_response` clause.

## Motivating use cases

From a Centralino-style app (agents that drive real work in real repos):

1. **Workspace isolation**: before the first turn, clone the repo or
   create a git worktree. After the final turn, remove the worktree.
2. **Per-turn commit/tag**: after each successful turn, `git commit
   -am "turn N"` and tag so the manager can diff or roll back.
3. **Create PR on completion**: when the agent halts cleanly, open a PR
   from its branch. Do NOT open a PR if the agent crashed or was
   interrupted.
4. **Observability**: log every turn's token usage and duration to an
   external system, without polluting `handle_response`.
5. **Rate limiting**: delay a turn until a budget becomes available.

Observation (4) is now served by telemetry events plus `post_turn/3` for
token usage (see below). The other cases motivated lifecycle hooks.

## Principle: telemetry first, callbacks for state mutation

Before adding any new callback, use existing telemetry events for
observational use cases. The original proposal was to enrich them
(`agent_state` on `:prompt, :start`; post-decision `agent_state` and
`outcome` on `:prompt, :stop`; `reason` on `:halted`). That proposal
was only partly adopted. Current behavior (see [GenAgent.Telemetry](../lib/gen_agent/telemetry.ex)
and `emit_prompt_start/6`, `emit_prompt_stop/5`, `emit_halted/2` in
[GenAgent.Server](../lib/gen_agent/server.ex)):

- `[:gen_agent, :prompt, :start]` -- metadata has `agent`, `ref`,
  `attempt`, `prompt`, `original_prompt`, `rewritten`, `agent_state`.
- `[:gen_agent, :prompt, :stop]` -- measurement `duration` is the
  core-measured prompt-task elapsed time in **milliseconds**; metadata is `agent`,
  `ref`, `attempt`, `agent_state`. It fires when the backend task
  returns, **before** `handle_response/3` and `post_turn/3`, so
  `agent_state` is the pre-decision state (it does not include changes
  made by this turn's `handle_response/3`, but includes returned
  task-local stream state). See `handle_task_result/3` in
  [GenAgent.Server](../lib/gen_agent/server.ex). There is no `outcome` key
  (success and failure are the separate `:stop` and `:error` events),
  no `usage`, no `session_id`, and no response.
- `[:gen_agent, :halted]` -- metadata is `agent` and `agent_state`
  (the state at the halt transition, after the decision). There is no
  `reason`; per Q4 there is a single halt cause.

Duration units differ: `:prompt, :stop` and `:prompt, :error`
`duration` are milliseconds, `:turn, :stop`/`:error` use `duration_ms`
(milliseconds), and `system_time` measurements are in native units.
Do not pass these through `System.convert_time_unit/3` as native time.

Normalized token usage lives on `GenAgent.Response.usage`. Read it in
`handle_response/3` or `post_turn/3`, not from prompt-stop telemetry.

If a use case is pure observation that needs only the metadata above
(send a Slack summary on halt, emit a duration metric), use a telemetry
handler. Anything needing the response or usage belongs in
`post_turn/3`.

New callbacks are justified only when the hook needs to:

1. Mutate `agent_state` with ordering guarantees, OR
2. Short-circuit the turn (`pre_turn` `:skip` / `:halt`), OR
3. Block the next transition until an async operation completes.

Telemetry handlers run synchronously in the process that emits the
event (usually the agent process), so a slow handler delays the agent,
and they cannot do any of the above in a controlled way. Offload
expensive handler work (e.g. send to a separate process or task
supervisor); that is best effort and gives no delivery guarantee, since
the receiving process may be down or overloaded and a crashing handler
is detached by `:telemetry`.

This framing sharpens the proposal below: the hooks exist specifically
for state-mutating side effects that must fire in the agent's own
message loop. Everything else is telemetry.

## Callbacks before the proposal

| Callback             | When                             | Required | Notes                         |
|----------------------|----------------------------------|----------|-------------------------------|
| `init_agent/1`       | agent start, synchronous         | yes      | returns backend opts + state  |
| `handle_response/3`  | after each successful turn       | yes      | core decision logic           |
| `handle_error/3`     | after each failed turn           | no       | core decision logic           |
| `handle_event/2`     | on `notify/2`                    | no       | async inbox                   |
| `handle_stream_event/2` | mid-turn stream event         | no       | runs in task, not agent proc  |
| `terminate_agent/2`  | process dying (any reason)       | no       | fires on crash AND clean exit |

Gaps at the time of the proposal:

- No "after init, before first turn" hook for slow setup that
  shouldn't block `start_agent`.
- No "before each turn" hook for gating/rate-limiting.
- No "after each turn, regardless of handle_response decision" hook for
  side effects like commit-per-turn.
- No "clean completion only" hook. `terminate_agent` fires on crashes
  too, so it's the wrong home for "create a PR."

## Implemented callbacks (originally proposed as four optional hooks)

All optional. All have default no-op implementations from `use GenAgent`.

### `pre_run/1`

```elixir
@callback pre_run(agent_state()) :: {:ok, agent_state()} | {:error, reason :: term()}
```

Runs once, after `init_agent/1` succeeds and the server has fully
started, before the first turn is dispatched. This is where long-running
setup goes: clone a repo, spin up a sandbox, fetch secrets.

Invoked from inside the server process, so it blocks the first turn
until it returns, but does NOT block `start_agent/2` from returning to
the caller. Implemented via `:gen_statem` `{next_event, :internal,
:pre_run}` posted at init time.

`{:error, reason}` stops the agent before the first turn runs, and the
reason is delivered through `terminate_agent/2` as
`{:pre_run_failed, reason}`.

### `pre_turn/2`

```elixir
@callback pre_turn(prompt :: String.t(), agent_state()) ::
            {:ok, prompt :: String.t(), agent_state()}
            | {:skip, agent_state()}
            | {:halt, agent_state()}
```

Runs before each prompt dispatch, inside the server process. Can
observe, mutate state, rewrite the prompt (for augmentation /
templating), or veto the turn entirely with `:skip` (drops the prompt,
returns to `:idle`) or `:halt` (idle with dispatch frozen; process alive).

For an ask or tell, skip, halt, invalid return, and a caught crash reject
that request with `:pre_turn_skipped`, `:pre_turn_halted`,
`:pre_turn_invalid`, and `:pre_turn_skipped`, respectively. These do not
run `handle_error/3` or `post_turn/3`, or emit prompt-start/stop events.
For a self-chain or event-generated prompt, a skip, crash, or malformed
return emits prompt-error telemetry and calls `handle_error/3`, so an
autonomous workflow can retry or halt rather than silently stopping.
Immediate generated-prompt retries are paced so other agent calls can
be handled even if the hook keeps rejecting.

Use cases: prompt augmentation (append context) and gating (check a
budget, `:halt` if exceeded).

Do not sleep in this callback to implement backoff: it blocks all
synchronous calls and can cause supervisor shutdown to skip cleanup.
Schedule a timer, return to idle, and dispatch the prompt from
`handle_event/2` when the timer fires, as in the Retry guide. The
turn watchdog does not cover time spent in this or other agent-process
callbacks.

### `post_turn/3`

```elixir
@callback post_turn(
            outcome :: {:ok, Response.t()} | {:error, reason :: term()},
            request_ref :: reference(),
            agent_state()
          ) :: {:ok, agent_state()}
```

Runs after a successful or failed turn's decision callback returns a valid
decision, including `handle_error/3` failures normalized to
`{:noreply, previous_state}`. A crash or invalid return from
`handle_response/3` stops the agent before `post_turn/3` runs. The hook
fires AFTER the decision callback so it sees the post-decision state.
See `finish_turn/5`, `finish_error/3`, `decision_to_transition/1`, and
`safely_handle_error/5` in [GenAgent.Server](../lib/gen_agent/server.ex).

Use cases: commit-per-turn, log token usage, persist a turn record.
Return value is just updated state; the hook cannot override the
decision callback's transition.

Ordering per turn:

```
dispatch -> backend -> handle_response OR handle_error -> post_turn -> transition (idle/processing/halted)
```

Note: `post_turn` runs before `drain_pending_events`, so a commit hook
sees the state as of the turn that just finished, not the state after
buffered notifies are drained.

### `post_run/1`

```elixir
@callback post_run(agent_state()) :: :ok
```

Runs when the agent transitions cleanly to halted, remaining alive. Specifically:
one of `handle_response`, `handle_error`, `handle_event`, `handle_info`,
or `pre_turn` returns `{:halt, state}`, or an external `GenAgent.halt/1`
request takes effect. `post_turn` only returns state
and cannot choose a halt transition.

The hook fires once per transition into halted state. Repeated
halt decisions while already halted do not repeat completion side
effects; `resume/1` permits a later halt to fire the hook again.

For a completed turn, `post_turn` precedes notification draining as above.
All buffered notifications are then applied in FIFO order before `post_run`
and `[:gen_agent, :halted]` observe the resulting state. If a notification
halts mid-drain (including a halt from handling its rejected generated
prompt), the remaining buffered notifications still run before completion.
Dispatch is disabled before draining; nested halt decisions cannot finalize
the same transition again. Queued tells with `on_halt: :fail` settle before
draining, releasing their capacity for notification-generated prompts that
remain queued until resume. Their failure completions precede `post_run`.
Later notifications can still update a halted
agent, but do not alter the completion snapshot or rerun these observers.

Does NOT run on crashes, `GenAgent.stop/1`, supervisor shutdown, or
abnormal exits -- `terminate_agent/2` covers those.

Use cases: create a PR, post a Slack summary, mark the task done in an
external tracker. The distinction from `terminate_agent/2` is
"completion" vs "termination."

## Interaction with existing callbacks

```
                             +-----------------+
                             |   init_agent    |
                             +--------+--------+
                                      |
                                      v
                             +-----------------+
                             |     pre_run     |  <-- new
                             +--------+--------+
                                      |
                                      v
                             +-----------------+
                             |      idle       |<---------------+
                             +--------+--------+                |
                                      | prompt dispatched       |
                                      v                         |
                             +-----------------+                |
                             |    pre_turn     |  <-- new       |
                             +--------+--------+                |
                                      |                         |
                                      v                         |
                             +-----------------+                |
                             |   processing    |                |
                             +--------+--------+                |
                                      |                         |
                       success        |        error            |
                            +---------+---------+               |
                            v                   v               |
              +-------------+---+       +-------+---------+     |
              | handle_response |       |  handle_error   |     |
              +-------------+---+       +-------+---------+     |
                            |                   |               |
                            +---------+---------+               |
                                      v                         |
                             +-----------------+                |
                             |    post_turn    |  <-- new       |
                             +--------+--------+                |
                                      |                         |
                     {:noreply}       | {:halt}                  |
                            +---------+---------+               |
                            |                   |               |
                            |                   v               |
                            |          +-----------------+      |
                            |          |    post_run     |  <-- new
                            |          +--------+--------+      |
                            |                   |               |
                            +-------------------+               |
                                      |                         |
                                      +-------------------------+
```

`terminate_agent/2` is still the death hook, called during `terminate/3`.
An untrappable kill or VM termination bypasses it (see design 003).

## Resolved (walkthrough 2026-04-10)

### Q1: `pre_run` vs `handle_continue`?

**`pre_run/1`**. Named hook is more teachable for the "slow startup"
use case than adopting GenServer's `{:continue, term}` protocol.
Alternative considered: `{:ok, opts, state, {:continue, term}}` from
`init_agent` + a `handle_continue/2` callback. More flexible
(multi-hop), but `{:continue, :clone_repo}` is less discoverable than
a named `pre_run` with a docstring that says "this is where slow
setup goes." Users who want multi-hop can chain via `handle_event`
with self-sent notifies.

### Q2: `post_turn` before or after the decision callback?

**After.** The hook sees post-decision state, which is what commit-per-turn
and usage-logging hooks actually want. Running before would force the
hook to predict what `handle_response` will decide, and require
threading the hook's return into the decision callback's input.

### Q3: Can `pre_turn` rewrite the prompt?

**Yes.** Use cases (prompt templating, context injection, rate-limiting
with no-op) justify it. The workaround otherwise is storing the
template in state and rebuilding the prompt inside every callback
that returns `{:prompt, ...}` -- duplicated and ugly.

**Traceability requirement**: `[:gen_agent, :prompt, :start]` telemetry
metadata must carry both the original and rewritten prompt, plus a
`rewritten: boolean` flag. A reader debugging a turn can see the
rewrite in telemetry without inspecting the callback module.

### Q4: `post_run` reasons?

**`post_run/1`** -- just agent_state, no reason arg. The proposal
originally took `:halted | :interrupted`, but interrupt-then-halt
routes through `handle_error` -> `{:halt, state}` -> `post_run`
(reason: `:halted`). Interrupt-without-halt goes back to `:idle`,
no `post_run`. So `:interrupted` was unreachable.

The reason arg was vestigial. Dropped. If we later grow reason
variants (e.g., `:max_turns_reached` as a server-detected clean exit),
we add the arg back then. YAGNI now.

### Q5: Hook crash semantics

Server wraps each hook in try/rescue/catch. Current behavior:

| Hook | Raise / throw / exit | Invalid return |
|------|----------------------|----------------|
| `pre_run` | error log; stops with `{:pre_run_crashed, failure_kind}` | error log; stops with `:pre_run_invalid` |
| `pre_turn` | warning log; external request gets `:pre_turn_skipped`; generated prompt calls `handle_error/3` with `{:pre_turn_crashed, failure_kind}` | warning log; rejects with `:pre_turn_invalid`; generated prompt also calls `handle_error/3` |
| `post_turn` | warning log; retains post-decision state and transition | warning log; retains post-decision state and transition |
| `post_run` | warning log; halt completes, agent stays alive | return ignored without validation or logging |

For a raised `pre_run/1` exception, `failure_kind` is the exception module
(for example, `RuntimeError`), not the exception struct. Caught throws
and exits in `pre_run/1` use `:other`. `terminate_agent/2` receives the
stop reason. See the internal `:pre_run` dispatch, `callback_failure_kind/1`,
and `safely_pre_run/3`, `safely_pre_turn/4`, `safely_post_turn/5`, and
`safely_post_run/3` in [GenAgent.Server](../lib/gen_agent/server.ex).

Rationale: setup failure prevents useful turns; pre-turn failure rejects
work; post-turn and completion side-effect failures preserve the decision.
Re-raising inside a wrapped hook is caught by the same wrapper and does
not provide a strict crash policy. Use explicit application-level error
handling and an external owner to decide whether to stop the agent.
Untrappable kills bypass these wrappers and termination cleanup.

## Telemetry first, callbacks for state mutation

Restated from the principle section above, applied to each hook:

| Use case                           | Solution                             |
|------------------------------------|--------------------------------------|
| Log token usage per turn           | `post_turn` / `handle_response` (`Response.usage`) |
| Metrics / distributed tracing      | telemetry handlers                   |
| Commit per turn (state-mutating)   | `post_turn` callback                 |
| Create PR on halt (state-reading)  | enriched `[:halted]` telemetry OR `post_run` |
| Rate limit (gates next turn)       | `pre_turn` callback                  |
| Prompt augmentation                | `pre_turn` callback                  |
| Clone repo on startup              | `pre_run` callback                   |
| Cleanup on death (any reason)      | `terminate_agent` (already exists)   |

Note the two options for "create PR on halt": the `[:halted]`
telemetry event includes `agent_state` (but no `reason`), so a
telemetry handler can do it without a callback. `post_run` remains
preferable when the side effect has error paths that should surface
through the agent's own logging. `post_run/1` cannot update agent state:
its return is ignored, and it does not terminate the process. Use
`post_turn/3` for a state update before completion.

## Backwards compatibility

All four callbacks are optional. Default implementations from
`use GenAgent`:

```elixir
def pre_run(state), do: {:ok, state}
def pre_turn(prompt, state), do: {:ok, prompt, state}
def post_turn(_outcome, _ref, state), do: {:ok, state}
def post_run(_state), do: :ok
```

The original proposal preserved existing callback shapes through these
no-op defaults. The current server schedules
`{next_event, :internal, :pre_run}` at init time; there is no
`pre_run_done` field in `Data`. See `init_impl/1` and `Data` in
[GenAgent.Server](../lib/gen_agent/server.ex).

## Original non-goals

- NOT adding middleware / plug-chain semantics. One hook per point.
  Users who need composition can compose in their own callback.
- NOT adding per-hook start_option overrides. The callback module is
  the home. If users need environment-specific hooks, they branch
  inside the hook.
- NOT changing telemetry. Existing events stay; the hooks are
  complementary, not a replacement.
