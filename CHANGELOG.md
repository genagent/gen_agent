# Changelog

## Unreleased

### Added

- Four optional lifecycle hook callbacks for fine-grained control over
  the agent's run (see `design/001-lifecycle-hooks.md`):
  - `c:GenAgent.pre_run/1` -- one-time setup after `init_agent`, before
    the first turn. Where slow async setup goes (clone a repo, create
    a worktree, fetch secrets). Does not block `start_agent/2`.
  - `c:GenAgent.pre_turn/2` -- per-turn pre-dispatch hook. Can observe,
    mutate state, rewrite the prompt, skip the turn (`:skip`), or halt
    the agent (`:halt`). Home for prompt templating and rate limiting.
  - `c:GenAgent.post_turn/3` -- per-turn post-dispatch hook. Fires after
    the decision callback (`handle_response` or `handle_error`) with
    post-decision state. For state-mutating side effects like
    commit-per-turn or usage persistence.
  - `c:GenAgent.post_run/1` -- clean-completion hook. Fires when any
    callback returns `{:halt, state}`. For completion side effects like
    opening a PR or posting a summary. Does NOT fire on crashes, stop,
    or supervisor shutdown (`c:GenAgent.terminate_agent/2` still owns
    those).
- Telemetry metadata enrichment:
  - `[:gen_agent, :prompt, :start]` now carries `prompt`,
    `original_prompt`, `rewritten`, and `agent_state`. When `pre_turn`
    rewrites the prompt, both versions appear in telemetry so the
    transformation is traceable.
  - `[:gen_agent, :prompt, :stop]` now carries `agent_state`.
  - `[:gen_agent, :prompt, :error]` now carries `agent_state`.
  - `[:gen_agent, :halted]` now carries `agent_state`.

### Notes

- All four new callbacks are optional and have default no-op
  implementations via `use GenAgent`. Existing agents keep working
  unchanged.
- Hook crash semantics are documented in each callback's @doc and in
  `design/001-lifecycle-hooks.md`. Summary:
  - `pre_run` crash -> agent stops with `{:pre_run_crashed, exception}`,
    `terminate_agent/2` runs.
  - `pre_turn` crash -> turn is skipped, warning logged, back to `:idle`.
  - `post_turn` crash -> warning logged, transition proceeds.
  - `post_run` crash -> warning logged, halt completes normally.
- `pre_turn` `:skip` and `:halt` deliver `{:error, :pre_turn_skipped}`
  and `{:error, :pre_turn_halted}` respectively to the calling `ask/2`
  or via `poll/2` for `tell/2`.

## 0.1.0 (2026-04-10)

- Initial release.
- GenAgent behaviour and supervision framework for long-running LLM
  agent processes modeled as OTP state machines.
- Fix: defer notify events that arrive during `:processing` so
  `handle_event/2` state mutations are not overwritten by the
  in-flight task's result (PR #1).
