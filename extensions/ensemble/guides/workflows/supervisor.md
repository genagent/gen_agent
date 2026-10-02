# Supervisor workflow

## Topology

A coordinator agent receives the original prompt and emits a
decomposition. A user-supplied `:decomposer` function turns that
into a list of sub-prompts. The strategy then spawns N workers in
parallel, each with one sub-prompt. When every worker has responded,
a `:synthesizer` function (or the default newline join) combines
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

## Ad hoc (not config-driveable)

Supervisor's `:decomposer` and `:synthesizer` are functions, which
don't serialise into `config/config.exs`. Start it from iex or from
code instead:

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
...>     synthesizer: fn worker_outputs ->
...>       worker_outputs
...>       |> Enum.map(fn {_name, text} -> "- " <> text end)
...>       |> Enum.join("\n")
...>     end
...>   ]
...> )
```

If you want persistent supervisor ensembles, put the `start_link/1`
call in your application's `start/2` callback (or any supervision
tree), passing the functions as module references.

## Canonical workflow

### Single decomposed run

```elixir
iex> E.ask!("research", "why does Erlang have a separate process per stage?")
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
{:ok, %{phase: {:decomposing, "tok-7"}, ...}}

iex> E.status("research")
{:ok, %{phase: {:fanout, "tok-7", 3, 0}, ...}}  # 3 workers dispatched, 0 returned

iex> E.status("research")
{:ok, %{phase: :idle, ...}}

iex> E.await("research", tok) |> E.puts()
```

## Variations

- **Decomposer shape.** Any `String.t -> [String.t]`. Newline
  splitting is the simplest; regex or JSON parsing (if the
  coordinator is prompted to emit JSON) are common next steps.
- **Synthesizer shape.** `[{worker_name, String.t}] -> String.t`.
  Default joins worker outputs with `\n\n`. Common custom
  synthesizers: markdown bullet list, JSON merge, "elect the
  strongest answer" with a second LLM call.
- **Worker count is dynamic.** Decomposer output length determines
  how many workers run. If it returns an empty list, the ensemble
  replies with the default synthesizer output (an empty string).

## Gotchas

- **One in-flight run at a time.** If a second `tell` lands while a
  decomposition is in progress, it's queued and runs after the
  current fan-out completes. Not concurrent fan-outs -- use multiple
  Supervisor ensembles if you need those.
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
- **Decomposer/synthesizer errors fail the session.** If your
  user-supplied function raises, the ensemble halts. Wrap
  defensively if the coordinator output might be malformed.
- **Decomposition determines synthesizer order.** The synthesizer
  receives `[{worker_name, output_text}]` in the original sub-prompt
  order, regardless of worker completion order.

## Usage accounting

The coordinator and every completed worker count. An empty decomposition
returns the coordinator response with its usage counted once.

`Response.usage` contains summed numeric provider fields and a reserved
`:by_agent` map of agent names to their summed numeric fields. It stays `nil`
when no turn reports usage. Nonnumeric fields are dropped, and each invocation
starts fresh. Failed turns cannot be counted; session-cumulative backend usage
would overcount. See [usage accounting](overview.md#usage-accounting) for the
complete shape and per-turn reporting assumption.
