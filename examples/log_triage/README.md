# Log triage

A running OTP node forwards its own error and crash reports to one long-lived
GenAgent. A local, deterministic backend writes short incident notes without
credentials, network access, or a model installation. It is a batching example,
not an AI diagnosis service.

From this directory, with dependencies already fetched:

```sh
mix run -e "LogTriage.Demo.run()"
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

In a sandbox that cannot use Mix's concurrency lock, prefix commands with
`MIX_OS_CONCURRENCY_LOCK=0`. This is a shell setting, not project configuration.
The demo deliberately prints crash logs, followed by incident notes and a drop
count. It crashes nine disposable GenServers using raise, match failure, and
explicit exit. Its final display uses a brief delay to allow asynchronous work;
tests use explicit gates and message barriers, never sleeps.

## Flow and modules

1. `LogTriage.Application` starts a caller-owned `:rest_for_one` tree: the sink,
   a `Task.Supervisor`, the agent built with `GenAgent.child_spec/2`, and the
   logger handler owner. The agent is registered as `:log_triage`.
2. `LogTriage.Handler` installs an OTP `:logger` handler and removes it during
   orderly shutdown. It keeps error, critical, alert, and emergency events.
   Events containing the `:log_triage` metadata key, events with application
   `:gen_agent`, and calls originating in `GenAgent` modules are ignored to
   prevent feedback. Any logging added to this example should use
   `log_triage: true` metadata.
3. The handler selects the label and reason of structured crash reports,
   discards process state and volatile report metadata, normalizes printed PIDs
   and references, and reduces the result to a valid UTF-8 sample of at most
   120 graphemes (usually at most 480 bytes; the agent drops a sample that
   exceeds its byte guard). An MD5 digest of that sample is the fingerprint. This is an
   approximate grouping key, not a security hash: truncated reports can group
   together. GenServer and process crash reports with different labels remain
   separate groups. Raw crash terms are never sent to the agent.
4. `LogTriage.Agent.handle_event/2` filters event shapes, counts fingerprints,
   and retains the first sample of each group. The first event queues a
   `FLUSH` marker. Later events update the buffer without adding markers.
   `pre_turn/2` renders the current buffer in fingerprint order, then clears it.
5. `LogTriage.Backend` returns a deterministic incident count, suggested next
   step, and at most three sample lines. Its optional `observer` and `hold`
   options let tests wait for `{:turn_started, prompt, task}` and explicitly
   send `:release` to that task.
6. `LogTriage.Sink` records notes in memory and counts notification drops from
   `[:gen_agent, :input, :rejected]`. Its telemetry callback only sends a message,
   filters by agent identity and notification queue, and never logs. Read it
   with `LogTriage.Sink.snapshot(LogTriage.Sink)`.
7. `LogTriage.Demo` supplies the disposable crashing workers and prints notes.

## GenAgent behavior demonstrated

The logger callback calls `notify/2`, an asynchronous cast. It does a small
amount of report reduction in the logging process, but never waits for the
agent or backend. `notify/2` always returns `:ok`, even if admission later fails.
Use `notify_ack/3` when an admission result is needed. Overload returns
`{:error, {:overloaded, info}}`, with `info.queue == :notifications` and
`info.limit` equal to `:count` or `:bytes`. Both APIs emit input-rejection
telemetry when admission fails.

While a turn is processing, notifications are deferred and drained FIFO before
another turn dispatches. There is no drain-complete callback. The marker prompt
provides late binding: `pre_turn/2` sees everything accumulated during that drain.
Thus one initial report and five reports admitted during its turn produce two
turns, containing one and five reports. This batches deferred drains, not an
arbitrary wall-clock burst. Idle notifications can each start a turn. Duplicate
counts apply within a batch, not across the entire lifetime of the node.

The application sets `max_pending_notifications: 100` and
`max_pending_notification_bytes: 65_536`. Bytes are measured using
`:erlang.external_size/1` on queued payloads. Immediately handled idle events
are outside these limits. These are pending-queue limits, not a bound on the
BEAM mailbox, callback buffer, or sink history. The sink keeps notes for this
short demo's lifetime. If a generated marker is rejected by the prompt queue,
`handle_error/3` resets the marker flag and retains the buffer for a future log
event to retry.

Current core behavior differs from the original issue sketch: an empty-buffer
`pre_turn/2` skip emits `[:gen_agent, :turn, :rejected]` with
`reason_kind: :pre_turn_skipped`, but does not call `handle_error/3` for the
event-origin prompt. The registered `:name` is still stripped before
`init_agent/1`; this agent receives its sink explicitly and does not infer a name.
The keyless backend lives here because core does not ship one.

`GenAgent.child_spec/2` returns a **temporary** child. The caller's task supervisor
must already be running. `:rest_for_one` shuts down later children when an earlier
one fails, but does not resurrect the temporary agent or restore its state.
Restart the example application to establish a fresh session after such a loss.

Tests hold backend turns until explicitly released, confirm notification
admission with same-sender snapshots, and assert settled state after notes.
They cover FIFO sample retention, duplicate counts, exactly two turns, count and
byte overload results and telemetry, feedback filtering, report reduction, and
OTP handler installation and cleanup.

The root README events link and CI job are follow-up integration work outside
this example's permitted change scope.
