# Member names and migration

Ensemble members register under `{GenAgentEnsemble, session, bare_member}`.
This replaces handwritten `"session/member"` strings in the next Ensemble
release. Use the public constructor for core calls and Registry lookups:

```elixir
key = GenAgentEnsemble.member_name("research/2026", "reviewer/1")
pid = GenAgent.whereis(key)
%{name: ^key} = GenAgent.status(key)
{:ok, response} = GenAgent.ask(key, "Review this")

{:ok, status} = GenAgentEnsemble.status("research/2026")
^key = status.member_names["reviewer/1"]
```

Replace old interpolated keys in completion and stream message patterns and
telemetry filters too. There is no legacy alias or string mode. Ordinary
standalone string names remain valid and may coexist with Ensemble members;
do not mechanically rewrite their names.

Session terms retain exact identity. Atoms, strings, integers, floats,
charlists, tuples and maps remain distinct, including `1` and `1.0`. Member
names are binaries, including empty and non-UTF-8 binaries. Slashes, percent
sequences and Unicode forms are not escaped, decoded or normalized. The helper
rejects nonbinary members with a fixed `ArgumentError`; start specifications
retain `{:invalid_start_spec, :name}`. References and PIDs used as sessions
identify exact runtime terms, not durable identities across restarts.

Strategies, `status.agents` and Ensemble stream envelopes still use bare
member names. The authoritative `status.member_names` map cannot be replaced
by strategy status fields. It describes tracked slots at a point in time,
including a dead child whose DOWN has not been processed, and is empty after
logical halt. It is not a liveness certificate. Core telemetry, messages and
listings expose the tuple. Join core telemetry's `agent` to Ensemble dispatch
telemetry's `member_name`, and turns by `ref`; existing bare `agent`, `session`
and token fields keep their meanings. External exporters and JSON consumers
must handle these terms explicitly.

The tuple family is reserved by convention, not access control. Starting an
unowned slot whose exact key is occupied returns `{:member_name_conflict, bare}`
without the foreign PID or options. A tracked slot returns
`{:duplicate_sub_agent, bare}`, even after its child dies but before DOWN is
handled. Invalid-spec validation and child-spec construction take precedence.
Initial failure cleans up owned siblings and the owned tree; dynamic failure
uses existing start-rejection callbacks or logged-failure handling.

Dispatch and forward require a tracked slot whose key resolves to its owned
PID. A failed guard returns `{:agent_not_running, bare}` through the existing
operation-failure path. Scoped dispatch closes its token through rejection
callbacks or fallback. Failed dispatch guards emit one rejected event and no
start event. Stop targets the tracked PID through the owned supervisor; it
does not look up a replacement by name. An unexpected stop failure preserves
ownership until termination or absence is confirmed. A redundant stop after
retirement follows the same failure path and can emit an `agent_not_running`
warning during cleanup. Private crash/status diagnostics redact the ownership
map now that it contains PIDs; use public status for tracked bare names and keys.

After successful validation, dispatch and forward use that captured PID directly
through `GenAgent.Client`; neither operation resolves the name again or retries
against a replacement. Forward reports bounded `:not_alive` through the existing
operation-failure path when the captured PID is dead at notification's liveness
check. A later death can still drop the event: forwarding is best effort, not
confirmation of delivery or admission, and never waits for the member callback.
Helper keys and status mappings continue to address current registrations.
Cancellation retains exact-request-ref semantics and captured-PID controls,
without a global interruption or external-provider settlement guarantee.
