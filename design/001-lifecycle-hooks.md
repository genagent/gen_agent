# Design Note 001: Lifecycle Hooks

Status: draft
Target: gen_agent v0.2
Author: jr + claude

## Problem

Users building real agents on top of gen_agent need to run setup and
teardown logic at specific points in an agent's life, in a way that is
decoupled from the core `handle_response` / `handle_error` decision
logic. Current workarounds either (a) stuff everything into
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
5. **Rate limiting**: before each turn, sleep if a budget was exceeded.

Observation (4) is already served by telemetry events. (1)(2)(3)(5) are
not.

## Principle: telemetry first, callbacks for state mutation

Before adding any new callback, enrich the existing telemetry events
with enough metadata to cover observational use cases. Concretely:

- `[:gen_agent, :prompt, :start]` -- add `agent_state`, `prompt`.
- `[:gen_agent, :prompt, :stop]` -- add `agent_state` (post-decision),
  `outcome` (`:ok | :error`).
- `[:gen_agent, :halted]` -- add `agent_state`, `reason`.

If a use case is pure observation (log tokens, send a Slack summary,
emit a metric), it should go into a telemetry handler, not a callback.
No new behaviour required.

New callbacks are justified only when the hook needs to:

1. Mutate `agent_state` with ordering guarantees, OR
2. Short-circuit the turn (`pre_turn` `:skip` / `:halt`), OR
3. Block the next transition until an async operation completes.

Telemetry handlers run outside the agent process -- they cannot do any
of the above.

This framing sharpens the proposal below: the hooks exist specifically
for state-mutating side effects that must fire in the agent's own
message loop. Everything else is telemetry.

## Existing callbacks

| Callback             | When                             | Required | Notes                         |
|----------------------|----------------------------------|----------|-------------------------------|
| `init_agent/1`       | agent start, synchronous         | yes      | returns backend opts + state  |
| `handle_response/3`  | after each successful turn       | yes      | core decision logic           |
| `handle_error/3`     | after each failed turn           | no       | core decision logic           |
| `handle_event/2`     | on `notify/2`                    | no       | async inbox                   |
| `handle_stream_event/2` | mid-turn stream event         | no       | runs in task, not agent proc  |
| `terminate_agent/2`  | process dying (any reason)       | no       | fires on crash AND clean exit |

Gaps:

- No "after init, before first turn" hook for slow async setup that
  shouldn't block `start_agent`.
- No "before each turn" hook for gating/rate-limiting.
- No "after each turn, regardless of handle_response decision" hook for
  side effects like commit-per-turn.
- No "clean completion only" hook. `terminate_agent` fires on crashes
  too, so it's the wrong home for "create a PR."

## Proposal: four new optional callbacks

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

`{:error, reason}` halts the agent before the first turn runs, and the
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
returns to `:idle`) or `:halt` (terminal).

Use cases: rate limiting (sleep + return `{:ok, prompt, state}`), prompt
augmentation (append context), gating (check a budget, `:halt` if
exceeded).

### `post_turn/3`

```elixir
@callback post_turn(
            outcome :: {:ok, Response.t()} | {:error, reason :: term()},
            request_ref :: reference(),
            agent_state()
          ) :: {:ok, agent_state()}
```

Runs after each turn, regardless of success/failure, and regardless of
what `handle_response` / `handle_error` returned. Fires AFTER the
decision callback so the hook sees the post-decision state.

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

Runs when the agent reaches a terminal state cleanly. Specifically:
any callback (`handle_response`, `handle_error`, `handle_event`,
`pre_turn`, `post_turn`) returns `{:halt, state}`.

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

`terminate_agent/2` is still the death hook and fires at the very end
regardless of path.

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

Server wraps each hook in try/rescue/catch. Per-hook behavior:

| Hook        | On raise                                                                 |
|-------------|--------------------------------------------------------------------------|
| `pre_run`   | halt agent; `terminate_agent` called with `{:pre_run_crashed, exception}` |
| `pre_turn`  | skip the turn, log warning, back to `:idle`                              |
| `post_turn` | log warning, continue with the transition the decision callback chose   |
| `post_run`  | log warning, terminate normally                                          |

Rationale: `pre_run` is the only hook whose failure breaks a core
invariant (no workspace = no sensible agent). `pre_turn` failing
should be recoverable (fix the rate limiter, next prompt works).
`post_turn` / `post_run` are side effects; their failure must not
unwind a successful turn or keep a dead agent alive.

Users who want strict "crash on any hook failure" can re-raise
explicitly from inside the hook.

## Telemetry first, callbacks for state mutation

Restated from the principle section above, applied to each hook:

| Use case                           | Solution                             |
|------------------------------------|--------------------------------------|
| Log token usage per turn           | telemetry `[:prompt, :stop]` handler |
| Metrics / distributed tracing      | telemetry handlers                   |
| Commit per turn (state-mutating)   | `post_turn` callback                 |
| Create PR on halt (state-reading)  | enriched `[:halted]` telemetry OR `post_run` |
| Rate limit (gates next turn)       | `pre_turn` callback                  |
| Prompt augmentation                | `pre_turn` callback                  |
| Clone repo on startup              | `pre_run` callback                   |
| Cleanup on death (any reason)      | `terminate_agent` (already exists)   |

Note the two options for "create PR on halt": the enriched
`[:halted]` telemetry event now includes `agent_state`, so a
telemetry handler can do it without a callback. `post_run` remains
preferable when the side effect has error paths that should surface
through the agent's own logging / supervision, or when it needs to
update state before `terminate_agent/2` runs.

## Backwards compatibility

All four callbacks are optional. Default implementations from
`use GenAgent`:

```elixir
def pre_run(state), do: {:ok, state}
def pre_turn(prompt, state), do: {:ok, prompt, state}
def post_turn(_outcome, _ref, state), do: {:ok, state}
def post_run(_state), do: :ok
```

No existing agent breaks. No existing callback shape changes. Server
state adds nothing visible; internally adds `pre_run_done: boolean` to
`Data` and a new `{next_event, :internal, :pre_run}` at init time.

## Implementation sketch

1. Add four callbacks to `lib/gen_agent.ex` behaviour + default impls
   in `__using__`.
2. Add `pre_run_done: false` to `server.ex` `Data` struct.
3. In `init/1`, post `{:next_event, :internal, :pre_run}` before the
   first state transition.
4. New `handle_event(:internal, :pre_run, :idle, data)` clause.
5. In `handle_event(:internal, :process_next, :idle, ...)`, call
   `pre_turn` before dispatching to the backend task. Honor `:skip`
   and `:halt` returns.
6. In `finish_turn/5` and `finish_error/3`, call `post_turn` between
   `handle_response`/`handle_error` and the idle transition.
7. When transitioning to halted (via `{:halt, state}` from any
   callback), call `post_run` before emitting `[:gen_agent, :halted]`.
8. Wrap all four in `safely_*` helpers matching the existing
   `safely_handle_event` pattern.
9. Scenario tests (see playground NOTES.md) for each hook firing in
   the expected order across normal, error, interrupt, and crash
   paths.

## Non-goals

- NOT adding middleware / plug-chain semantics. One hook per point.
  Users who need composition can compose in their own callback.
- NOT adding per-hook start_option overrides. The callback module is
  the home. If users need environment-specific hooks, they branch
  inside the hook.
- NOT changing telemetry. Existing events stay; the hooks are
  complementary, not a replacement.
