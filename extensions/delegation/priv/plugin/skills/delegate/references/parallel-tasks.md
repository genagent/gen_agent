# Parallel tasks

Choose independent assignments with explicit ownership before spawning. Use
separate worktrees for simultaneous edits to one repository, or genuinely disjoint
files when the working state can safely be shared. A shared path is not isolation.
Do not assign work already owned by another agent or session.

The manager decides the split, provider and concurrency, ordering, and what is
accepted. Scale to the independence the work actually has, not to a target count;
work that depends on another result is sequenced, not parallelized. Workers stay
inside their brief: they do not reassign scope, spawn or admit children without
caller authorization, or raise permissions or capacity.

Parallel suits independent research, disjoint-file or separate-worktree edits, and
reviews of a fixed revision. Keep sequential what depends on a prior result: design
before implementation, overlapping writes, and review of a patch not yet written.

Each brief should include goal, allowed files, prohibited edits, required checks,
and that the worker returns outcome, changed files, evidence, and limitations.
Start within the server's configured concurrency limit (three by default).
Read the `capacity` error message: a worker
limit refusal means wait for active work, not spawn another server to bypass it.
Full task history requires operator action while stopped; waiting will not free
retained history. Profile capacity and waiting-caller limits are separate causes.
Both spawning and continuation consume an active worker slot.

The operator can configure a fresh local host with `GEN_AGENT_MAX_RUNNING`
(1–32, default 3). `check_environment` reports the effective limit. A larger
batch needs explicit capacity and task-budget authorization; profiles and worker
instructions cannot raise it. The manager refuses excess work rather than queuing
it. Multiple controllers or Ensemble children must share an admission authority
to enforce one overall limit; a per-manager cap is not a machine-wide cap.

Wait on up to 32 IDs. `wait_tasks` returns when any selected task is terminal or
its timeout expires (default 30 seconds, maximum 55 seconds). Inspect both `tasks`
and per-ID `errors`; remove settled IDs before the next wait. Do independent work
between waits rather than polling rapidly.

Collection pattern (pseudocode, with the host's GenAgent Delegate tools):

```text
pending = all admitted task IDs
while pending is not empty:
    snapshot = wait_tasks(task_ids=pending, timeout_ms=55000)
    inspect per-ID errors and each returned lifecycle/domain outcome
    remove completed/failed/cancelled/interrupted IDs from pending
    retain outcomes; verify source changes and acceptance separately
```

This waits for any selected task, not for the slowest member of the batch. A
timeout keeps those IDs pending; it does not justify replacement spawns. Stop
the loop on an unresolved per-ID error rather than silently dropping work.

`list_tasks` is newest-first and compact by default. Use `since` as an inclusive
Unix timestamp in milliseconds and `limit` for discovery; use `wait_tasks` or
`full_result: true` when the output is actually needed. Do not confuse a compact
listing's omitted result with a worker that produced no result.

Validate diffs and run acceptance commands before integration. Keep exact briefs,
backend/model/effort choices, failures, and verification outcomes in the caller's
work record. Stop redundant work explicitly and record unresolved cleanup evidence.
