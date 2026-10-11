# Supervisor workflow

## Topology

A coordinator agent receives the original prompt and emits a
decomposition. A user-supplied `:decomposer` function turns that
into a list of sub-prompts. The strategy then spawns N workers in
parallel, each with one sub-prompt. When every worker has responded,
a `:synthesizer` function (or the default subtask-labeled join) combines
their outputs and replies to the caller.

```
                         +---------------+
              +--------> |  coordinator  |
              |          +-------+-------+
              |                  |
              |          decomposer (user fn)
              |                  |
              |                  v
              |          [sub-prompts]
              |                  |
              |        fan out in parallel
              |                  |
              |          +-------+-------+
              |   +----> |   worker 1   | ----+
   +-------+  |   |      +---------------+    |
   |  E.*  |--+   |      +---------------+    |
   +-------+      +----> |   worker 2   | ----+
                  |      +---------------+    |
                  |      +---------------+    |
                  +----> |   worker N   | ----+
                         +---------------+    |
                                              v
                                      synthesizer (user fn)
                                              |
                                              v
                                        final reply
```

## When to reach for it

- You have a big prompt that's naturally decomposable into
  independent parts answerable in parallel.
- You want the coordinator (an LLM) to do the decomposing, so the
  split adapts to the prompt content.
- You need a single-reply interface -- caller asks one question,
  gets one combined answer.

Classic shapes:

- "Research question" -> sub-questions -> per-question research ->
  synthesised answer
- "Audit this document" -> per-section concerns -> reviewer agents
  -> consolidated report
- "Plan this feature" -> distinct concerns (API, storage, tests) ->
  focused drafts -> integrated plan

For homogeneous batch work with user-supplied sub-prompts, use
Pool. For a linear chain with a fixed number of stages, use
Pipeline.

## Starting it

Supervisor's `:decomposer` and `:synthesizer` are functions. In
`config/config.exs` pass them as function references to a module you
define (for example `&MyApp.Research.decompose/1`). Named references
are preferred there: they survive release config handling and any
serialization of application config better than anonymous functions.
The Supervisor template in the package's `config/config.exs` shows the
shape. From iex or application code you can also pass anonymous
functions:

```elixir
iex> E.start_link(
...>   name: "research",
...>   strategy: GenAgentEnsemble.Strategies.Supervisor,
...>   opts: [
...>     coordinator:
...>       {"coord", GenAgentEnsemble.Agents.Simple,
...>        backend: GenAgent.Backends.Anthropic,
...>        system: """
...>        You decompose a question into 3-5 independent sub-questions,
...>        one per line, no numbering.
...>        """,
...>        model: "claude-sonnet-4-6"},
...>     worker_template:
...>       {"w", GenAgentEnsemble.Agents.Simple,
...>        backend: GenAgent.Backends.Anthropic,
...>        system: "Answer the question in 2-3 sentences.",
...>        model: "claude-sonnet-4-6"},
...>     decomposer: fn text -> String.split(text, "\n", trim: true) end,
...>     max_subtasks: 5,
...>     synthesizer: fn worker_outputs ->
...>       worker_outputs
...>       |> Enum.map(fn {_name, text} -> "- " <> text end)
...>       |> Enum.join("\n")
...>     end
...>   ]
...> )
```

If you want persistent supervisor ensembles, either use the config
form above or put the `start_link/1` call in your application's
`start/2` callback (or any supervision tree).

## Canonical workflow

### Single decomposed run

Decompose, fan out and recombine take several backend turns, so budget the
call with `timeout:` (default 30_000 ms). Expiry exits the caller; the
timeout itself does not cancel the work, which keeps running only if the
ensemble survives (the caller catches the exit, or a separate supervised
owner started it). An uncaught exit that kills the `start_link` owner stops
the ensemble. For recoverable waits use `GenAgentEnsemble.tell/2` +
`GenAgentEnsemble.await/3` (`E.await` raises on timeout).

```elixir
iex> E.ask!("research", "why does Erlang have a separate process per stage?", timeout: 300_000)
"""
- The BEAM's process model makes this cheap...
- Isolation: a crashing stage can't corrupt the others...
- Supervision trees restart failed stages deterministically...
"""
```

Single call, multiple underlying LLM calls (1 coordinator + N
workers in parallel + synthesis).

### Inspect during a run

```elixir
iex> {:ok, tok} = E.tell("research", "big question")
iex> E.status("research")
{:ok, %{phase: :decomposing, ...}}

iex> E.status("research")
{:ok, %{phase: {:fanning_out, 0, 3}, ...}}  # 0 of 3 workers returned

iex> E.status("research")
{:ok, %{phase: :idle, ...}}

iex> E.await("research", tok) |> E.puts()
```

## Variations

- **Decomposer shape.** Any `String.t -> [String.t]` (a list of binaries). Newline
  splitting is the simplest; regex or JSON parsing (if the
  coordinator is prompted to emit JSON) are common next steps.
- **Synthesizer shape.** A one-argument function receives ordered
  `[{worker_name, output_text}]`, preserving the original callback API.
  A two-argument function also receives the corresponding ordered
  sub-prompts. The default labels each worker response with its sub-prompt.
  Common custom
  synthesizers: markdown bullet list, JSON merge, "elect the
  strongest answer" with a second LLM call.
