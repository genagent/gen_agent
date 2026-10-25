---
name: delegate
description: Delegate a bounded local task, independent review, or follow-up to Claude or Codex through GenAgent Delegate. Use when a separate worker helps complete the authorized task.
---

# Delegate a bounded task

Use the installed MCP tools for this host. Discover deferred tools if needed;
if the connection is unavailable, diagnose it rather than inventing another
stdio bridge. This skill grants no permission beyond the user's authorized work.
When Tosi or another delegate plugin is also loaded, select the tools explicitly
namespaced to GenAgent Delegate. Their similarly named tools do not share catalogs.

Give `spawn_task` an absolute existing `cwd` and a self-contained brief: the
outcome, relevant files/context, constraints, applicable repository instructions,
and acceptance checks. A worker does not inherit this conversation or its tools.
Keep the returned task ID, then use `wait_tasks` to retrieve the outcome. A wait
timeout is a snapshot, not a failed or cancelled task. Remove completed IDs before
waiting for remaining work, because waits return when any selected task is terminal.

Honor explicit backend/model/effort choices. Omit `backend` to use the server's
configured default (normally Claude). Omitted model and effort use CLI behavior,
not the parent chat's settings. Do not invent provider routing rules or assume a
requested model is the reported model. Read the model/effort reference when needed.

Default to `read_only`. Request `workspace_write` only for authorized edits.
Claude gets a restricted read/edit tool list with no shell; Codex uses its native
sandbox. Use separate worktrees or disjoint file ownership for parallel writers.
Verify source changes and mechanical acceptance checks outside worker claims.
`completed` is a lifecycle status, not proof the assignment succeeded. Check the
domain outcome and limitations too: `needs_information`, `blocked`, or `partial`
requires follow-up even when the response validates. Verify findings, locations,
and reported test execution against source and independent checks.

Manager and worker roles: the calling session (the manager) owns decomposition,
assignments, provider/model/effort, permissions, dependencies, acceptance, and
cleanup. Subagents help with scoped independent tasks or focused review; the number
of workers is not a goal. Give each an exact deliverable and boundary, isolate
writers, and state source access accurately for the provider (Claude: Read/Glob/Grep
and, in write mode, Edit/Write, no shell; Codex: its native sandbox). A worker does
not reassign its work or admit child tasks without the caller's authorization, and
no worker can raise enforced permissions or capacity; access never widens through
delegation, and continuations stay pinned to the original settings.
Ask each worker to report the sources it actually used, checks it actually ran,
and unknowns, plus outcome and changed files. A report is not acceptance: the
manager runs the checks, records the exact revision, and verifies before
integrating. Terminal state and valid JSON are not domain success.

This guidance is behavioral. It is not proof of sandboxing, a child cost cap, or
enforced global ownership.

For structured output on an ordinary task, provide `output_schema` as a
self-contained object schema.
Prefer simple closed objects with all properties required for both CLIs. The
server applies provider-native formatting and local validation; inspect
`structured_result` separately from prose `result`. Schema support and bounds are
server-enforced; a valid JSON object is not evidence that its assertions are true.
Follow-ups inherit the original schema and execution settings.

Use a named profile when reusable behavior and input/output contracts help.
`list_profiles` discovers names including the seeded `researcher`,
`elixir-developer`, and `reviewer`; `get_profile` shows the actual definition.
Supply `profile` and explicit JSON `input` instead of `task`. Profiles select no
execution settings or permissions. Register caller-supplied text with
`register_profile`; replacement requires `replace: true`. `delete_profile` only
affects future lookups. Existing tasks retain their original profile revision.
Read the profiles reference before creating or changing a profile.

Call `check_environment` for an optional backend before diagnosing a launch or
authentication failure. It makes no model request and returns no credential values.
Its `server` object identifies the running version, runtime module and launch path,
actual state directory, default backend, and configured limits. A null launch path
means it was not launched through the packaged entrypoint; it is not a failed probe.
Unknown auth status can reflect the process environment or credential-store access;
do not claim the user is logged out merely because the probe failed. Do not read,
export, or replace credentials, or bypass inherited sandbox restrictions.

Use `continue_task` only for the conversation's newest task, which must have
completed successfully; it returns a new task ID
in the same conversation. Supply `message` for an ordinary task or explicit
`input` for a profile task. Use `cancel_task` when a task is no longer wanted, then
inspect cancellation and cleanup evidence. Task cancellation is not certification
that all external processes have exited. After a restart, list retained tasks
before replacing interrupted work. A state directory has one live server owner.

Read only the reference relevant to the current assignment. MCP clients can fetch
the identical canonical text with `resources/read`:

- [Parallel tasks](references/parallel-tasks.md): ownership, capacity, collection.
  `skill://gen-agent-delegate/delegate/references/parallel-tasks.md`
- [Implementation and review](references/implementation-review.md): scoped edits,
  verification, and independent review.
  `skill://gen-agent-delegate/delegate/references/implementation-review.md`
- [Follow-up and cancellation](references/follow-up.md): continuity and lifecycle.
  `skill://gen-agent-delegate/delegate/references/follow-up.md`
- [Model and effort](references/model-effort.md): explicit choices and provenance.
  `skill://gen-agent-delegate/delegate/references/model-effort.md`
- [Named profiles](references/profiles.md): behavior/schema definitions, typed
  input, immutable revisions, and registry changes.
  `skill://gen-agent-delegate/delegate/references/profiles.md`

General resource: `skill://gen-agent-delegate/delegate/SKILL.md`. Exposing resources
does not automatically load them into a client's model context.
