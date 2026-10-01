# Strategy workflows

Each shipped strategy has a canonical command sequence that matches
its topology. This section documents those workflows so you can pick
the right strategy for the shape of work you're doing, and so the
usual iex idioms for each are in one place.

Examples use the `E` alias (`GenAgentEnsemble.IEx`) set up by the
repo's `.iex.exs`. Outside iex, call `GenAgentEnsemble` directly --
the same operations are available, minus the REPL-flavoured helpers
(`ask!`, `text`, `puts`, `await`, `drain`).

## Which strategy?

| Shape of work                                                   | Strategy    | Typical call                  |
|-----------------------------------------------------------------|-------------|-------------------------------|
| "Answer this one thing, maintaining a running conversation."    | Solo        | `E.ask!/2`                    |
| "Ask Alice or Bob specifically -- named fleet."                 | Switchboard | `E.ask!/3` with `agent:`      |
| "Answer N independent things, in parallel."                     | Pool        | `tell` + `drain`              |
| "Run this input through a chain of transformations."            | Pipeline    | `E.ask!/2`                    |
| "Decompose a big question, fan out, recombine."                 | Supervisor  | `E.ask!/2`                    |
| "Two perspectives interrogate each other until they converge."  | Debate      | `E.ask!/2`                    |
| "N agents vote on a decision and return a categorical verdict." | Consensus   | `E.ask!/2`                    |

Rough guide, not a rulebook -- a Solo can handle multi-turn
conversation just fine, a Pool can be used for a single prompt if
you want a fresh worker each time, and so on.

## Common idioms across strategies

**Quick synchronous turn:**

```elixir
iex> E.ask!("name", "prompt") |> IO.puts()
```

**Async, come back later:**

```elixir
iex> {:ok, tok} = E.tell("name", "prompt")
iex> # ...do other work...
iex> E.await("name", tok).text
```

**Batch submit + batch collect:**

```elixir
iex> tokens = for q <- questions, do: elem(E.tell("name", q), 1)
iex> Process.sleep(5_000)
iex> E.drain("name")
```

**Inspect in-flight:**

```elixir
iex> E.status("name")
```

**Peek at all sessions:**

```elixir
iex> E.list()
```

## Per-strategy guides

- [Solo](solo.md) -- single agent, passthrough
- [Switchboard](switchboard.md) -- named fleet, caller routes by `agent:` opt
- [Pool](pool.md) -- fixed-size worker pool, FIFO queue
- [Pipeline](pipeline.md) -- linear N-stage chain
- [Supervisor](supervisor.md) -- coordinator decomposes, workers fan out
- [Debate](debate.md) -- two agents alternate until convergence or round cap
- [Consensus](consensus.md) -- N peer agents vote with a structured verdict until they converge