- **Worker count is dynamic but bounded.** Decomposer output length
  determines how many workers run, up to `:max_subtasks` (a positive
  integer, default 10; any other value raises `ArgumentError` at init).
  If it returns an empty list, the ensemble replies with the
  coordinator's response without invoking a synthesizer.

## Gotchas

- **One in-flight run at a time.** If a second `tell` lands while a
  decomposition is in progress, it's queued and runs after the
  current fan-out completes. Not concurrent fan-outs -- use multiple
  Supervisor ensembles if you need those.
- **Over-limit decompositions fail the run.** If the decomposer returns
  more than `:max_subtasks` sub-prompts, the caller receives
  `{:error, {:too_many_subtasks, count, max}}`. No workers are started
  and the list is not truncated. Queued requests continue normally.
  Prompt the coordinator for fewer sub-prompts or raise the limit.
- **Workers are ephemeral.** Each fan-out spawns fresh workers and
  stops them after synthesis. This means no per-worker conversation
  history accumulation across runs -- the trade-off is the
  start/stop cost per sub-prompt.
- **A worker death fails pending work.** If a worker process dies during
  fan-out, the active request and every queued request complete with
  `{:worker_down, worker_name, reason}`. Other workers are stopped;
  submit a fresh request to retry after inspecting the error.
- **Coordinator is persistent.** The coordinator agent's session
  lives across runs, so its input tokens grow as you reuse the
  ensemble. Restart if you want a clean coordinator.
- **Decomposer/synthesizer failures fail the run, not the ensemble.** If
  your `:decomposer` raises, throws or exits, or returns anything other
  than a list of binaries, or your `:synthesizer` fails or returns a
  non-binary, the caller receives
  `{:error, {:strategy_function_failed, label, kind, class}}` or
  `{:error, {:invalid_strategy_result, label}}`, with `label` either
  `:decomposer` or `:synthesizer`. Messages, stacktraces and returned
  values are not included. A decomposer failure happens before any worker
  starts. A synthesizer failure is replied first, then all workers are
  stopped. The ensemble keeps running and queued requests proceed. This
  covers only these built-in callbacks; it is not a general containment
  guarantee for custom strategies, and the built-in default synthesizer is
  not wrapped: only functions you supply are treated as user code.
- **Decomposition determines synthesizer order.** The synthesizer
  receives `[{worker_name, output_text}]` in the original sub-prompt
  order, regardless of worker completion order. For two-argument
  synthesizers, the second list has sub-prompts in that same order.

## Usage accounting

The coordinator and every completed worker count. An empty decomposition
returns the coordinator response with its usage counted once.

`Response.usage` contains summed numeric provider fields and a reserved
`:by_agent` map of agent names to their summed numeric fields. It stays `nil`
when no turn reports usage. Nonnumeric fields are dropped, and each invocation
starts fresh. Failed turns cannot be counted; session-cumulative backend usage
would overcount. See [usage accounting](overview.md#usage-accounting) for the
complete shape and per-turn reporting assumption.

## Opt-in structured runtime failures

Set `failure_reply: :structured` in the strategy's `opts` to receive:

```elixir
{:error, %GenAgentEnsemble.Strategies.Failure{
  strategy: strategy_module,
  phase: phase,
  agent: agent_name_or_nil,
  reason: original_reason,
  partial: [%{agent: name, phase: output_phase, index: index, text: text}]
}}
```

`failure_reply: :legacy` is the default and preserves existing error reasons
and operation ordering. Other option values raise `ArgumentError` at init.
Migrate caller error matches before opting in, for example:

```elixir
{:error, %GenAgentEnsemble.Strategies.Failure{agent: agent, reason: reason, partial: partial}}
```

This contract covers handled backend turn errors that abort the token, guarded
callback failures or malformed outputs, and scoped dispatch rejection. `reason`
is exactly the original legacy reason (including any agent tuple) or the
redacted Guard reason. Known turn, dispatch and callback agents are identified;
aggregate synthesis uses `agent: nil`.

Supervisor partials contain coordinator text with phase `:coordinator` and index 0, followed by completed workers with phase `:worker` and numeric assignment indexes starting at 1. Failure phases are `:turn`, `:dispatch`, `:decomposer` (including excessive decomposition), and `:synthesizer`. Empty decomposition remains successful. Worker start operation semantics are unchanged: a subsequent dispatch rejection identifies the worker but cannot recover the original worker-start error.

Partials contain only completed successful response texts, including the response
that triggers a callback failure and all completed synthesis inputs. Failed turns
and outstanding turns contribute no invented outputs or streamed fragments.
Only text is journaled in structured mode; retained text is cleared on success,
terminal failure, cancellation and successor start. Partials never mix queued
requests. Guard still redacts callback payloads, messages and stacktraces from
`reason`; response text and backend reasons may contain application data.

Agent deaths, halt, cancellation, timeouts, initialization/startup errors and
custom strategy/framework errors are outside this structured guarantee and keep
their existing semantics. Callers must handle those outcomes separately.
Structured failures are optional; the default contract remains legacy.
