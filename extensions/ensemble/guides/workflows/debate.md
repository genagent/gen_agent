# Debate workflow

## Topology

Two agents take turns arguing about a topic. The prompt hits the
first agent; that agent's response becomes the second agent's
prompt; the second agent's response becomes the first agent's next
prompt; and so on until they converge or a round cap is reached.

```
+-------+    +--------+        +-------+        +-------+
|  E.*  | -> | Debate | -----> | alice | -----> |  bob  |
+-------+    +--------+        +-------+   ^    +-------+
                                   ^        \_____|
                                   |______________|

turn 1:  "Topic X"          -> alice -> "opener"
turn 2:   "opener"           -> bob   -> "rebuttal"
turn 3:   "rebuttal"         -> alice -> "counter"
turn 4:   "counter"          -> bob   -> "AGREED on Y"  (converged)

final reply: transcript of all 4 turns, or last, or synthesized.
```

Each agent's backend session retains the full back-and-forth in its
own conversation memory, so turn N sees turns 1..N-1 in context.
The prompt wire format is just the previous agent's response text
(same convention as Pipeline), so the first turn's prompt is what
establishes the topic.

## When to reach for it

- You want two perspectives to interrogate each other (proposer vs
  critic, bull vs bear, security vs feature-velocity).
- Running the same question through two different backends (Claude
  + GPT, say) surfaces disagreements you would have missed solo.
- Architecture and design decisions where the failure mode of a
  single model is overconfidence.

For more than two agents or a moderator/synthesizer, Consensus
(planned) is the better fit. For parallel fan-out, use Supervisor.

## Config

```elixir
config :gen_agent_ensemble,
  ensembles: [
    [
      name: "redis-vs-postgres",
      strategy: GenAgentEnsemble.Strategies.Debate,
      opts: [
        agents: [
          {"pro-redis", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Anthropic,
            system: "You argue for Redis as the primary store. Be concrete, cite tradeoffs, respond directly to the other side's points."},
          {"pro-postgres", GenAgentEnsemble.Agents.Anthropic,
            backend: GenAgent.Backends.Anthropic,
            system: "You argue for Postgres as the primary store. Same rules."}
        ],
        rounds: 6,
        converge: &String.contains?(&1, "AGREED"),
        reply: :transcript
      ]
    ]
  ]
```

## Options

- `:agents` (required) -- exactly two `{name, module, opts}` specs.
  Distinct names.
- `:first` (optional) -- which agent speaks first. Defaults to the
  first entry in `:agents`.
- `:rounds` (optional) -- hard cap on total agent responses across
  both sides. Defaults to 6 (three exchanges per side). Hitting the
  cap ends the debate with whatever transcript has accumulated.
- `:converge` (optional) -- `(text -> boolean)`. Checked starting on
  turn 2. Returning `true` ends the debate immediately. Default:
  `fn _ -> false end` (round cap is the only limit).
- `:reply` (optional) -- how the final response is shaped:
    * `:transcript` (default) -- all turns joined as
      `"#{agent}:\\n#{text}"` separated by blank lines.
    * `:last` -- just the last agent's response text.
    * `{:synthesize, fun}` -- call `fun.(transcript)` where
      transcript is `[{agent_name, text}, ...]` in order.

## Canonical workflow

### Sync run

```elixir
iex> E.ask!("redis-vs-postgres", "Should a new event-sourced audit log land in Redis Streams or a Postgres partitioned table?")
"pro-redis:
...

pro-postgres:
...

pro-redis:
...

pro-postgres:
AGREED on one point: ..."
```

One call, up to `rounds` backend calls in sequence.

### Async run with a meatier topic

```elixir
iex> {:ok, tok} = E.tell("redis-vs-postgres",
...>   "Postgres 17 has logical replication with row filtering. Does that change the case for a dedicated CDC pipeline (Debezium/Kafka)?")
iex> E.await("redis-vs-postgres", tok, 120_000) |> E.puts()
```

### Inspect mid-debate

```elixir
iex> E.status("redis-vs-postgres")
{:ok, %{
  session: "redis-vs-postgres",
  strategy: GenAgentEnsemble.Strategies.Debate,
  phase: %{awaiting: "pro-postgres", turns: 3, transcript_len: 3},
  agents: ["pro-redis", "pro-postgres"],
  first: "pro-redis",
  rounds: 6,
  queued: 0,
  in_flight: 1,
  pending_tokens: ["tok-7"]
}}
```

### Custom synthesis

```elixir
iex> E.start_link(
...>   name: "code-review",
...>   strategy: GenAgentEnsemble.Strategies.Debate,
...>   opts: [
...>     agents: [
...>       {"optimist", GenAgentEnsemble.Agents.Simple,
...>         backend: GenAgent.Backends.Anthropic,
...>         system: "You find what's good about this code."},
...>       {"skeptic", GenAgentEnsemble.Agents.Simple,
...>         backend: GenAgent.Backends.Anthropic,
...>         system: "You find what's concerning about this code."}
...>     ],
...>     rounds: 4,
...>     reply: {:synthesize, fn transcript ->
...>       concerns =
...>         transcript
...>         |> Enum.filter(fn {who, _} -> who == "skeptic" end)
...>         |> Enum.map_join("\n", fn {_, text} -> "- #{text}" end)
...>       "Concerns:\n" <> concerns
...>     end}
...>   ]
...> )
```

## Variations

- **Heterogeneous backends.** The point of Debate is that different
  models have different blind spots; wire `pro-redis` to Claude and
  `pro-postgres` to OpenAI, or run Haiku against Sonnet for cheap
  cross-checking.
- **Asymmetric roles.** Nothing says both agents must argue. One
  side can be "propose a design," the other "find five things that
  will break in production" -- a code-review flow in disguise.
- **Structured verdict detection.** If you ask each agent to end its
  response with `VERDICT: (AGREE|DISAGREE)`, the `:converge` function
  can be `&String.contains?(&1, "VERDICT: AGREE")` for cheap
  mechanical convergence detection.

## Gotchas

- **One debate at a time per ensemble.** Additional `tell`/`ask`
  calls queue and run after the current debate finishes. If you
  want parallelism, start multiple Debate ensembles with different
  names.
- **Agents accumulate conversation state across runs.** A second
  `ask!` on the same ensemble continues with both agents'
  conversation history intact. If you want a fresh debate, restart
  the ensemble (`E.stop("name")` then `start_link` again).
- **Round cap is turns, not exchanges.** `rounds: 6` means 6 agent
  responses total, which is 3 exchanges per side. Set it to 4 if
  you want a shorter back-and-forth.
- **Convergence skips the first turn.** The opener can't converge
  against nothing. If the opener's text looks like agreement, the
  `:converge` check still waits until turn 2.
- **Either agent dying halts the session.** Debate needs both
  sides; there's no "recover with one speaker" mode.
- **`:reply :transcript` can get large.** Six turns at 1000 tokens
  each is 6K tokens in the final response. Use `:last` or
  `{:synthesize, ...}` if the full transcript isn't useful
  downstream.
