# GenAgent primitive examples

These single-file scripts run inside this Mix project against the core at
`../..`. The shared scripted backend runs entirely in the BEAM, with no API
keys, provider, CLI, or network calls.

| Script | Primitives |
| --- | --- |
| [01_hello.exs](scripts/01_hello.exs) | Initialization, response fields, ask, tell, pending/completed poll, FIFO queueing, status, stop |
| [02_requests.exs](scripts/02_requests.exs) | Completion recipient, exact-ref interruption, queued cancellation, prompt overload, watchdog, runtime snapshot, poll recovery |
| [03_events.exs](scripts/03_events.exs) | Notification admission, event callback decisions, ordered deferral, notification overload, halt and resume |

With Elixir 1.19 or later and dependencies fetched, run from this directory:

```sh
mix compile --warnings-as-errors
mix format --check-formatted
bash scripts/run_all.sh
```

Run one script with `mix run scripts/01_hello.exs`. In a sandbox that blocks
Mix's TCP concurrency lock, set `MIX_OS_CONCURRENCY_LOCK=0` for both the
scripts and the runner.

Each script prints explanations, asserts its outcomes, and ends with
`<script name>: ok`. The runner checks the exit status and exact final line
for every `scripts/*.exs` file. CI also compiles and checks formatting.

[Primitives.ScriptedBackend](lib/scripted_backend.ex) emits lazy word deltas,
illustrative usage counts, and a terminal result or error. Its `:delay_ms`
option delays every turn, and its `:script` map selects behavior by prompt:
`:echo`, `{:slow, milliseconds}`, `{:error, reason}`, or `{:gate, owner_pid}`.
Gated turns announce their task pid and a token, then wait for a release
message. The scripts use those gates to assert pending and queued states
without sleeps. The watchdog example uses a 60-second slow turn with a
100-millisecond watchdog, which cancels the task before the delay finishes.

Streaming, chaining/retry, and lifecycle hook examples are deferred to later
increments.
