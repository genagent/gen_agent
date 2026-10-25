# Follow-up and cancellation

Continue the conversation's newest task only if it completed successfully, specifying
its task ID and the next bounded `message` for an ordinary task, or explicit JSON
`input` for a profile task. These modes cannot be mixed. A follow-up returns a new
task ID while preserving the conversation and original backend/model/effort/access/schema.
Do not continue an earlier task after the conversation has advanced.
If a follow-up fails, is cancelled or is interrupted, neither that task nor its
older successful parent can continue. There is no implicit rollback or replay.
Inspect retained evidence and start a new bounded task with relevant context when
appropriate; do not assume the failed request had no effects.

A profile continuation retains the captured behavior, input/output schemas, and
revision even if the catalog name was replaced or deleted, including after a
server restart. Read task `profile` metadata for its pinned name/revision; fetching
that name from the catalog may return a newer definition or no definition at all.

`wait_tasks` timeouts only stop waiting. Task deadlines are set independently by
`timeout_secs` when spawning (1–3600 seconds, default 600). Inspect task status and
structured error information to distinguish timeout, provider failure, and user
cancellation. Do not blindly retry a task that may already have changed files.

`cancel_task` targets a particular GenAgent request. Inspect `cancellation_scope`
and `provider_settled`; request cancellation does not establish that every provider
descendant stopped. A completed task can win a race against cancellation, so read
the returned outcome instead of assuming cancellation succeeded.

Results can be read repeatedly. Check `result_truncated` before treating prose as
complete. Structured results are validated separately and must never be recovered
by parsing a truncated display string. Read per-ID errors as well as task snapshots.

Use `check_environment` to record the actual state directory. An explicit
`GEN_AGENT_STATE_DIR`, or a host-supplied session identity, preserves that namespace
on reconnect. Hosts without identity get a fresh directory on each launch; an
empty task list there does not mean earlier tasks disappeared. To recover them,
reconnect with their recorded directory after its previous owner exits. Never
remove a live owner lock or assume another chat shares your tasks/profiles.
After reconnecting to the same directory, use `list_tasks` before creating replacement work.
Default rows are summaries: IDs, status, timestamps, backend/model, profile
name/revision, a short redacted `error`, and `error_info` with only `kind` and
`retryable?`. For output, usage, provider metadata, selection or the native
`provider_session_id`, use `wait_tasks` or `list_tasks(full_result=true)`.
An interrupted record describes owner loss, not certified process settlement.
The task-state directory permits one live server owner; use distinct directories
for separate hosts, and do not assume live cross-server continuation or cancellation.
Inspect the record's evidence and working tree before deciding what should resume.
