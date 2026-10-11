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

The package resolves a compatible GenAgent core version through its dependency.

```elixir
def deps do
  [{:gen_agent_ensemble, "~> 0.6.1"}] # x-release-please-version
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
or a strategy halt exits normally and the ensemble stays stopped until the
application is restarted; an abnormal crash of the session is restarted.
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
policy keeps explicit stops and strategy halts stopped and restarts abnormal
exits. `shutdown: :infinity` lets the owned agent tree finish using each
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
