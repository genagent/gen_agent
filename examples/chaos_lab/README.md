# Chaos Lab

A keyless, local supervision contract check for OTP developers embedding
GenAgent in an application. It uses the in-repo core through the scaffold's
path dependency. No provider, credentials, network access, or `Mix.install`
is needed to run it with dependencies already fetched.

```sh
cd examples/chaos_lab
mix run scripts/chaos_lab.exs
```

The script raises on a failed assertion and finishes with exactly one
`chaos_lab: ok` line on success. Injected crashes produce expected OTP error
reports. Intermediate output includes caller results, callback messages,
process monitors, overload details, and supervisor observations. Its ordering,
pids, references, and timestamps vary. A future CI job should check the exit
status and final success line, not compare the whole output.

## Scenarios

| Scenario | Fault and asserted observation |
| --- | --- |
| A | Kill the prompt task discovered through `handle_stream_event/2`. The callback receives `{:task_crashed, :killed}`, the original request receives that error in its completion message, a self-chained retry completes, and the agent pid stays the same. |
| B | Raise while enumerating a backend stream. `ask/3` returns `{:error, {:task_crashed, _}}`, `handle_error/3` observes the crash, and the same agent serves another request. Retry is disabled for this scenario to isolate the caller result. The exception and stacktrace are intentionally not matched exactly. |
| C | Kill an agent during a held turn. Both agent and task monitors report `:killed`; no completion or termination callback arrives. After registry cleanup, `whereis/1` is nil and a new agent starts under the same name. The absence check runs after both possible producers are dead. |
| D | Use `watchdog_ms: 100` with a held turn. `ask/3` and `handle_error/3` observe `:timeout`; the same agent serves another request. |
| E | Start a `child_spec/2` in a caller-owned `DynamicSupervisor`. Duplicate start returns `{:error, {:already_started, pid}}`. `stop/2`, passed that dynamic supervisor, runs `terminate_agent/2` and `terminate_session/1` and clears the registration. |
| F | Kill the caller-owned task supervisor in a `:rest_for_one` tree. Both supervisor pids are replaced, the temporary agent exits, and the replacement dynamic supervisor has no agents. The agent is idle here to isolate tree behavior from retry dispatch. |
| G | Stop the owner tree while a turn is held. Both termination callbacks run, the prompt task dies, and `whereis/1` becomes nil. |
| H | Override the default temporary child spec with `Supervisor.child_spec(spec, restart: :permanent)`, complete a turn, then kill the agent. The same name resolves to a new pid with empty response history, a new backend session id, and zero previous backend turns. |
| I | During a held turn, buffer five notifications and two additional prompts. The sixth `notify_ack/3` and third queued `tell/3` return overload errors. Assert the queue, `limit: :count`, `pending_count`, and `max_count` fields. `runtime_snapshot/2` shows five pending notifications, two pending prompts, the running request, and no self-chain. Release the turn and verify that both queued prompts complete and the counts drain to zero. |

The backend yields two text events and a terminal result. The `"hold"` prompt
waits for an explicit release between its text events; `"crash"` raises on
its first element. Observer messages identify both the owning agent and prompt
task, so one scenario cannot consume another scenario's stream observation.
Receives and registry/tree polling have five-second deadlines. Holds have a
30-second failure bound. Only registry polling sleeps; fault injection uses
messages and monitors rather than elapsed-time guesses.

## Differences from issue #146

Scenario D uses a release gate instead of a one-second sleep. This preserves
the watchdog assertion without assuming that the script gets scheduled before
a sleeping turn finishes. Normal successful turns have no artificial delay.

Scenario H requires an explicit restart override. Core's default remains
`:temporary`, and a restarted process does not restore its conversation.

Scenario I counts queued prompts only: one is running, two are queued, and
the next is rejected. Notifications count only events buffered during a turn.
Current overload errors contain an information map, including byte accounting;
the script asserts the count-limit fields and prints the full map. It makes no
assumptions about retained-event metadata or cancellation return shapes.

## Prototype gap checks on current core

1. **Unavailable task supervisor still stops a retrying agent**
   (tracked in genagent/gen_agent#305). The probe accepts the fixed outcome
   too, a typed retry error with the agent still running, so it keeps passing
   after the core fix.
   The dispatch path in `GenAgent.Server` calls `Task.Supervisor.async/2` without a
   local exit guard. The catch in `handle_event/4` converts
   the exit to `{:callback_failed, :exit, :other}`. The extra gap probe holds a
   turn, suspends the agent, explicitly terminates the caller-owned task
   supervisor, and resumes the agent. Suspending delivery makes the missing
   supervisor deterministic without racing `:rest_for_one` restarts. The
   original request **does** get its `{:task_crashed, :shutdown}` completion;
   dispatch of the self-chained retry then kills the agent instead of producing
   a typed request error for that retry. This is more precise than saying that
   no caller gets an error. The older prototype's `{:noproc, _}` exit is now
   hidden by the callback failure wrapper. Scenario F tests the normal tree
   restart independently; it does not claim that a retry succeeds.
2. **Backend-session exposure in the server crash status is resolved.**
   `GenAgent.Server.format_status/1` redacts the
   backend session, agent state, current request, and queues. The catch in
   `handle_event/4` also prevents callback arguments from appearing in the
   server exception report. The gap probe's actual crash report shows
   `backend_session: :redacted`. This is a check of server status formatting,
   not a claim that arbitrary backend exception messages cannot contain secrets.
3. **Restart without conversation resume still holds.**
   `GenAgent.Server.init/1` initializes fresh agent state and calls
   `start_session/1`. Core never calls `resume_session/2`, as documented in
   the `GenAgent.Backend` moduledoc. Scenario H verifies fresh state and a
   fresh backend session after a completed turn. The lab implements
   `resume_session/2` as a failure sentinel so unexpected use cannot pass.

These findings are recorded locally for separate library follow-up. This
example does not change core, the top-level README, or CI configuration.

## Verification

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix run scripts/chaos_lab.exs
mix run scripts/chaos_lab.exs
mix run scripts/chaos_lab.exs
```
