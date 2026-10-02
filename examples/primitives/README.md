# GenAgent primitive examples

These single-file scripts run inside this Mix project against the core at
`../..`. The shared scripted backend runs entirely in the BEAM, with no API
keys, provider, CLI, or network calls.

| Script | Primitives |
| --- | --- |
| [01_hello.exs](scripts/01_hello.exs) | Initialization, response fields, ask, tell, pending/completed poll, FIFO queueing, status, stop |
| [02_requests.exs](scripts/02_requests.exs) | Completion recipient, exact-ref interruption, queued cancellation, prompt overload, watchdog, runtime snapshot, poll recovery |
| [03_events.exs](scripts/03_events.exs) | Notification admission, event callback decisions, ordered deferral, notification overload, halt and resume |
| [04_stream.exs](scripts/04_stream.exs) | Stream deltas to a sink, tool events, lossless event capture overflow |
| [05_chain_retry.exs](scripts/05_chain_retry.exs) | Response self-chaining, bounded retries for synchronous and terminal event errors |
| [06_hooks.exs](scripts/06_hooks.exs) | Setup, prompt rewrite, skip, usage accounting, token budget halt |

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
`:echo`, `{:slow, milliseconds}`, `{:error, reason}`, `{:fail, reason}`,
`{:tools, [{name, input, output}]}`, or `{:gate, owner_pid}`.
Errors emit a terminal error event; failures return a synchronous backend error.
Tools emit use/result pairs between text deltas and usage.
Gated turns announce their task pid and a token, then wait for a release
message. The scripts use those gates to assert pending and queued states
without sleeps. The watchdog example uses a 60-second slow turn with a
100-millisecond watchdog, which cancels the task before the delay finishes.
