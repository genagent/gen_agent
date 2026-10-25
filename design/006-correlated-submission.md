# Design Note 006: Correlated Local PID Submission

Status: Implemented in source, unreleased. This is the first additive core
prerequisite for #221. Ensemble adoption and the broader #490 ownership
changes remain proposed consumer work, outside this change.

## Boundary

`GenAgent.Client.submit_with_completion(pid, prompt, recipient \\ self(), opts \\ [])`
validates a local PID, binary prompt, PID recipient, `on_halt: :queue | :fail`
and `stream_to: nil | pid`, creates a fresh ref, sends one private cast and
returns `{:submitted, ref}`. It does not look up a name, check liveness,
retry, or accept a supplied ref. Existing `GenAgent` functions still treat
all targets, including PID and tuple terms, as Registry names.

Submitted means sent, not accepted. The ref exists before the child runs
`pre_turn`; submission does not wait for that callback. Scheduling can let
the child enter or finish its callback before the function returns.

`poll(pid, ref, timeout \\ 5_000)`, `cancel_request/3` and
`interrupt_request/3` call the existing requests on exactly that PID,
propagating native timeout/death exits. They cannot respond during a
blocked callback. The separate namespace avoids changing existing named
lookup, timeout and death semantics, or retargeting a new process.

## Shared admission

The named completion call mints its ref in the server, uses
`admit_completion/6` and prepends its existing reply action. The cast passes
its client-created ref to the same helper and sends
`{:gen_agent, :admission, data.name, ref, outcome}` after computing the
transition, before returning it. No synthetic `gen_statem` caller or extra
idle mailbox hop is needed. Existing followup actions, state timeouts,
telemetry and tell-kind lifecycle handling remain in place.

Already halted plus `on_halt: :fail` rejects with `:halted`; ordinary halted
work queues until resume. Queued admission uses existing count, serialized
prompt-byte, FIFO and overload rules. Idle nonhalted work dispatches
directly even when pending budgets are zero. Immediate gate or dispatch
failure is accepted work with its existing terminal error.

For one recipient, protocol ordering is:

| Path | Child messages |
| --- | --- |
| Normal idle or queued admission | admission `:ok`, optional later events, completion |
| Immediate idle gate/dispatch rejection | completion error, admission `:ok` |
| Admission rejection | admission error only |
| Death before the admission send | Only messages already sent, then monitored `:DOWN` |

A pre-turn halt can run `post_run` between completion and admission; death
there can leave completion without acknowledgement. No buffer manufactures
acknowledgement-first ordering. Events, retries, result cache and
cancellation keep the same ref. Retries send one final completion and no
additional admission. Same-recipient events precede completion; different
recipients have no shared ordering. Stream delivery remains best effort
without backpressure and retains existing stale-task filtering.

## Death, cancellation and bounds

Monitor the captured PID before sending, ideally once per owned child.
Consume child messages and `:DOWN` in mailbox order. Completion proves
acceptance and remains terminal even if a later admission or death arrives.
Admission `:ok` then death leaves the terminal outcome uncertain; death
alone leaves acceptance uncertain. A dead PID still returns submitted.
Stop invents no completion, and a monitor does not prove provider settlement.
Before the cast is processed, an observation from another process can see
`:not_found`; that is not proof of rejection or cancellation.

There is no new submission map, relay, timer, monitor or historical ref set.
Rejection retains nothing. Accepted work uses existing current, queued,
retry, stream-recipient and bounded result-cache ownership. Cache eviction
is independent of completion delivery. Configured pending limits do not
bound casts already waiting in the BEAM mailbox.

Callers must bound unresolved physical submissions. Keep each permit until
rejection, terminal completion, confirmed cancellation or `:DOWN`; logical
user timeout or abandonment cannot silently release it for repeated
replacement work. Cancel a queued ref, and if it is current, interrupt that
exact ref. A callback can dispatch before cancellation is processed. A
native control timeout is uncertainty, not cancellation or permission to
resubmit. Finite-time confirmed cleanup of a permanently held callback
requires owner termination or a broader future protocol.

## Future consumers and release

A future Ensemble consumer must register each returned ref with its captured
PID/context, accept early completion, fence late user results, and run
blocking controls outside its responsive coordinator. It should retain
bounded cleanup obligations and permits, remove monitors/timers when done,
and ignore retired refs without permanent tombstones. No Ensemble operation
pump, forward/notify change or ownership rewrite is implemented here.

Release metadata and dependencies are unchanged. Before a consumer adopts
this API it must require the actual published core release containing it
and test that exact minimum from Hex, in addition to local path tests.
An archive or local checkout does not establish a published dependency floor.
