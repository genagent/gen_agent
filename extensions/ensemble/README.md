# gen_agent_ensemble

[![CI](https://github.com/genagent/gen_agent/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/gen_agent/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/gen_agent_ensemble.svg)](https://hex.pm/packages/gen_agent_ensemble)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/gen_agent_ensemble)

Multi-agent orchestration strategies for
[GenAgent](https://hex.pm/packages/gen_agent). Where `GenAgent`
gives you one process per LLM session, `gen_agent_ensemble` gives
you one process per *logical* session that owns N sub-agents under
a strategy. Single-agent is the degenerate `Solo` case.

This library is both:

- **A library** consumed by applications (MCP servers, LiveView
  apps, scripts) that need multi-agent orchestration.
- **A platform** for Elixir power users. Declare ensembles in
  `config/config.exs`, run `iex -S mix`, and your ensembles are
  live as named processes you can drive directly.

## Member names

Members register under `{GenAgentEnsemble, session, bare_member}`. Use
`GenAgentEnsemble.member_name/2` or `status.member_names` when calling core APIs:

```elixir
key = GenAgentEnsemble.member_name("research/2026", "reviewer/1")
%{name: ^key} = GenAgent.status(key)
```

This replaces handwritten `"session/member"` lookups. Bare strategy names stay
unchanged. See the [member-name migration guide](guides/member-names.md) for
collision handling, telemetry and the remaining named-routing identity boundary.

## Strategies (shipped)

| Strategy      | Topology                                 | Module                                      |
|---------------|------------------------------------------|---------------------------------------------|
| Solo          | One agent, passthrough                   | `GenAgentEnsemble.Strategies.Solo`          |
| Switchboard   | Named fleet, caller-routed               | `GenAgentEnsemble.Strategies.Switchboard`   |
| Pool          | N reusable workers, FIFO queue           | `GenAgentEnsemble.Strategies.Pool`          |
| Pipeline      | Linear stage chain                       | `GenAgentEnsemble.Strategies.Pipeline`      |
| Supervisor    | Coordinator + dynamic worker fan-out     | `GenAgentEnsemble.Strategies.Supervisor`    |
| Debate        | Two agents alternate until convergence   | `GenAgentEnsemble.Strategies.Debate`        |
| Consensus     | N peer agents vote with structured verdict | `GenAgentEnsemble.Strategies.Consensus`  |

See the [strategy workflow guides](guides/workflows/overview.md)
for the shape of each strategy, canonical iex workflows, and
per-strategy gotchas.

## Install

Add a backend from its own installation guide when using Ensemble:
[Claude](https://github.com/genagent/gen_agent/tree/main/integrations/claude),
[Codex](https://github.com/genagent/gen_agent/tree/main/integrations/codex),
[Anthropic](https://github.com/genagent/gen_agent/tree/main/integrations/anthropic),
or [OpenAI](https://github.com/genagent/gen_agent/tree/main/integrations/openai).

Ensemble requires GenAgent core `>= 0.10.0 and < 0.11.0` (`~> 0.10.0`).
Forward operations use `GenAgent.Client.notify/2`, introduced in core 0.10.0;
earlier cores cannot supply that function and are incompatible with this code.
The older synchronous child-admission implementation admitted core 0.7, 0.8,
and 0.9.

```elixir
def deps do
  [{:gen_agent_ensemble, "~> 0.7.4"}] # x-release-please-version
end
```

## Quickstart (zero-setup demo)

The GenAgent checkout ships the `"echo"` ensemble pre-enabled in
`extensions/ensemble/config/config.exs`. It uses
`GenAgentEnsemble.Backends.Echo` -- no API keys, no external
services, every prompt echoed back with an `"echo: "` prefix.
Every other ensemble in that file is commented out as a template you
can enable after wiring up real credentials.

The `echo` config and the `E` alias come from `extensions/ensemble`
only; the checkout root has neither. Start iex from that directory.
Its `.iex.exs` aliases `GenAgentEnsemble.IEx` to `E` -- a module that
delegates the core API (`list/0`, `ask/2`, `tell/2`, ...) and adds
REPL-flavoured helpers on top:

```sh
cd extensions/ensemble
mix deps.get
iex -S mix
```

In your own application, add the dependency from [Install](#install),
declare ensembles under `config :gen_agent_ensemble` (see below), and
add `alias GenAgentEnsemble.IEx, as: E` to your own `.iex.exs` (or
call `GenAgentEnsemble` directly). The `"echo"` ensemble is not
defined for you.

```elixir
iex> E.list()
["echo"]
iex> E.ask!("echo", "hello there")
"echo: hello there"
```

Once that feels right, uncomment one of the commented templates
in `config/config.exs` (Solo, Pool, Switchboard, Pipeline,
Supervisor, Debate, or Consensus), set the appropriate env var
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`), and restart iex.

## Real backend example

```elixir
config :gen_agent_ensemble,
  ensembles: [
    [
      name: "solo",
      strategy: GenAgentEnsemble.Strategies.Solo,
      opts: [
        agent:
          {"w", GenAgentEnsemble.Agents.Simple,
           backend: GenAgent.Backends.Anthropic,
           system: "You are a pragmatic Elixir reviewer.",
           model: "claude-sonnet-4-6"}
      ]
    ]
  ]
```

Config-declared ensembles are started under `GenAgentEnsemble.Supervisor`
with a `:transient` restart policy. An explicit `GenAgentEnsemble.stop/1`
exits normally and the ensemble stays stopped until the application is
restarted; an abnormal crash of the session is restarted. A strategy halt does
not exit the process (see "Halting" below): the halted ensemble stays
registered until it is stopped explicitly.
Caller supervisors can use the same public child spec described below.
Recovery after a crash of the
`GenAgentEnsemble.Supervisor` itself is not provided.

### Supervise ensembles in your application

Use `{GenAgentEnsemble, opts}` in your supervisor's children:

```elixir
children =
  for name <- ["research", "review"] do
    {GenAgentEnsemble,
     name: name,
     strategy: GenAgentEnsemble.Strategies.Solo,
     opts: [
       agent: {"worker", GenAgentEnsemble.Agents.Simple,
               backend: GenAgentEnsemble.Backends.Echo}
     ]}
  end

Supervisor.start_link(children, strategy: :one_for_one)
```

`GenAgentEnsemble.child_spec/1` requires `:name`, just like `start_link/1`.
Its ID is `{GenAgentEnsemble, name}`, so multiple distinct named ensembles
can share a supervisor without generating atoms. The `:transient` restart
policy keeps explicit stops stopped and restarts abnormal exits. A halted
ensemble is still a live child until it is stopped explicitly. `shutdown: :infinity` lets the owned agent tree finish using each
sub-agent's configured shutdown budget; blocking callbacks or infinite
budgets can prolong shutdown indefinitely. Override defaults with
`Supervisor.child_spec/2` if needed. Direct `start_link/1` calls retain their
caller-linked behavior.

Programmatic use:

```elixir
iex> E.ask!("solo", "What's wrong with `Enum.map(list, &(&1 + 1))`?") |> IO.puts()
# Nothing is wrong with it -- valid idiomatic Elixir...
```

Async fan-out with a Pool (declare it in config too):

```elixir
iex> {:ok, t1} = E.tell("qa-pool", "question one")
iex> {:ok, t2} = E.tell("qa-pool", "question two")
iex> E.status("qa-pool")
iex> E.await("qa-pool", t1, 60_000)
iex> E.await("qa-pool", t2, 60_000)
iex> E.drain("qa-pool")   # [{token, text}, ...] of completed tokens
```

See the [Pool workflow guide](guides/workflows/pool.md) for the
config shape and the fan-out-vs-serial gotcha.

See the [strategy workflow guides](guides/workflows/overview.md)
for the canonical command sequences for every strategy (Solo,
Switchboard, Pool, Pipeline, Supervisor, Debate, Consensus),
including per-strategy gotchas and variations.

## Public API

All functions are addressed by session name (the `:name` you put
in config). Shown here with the `E` alias (`GenAgentEnsemble.IEx`)
set up by the repo's `.iex.exs`.

### Core

| Function                   | Purpose                                            |
|----------------------------|----------------------------------------------------|
| `E.ask(name, prompt)`      | Synchronous single-turn. Blocks until reply.       |
| `E.tell(name, prompt)`     | Async. Returns a `token` you poll or drain later.  |
| `E.poll(name, token)`      | Non-blocking check; consumes a completed token.    |
| `E.inbox(name)`            | Drain all retained completed tokens.              |
| `E.notify(name, event)`    | Send an event to the strategy (cast).              |
| `E.status(name)`           | Inspect strategy phase, queue depth, etc.          |
| `E.stop(name)`             | Stop an ensemble cleanly.                          |
| `E.list()`                 | Names of all running ensembles.                    |
| `E.start_link(opts)`       | Start an ad-hoc ensemble imperatively (same shape  |
|                            | as a config entry).                                |

Tokens are opaque strings with a `tok-` prefix. Keep the returned value intact;
do not parse it or infer ordering. The Ensemble API assumes a trusted host:
token randomness does not authorize callers or isolate users.

Completed tell results are retained per ensemble with a top-level
`max_completed_results: 100` default, matching core's default tell result
limit. Set a non-negative integer (including `0` to disable retention), or
`:infinity` to explicitly allow unbounded retention. This option belongs
beside `:name` and `:strategy`, outside strategy `:opts`. Invalid values
return `{:error, {:invalid_option, :max_completed_results, value}}` before
strategy initialization or owned tree startup.

Successes, errors, and cancellations all count; the oldest by completion
order is evicted first. Asks are never cached. `poll/2` consumes one retained
result and `inbox/1` drains the cache; inbox entry order is unspecified.
`await/3` does not consume results. Later poll/await calls for evicted or
consumed tokens return `{:error, :not_found}`. Already registered waiters
and `tell_with_completion` recipients still receive terminal results when
retention is zero or the cache is full. The limit bounds result count and
cache bookkeeping, not response bytes, strategy state, or pending work.

Outstanding requests are bounded separately. Top-level
`max_pending_prompts: 1_000` and `max_pending_prompt_bytes: 1_048_576`
(each a non-negative integer or `:infinity`, validated like
`max_completed_results`) cap the public `ask`, `tell` and
`tell_with_completion` calls that are active or waiting in the session, for
every strategy. A call that does not fit returns
`{:error, {:overloaded, info}}` before any token, callback, or child work
exists; `info` has `queue: :ensemble_prompts`, `limit: :count | :bytes`, the
pending and incoming numbers, and both maximums. Zero rejects every new call.
Each accepted call is charged once with the `:erlang.external_size/1` of its
original prompt and keeps that charge, through pipeline stages, rounds and
fanout, until it reaches a terminal result (success, error, cancellation,
rejection, or halt). An uncertain cancellation closes the logical token but
retains its count and byte charge until every unresolved captured request has
terminal completion, admission rejection, or captured-PID death evidence.
Admission acknowledgement alone, result consumption, and result eviction do
not release this charge. A caller's `ask` timeout does not release it.
`E.status(name)` reports charged `pending_count` and `pending_bytes` under
`:admission`, including `unresolved_cancelled_tokens` and
`unresolved_cancelled_refs` counts. `pending_tokens` lists only logically pending
tokens. Each rejection emits `[:gen_agent_ensemble, :admission, :rejected]`. This is a budget for the
original serialized prompts, not a memory limit or a limit on physical work:
the mailbox, strategy state and options, generated prompts, intermediate
outputs, backend histories, and completed results are bounded separately.

Child dispatch uses nonblocking PID submission, replacing the older
synchronous child-admission behavior. A token acknowledges Ensemble
admission, not child admission. A held child `pre_turn` callback does not by
itself block subsequent submission, status, poll, inbox, or notify processing.

Child rejection closes the existing token through the usual result paths.
An immediate `poll` may still return `{:ok, :pending}`; use `await` or poll
until the terminal result arrives to observe child rejection.

For external strategy authors: synchronous ownership-guard rejection of a
scoped dispatch still ends its operation batch. Child admission rejection is
asynchronous; later operations in the batch, including sibling starts and
dispatches, may already have run before `handle_dispatch_rejected/4` is called.
Strategies must tolerate and clean up that work; rejection does not roll it
back. Unscoped rejection is logged without calling that token-scoped callback.
Submission reserves a per-token ordinal even when the child rejects it; the
`:dispatch, :rejected` event carries that ordinal and ref. Guard-time rejection
has neither. Accepted dispatch ordinals can therefore have gaps.

Cancellation runs exact-PID/ref controls in monitored workers, including before
child admission. All refs are fenced together and `handle_cancel/2` runs once
before controls start, removing the token from strategy FIFO bookkeeping.
Controls share one five-second absolute deadline across all references and any
required interruption. Reads, results, admissions and other cancellations can
proceed while controls wait. Duplicate cancellation returns
`{:error, :cancelling}`; caller death does not abandon cancellation. Strategy replies and token-scoped
dispatches for a cancelling token are rejected as unknown-token operations,
while its pending entry retains capacity. Halt during the wait returns
`{:error, {:halted, reason}}`; server termination exits the waiting call.

Terminal completion, admission rejection and captured-PID death settle physical
ownership. Timeout or worker failure returns `:cancelled_unconfirmed` and
transfers only unresolved refs into retained capacity leases. Consuming the
cancelled result does not release those leases.

Runtime strategy-generated child start and shutdown supervisor waits run in
lifecycle workers. Status, poll, inbox, await timers, admission, result evidence
and unrelated cancellation controls remain responsive while those waits are held.
Each callback batch retains operation order; independent batches can interleave.
Runtime starts and stops share one ordered lane. A start, stop, dispatch or
forward targeting a member currently reserved by a start or stop waits, along
with its remaining batch tail, until that reservation clears. Members named only later in an unexecuted
batch tail are not reserved. Custom strategies with cross-batch dependencies on
those future targets must sequence the operations themselves. Rejection fallback
runs after its callback batch finishes; a callback reply wins, and installed
cancellation keeps ownership of its terminal result.

Strategy callbacks, custom child-spec construction and telemetry handlers remain
synchronous and can block the server. Initialization and graceful session shutdown
still wait for owned children. Cancellation confirmation describes captured request
ownership, not completion of strategy cleanup or settlement of remote work.

Runtime `tell` and `notify` returns, and a subsequent `status`, may observe a
pending lifecycle operation. Completions from a member being stopped may still
reach the strategy before retirement. When cancellation has no in-flight refs,
its reply can wait for the `handle_cancel` cleanup batch to finish or the
five-second cancellation deadline, even though confirmation only describes
captured request ownership. Cleanup can continue after that deadline.

### Halting

A strategy's first `{:halt, reason}` ends the session logically and
immediately: the rest of its operation batch is skipped, every pending token
finishes with `{:error, {:halted, reason}}` (asks, completion recipients and
registered `await/3` callers included), and the strategy is never called
again. Results stored earlier are kept under the retention limit below.

Runtime mutating strategy callbacks also use this halt path when they raise,
throw, exit, or return an invalid envelope or improper operation list. Reasons
are `{:strategy_callback_failed, callback, kind}` (`:error`, `:throw`, `:exit`)
or `{:invalid_strategy_result, callback}`, without the failure value. The
session halt telemetry distinguishes deliberate `:strategy_halt` from
`:strategy_callback_failed` and `:invalid_strategy_result`. Failure logs contain
only the callback atom and kind/category. The full list spine is checked before
installing returned strategy state or running any operation. Individual malformed
operations retain their skip/log behavior.
An admitted tell still returns its token; an ask receives the halt error.
Strategy state is discarded. This provides no rollback of callback side effects,
recovery from blocking callbacks or untrappable kills, or containment of internal
framework failures. Initialization and read-only status have separate boundaries;
see `GenAgentEnsemble.Strategy`.

The ensemble process stays alive under the same PID and name so those results
can be collected. `await/3`, `poll/2`, `inbox/1`, `cancel/2` and `status/1`
keep working (`status/1` reports `lifecycle: :halted`); new `ask`, `tell` and
`tell_with_completion` calls return `{:error, {:halted, reason}}` without
starting work, and `notify/2` is ignored. The owned agent tree is told to shut
down at the halt. That shutdown is asynchronous and each child's configured
budget applies, so there is no latency guarantee and no guarantee an external
provider has settled.

A halted ensemble cannot be resumed. It holds its name, and under a
supervisor it counts as an active child, until `GenAgentEnsemble.stop/1`, an
explicit supervisor termination, or the exit of its owner disposes of it.
Disposal discards the retained results. Until then they stay in memory with no
expiry, bounded by `max_completed_results` (a result count, not bytes; zero
keeps none). Halt errors count against that bound like any other result.

### Helpers (iex-flavoured sugar)

| Function                   | Purpose                                            |
|----------------------------|----------------------------------------------------|
| `E.ask!(name, prompt)`     | Like `ask/2` but returns the response text string. |
| `E.text(resp)`             | Extract `.text` from `%Response{}` or `{:ok, r}`.  |
| `E.puts(resp)`             | Print response text (markdown-friendly).           |
| `E.await(name, token)`     | Block on a `tell` token, return the `%Response{}`. |
| `E.drain(name)`            | `inbox` unwrapped to `[{token, text}, ...]`.       |

For library code (not iex), call `GenAgentEnsemble` directly -- the
`GenAgentEnsemble.IEx` module is a humans-at-the-prompt convenience.

**Ask timeouts.** `ask` defaults to 30_000 ms. Override per call with
`timeout:` (non-negative integer or `:infinity`) or globally with
`config :gen_agent_ensemble, ask_timeout: 120_000`; the per-call option
wins. Expiry exits the *calling* process; the timeout itself does **not**
cancel the work, which keeps running only if the ensemble survives (the
caller catches the exit, or a separate supervised owner started the
ensemble). If the uncaught exit kills the process that called `start_link`,
the ensemble stops with it. For long or recoverable waits call
`GenAgentEnsemble.tell/2` and `GenAgentEnsemble.await/3`, where a timeout
returns `{:error, :timeout}` and the result can be fetched later while the
ensemble is alive. (`E.await` is the iex helper and raises on timeout
instead.) Invalid values raise `ArgumentError` before any work is submitted.

`GenAgentEnsemble.cancel(name, token)` closes a pending token with
`{:error, :cancelled}` through the existing completion, await, ask, and
poll/inbox paths while preserving other tokens and the session. It returns
`{:ok, :cancelled}` for acknowledged child requests or
`{:ok, :cancelled_unconfirmed}` for uncertain child outcomes; neither proves
an external provider has settled. Finished/consumed/unknown tokens return
`:already_finished` or `:not_found` errors. Custom strategies must implement
`handle_cancel/2`, otherwise cancellation returns `{:error, :unsupported}`.

## Ad-hoc ensembles from iex

You don't have to use config. Any ensemble can be started
imperatively with the same opts shape:

```elixir
iex> E.start_link(
...>   name: "scratch",
...>   strategy: GenAgentEnsemble.Strategies.Solo,
...>   opts: [
...>     agent: {"w", GenAgentEnsemble.Agents.Simple,
...>             backend: GenAgentEnsemble.Backends.Echo,
...>             transform: &String.upcase/1}
...>   ]
...> )
iex> E.ask!("scratch", "hello")
"HELLO"
```

This is the natural way to prototype: try a config inline, iterate,
then promote to `config/config.exs` when you're happy with it.

## Secrets and `config/runtime.exs`

API keys and other secrets don't belong in `config/config.exs`
(compile-time evaluated, checked into git). Use
`config/runtime.exs` or environment variables that the backend
reads directly.

For Anthropic:

```sh
export ANTHROPIC_API_KEY=...
iex -S mix
```

## Built-in `Simple` agent

`GenAgentEnsemble.Agents.Simple` is a reusable one-turn callback
module. Accepts any backend options (`:system`, `:system_prompt`,
`:model`, `:cwd`, etc.) and forwards them to the backend. Use it
for iex experimentation and as the worker for simple ensembles.

For real projects you'll typically write your own callback module
with richer state and prompt-engineered behaviour -- Simple is the
shortest path to "working ensemble in 10 lines of config."

## Telemetry

Ensemble emits observational session, token, and dispatch events. A
dispatch's agent name and ordinal identify Pipeline stages and Supervisor
branches; its turn reference links to core GenAgent telemetry. Events do
not include prompts or responses. See `GenAgentEnsemble.Telemetry` for the
event contract and cardinality guidance. Completion delivery does not rely
on telemetry handlers.

## Development

From `extensions/ensemble` in the GenAgent checkout:

```sh
mix deps.get
mix test
```

Local development uses path dependencies on core and the four adapters.
Set `GEN_AGENT_HEX=1` when building or publishing a standalone Hex archive;
the package then declares ordinary Hex requirements instead.

Full pre-commit checklist (matches CI):

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test
```

## Status

Pre-1.0. The strategy op vocabulary
(`:start | :stop | :dispatch | :reply | :reply_error | :forward | :halt`)
and public API are stable and unlikely to change further before 1.0.
Breaking changes bump the minor version; see [CHANGELOG.md](CHANGELOG.md) for
what's changed.
