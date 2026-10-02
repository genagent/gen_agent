# Pool workflow

## Topology

One ensemble process owning N identical sub-agents. Each tell/ask
lands on the next free worker; when all are busy, prompts queue FIFO
and dispatch as workers free up.

```
+-------+    +-------+    +----------+
|  E.*  | -> | Pool  | -> | worker 1 | -> backend session 1
+-------+    |       |    +----------+
             |       |    +----------+
             |       | -> | worker 2 | -> backend session 2
             |       |    +----------+
             |       |    +----------+
             |       | -> | worker N | -> backend session N
             +-------+    +----------+
```

## When to reach for it

- You have many independent prompts and want them answered in
  parallel.
- You want bounded concurrency: "up to N at once, overflow queues."
- The work is homogeneous -- same system prompt and backend for
  each worker.

For coordinated fan-out where the sub-prompts are derived from a
parent prompt, use Supervisor. For a pipeline of transformations
through different agents, use Pipeline.

## Config

```elixir
config :gen_agent_ensemble,
  ensembles: [
    [
      name: "qa-pool",
      strategy: GenAgentEnsemble.Strategies.Pool,
      opts: [
        worker_count: 3,
        worker_template:
          {"qa", GenAgentEnsemble.Agents.Simple,
           backend: GenAgent.Backends.Anthropic,
           system: "Answer tersely. One paragraph max.",
           model: "claude-sonnet-4-6"}
      ]
    ]
  ]
```

Workers are automatically named `"qa-1"`, `"qa-2"`, `"qa-3"` from
the template's prefix.

## Canonical workflow

### Fan-out batch

```elixir
iex> questions = ["What is GenServer?", "What is a Supervisor?", "What is ETS?"]
iex> tokens = for q <- questions, do: elem(E.tell("qa-pool", q), 1)
["tok-3", "tok-4", "tok-5"]

iex> E.status("qa-pool")
{:ok, %{busy: 3, free: 0, queued: 0, workers: ["qa-1", "qa-2", "qa-3"], ...}}

iex> Process.sleep(5_000)
iex> E.drain("qa-pool")
[
  {"tok-3", "A GenServer is..."},
  {"tok-4", "A Supervisor is..."},
  {"tok-5", "ETS is..."}
]
```

Fire the tells in a single pipeline (`for` comprehension or
`Enum.map`) so they land at the Pool before any can finish.
Otherwise a worker may finish before the next request arrives, and
the requests will run sequentially instead of in parallel. Idle
workers rotate, so sequential requests are spread across the pool.

### Overflow queueing

```elixir
iex> tokens = for q <- many_questions(), do: elem(E.tell("qa-pool", q), 1)
iex> E.status("qa-pool")
{:ok, %{busy: 3, free: 0, queued: 7, ...}}

# Drain as they finish:
iex> :timer.tc(fn -> Enum.each(tokens, &E.await("qa-pool", &1, 30_000)) end)
```

### One-off sync through the pool

```elixir
iex> E.ask!("qa-pool", "single question")
```

Uses whichever worker is free. If all are busy, queues behind them.

## Variations

- **Worker count.** Tune `worker_count:` for concurrency vs cost.
  Three is a reasonable default.
- **Heterogeneous workers?** Not directly -- Pool clones one
  template. If you need different system prompts per worker, use
  Supervisor with a `:worker_template` and a decomposer that
  assigns roles, or run multiple Pool ensembles.

## Gotchas

- **Workers retain per-worker conversation history.** The Pool
  recycles workers across turns, and each worker's backend session
  persists. Sequential requests rotate among idle workers, then
  return to each worker's existing conversation. Use a fresh-session
  callback module if you need isolated single turns.
- **`status` races against fast turns.** If you call `E.status` in a
  separate iex line after firing tells, a sub-second turn may have
  already completed, showing `busy: 0`. Capture status right after
  dispatch in the same expression if you want to see the in-flight
  state.
- **Worker death starts a fresh worker.** An in-flight token fails
  with `{:worker_down, reason}`; queued requests can continue on the
  replacement. The new worker has a fresh backend session and loses
  the dead worker's conversation history. If replacement startup fails,
  that slot is removed. Other workers continue; if none remain, the pool
  halts and pending requests fail.
