# Debate workflow

## Topology

Two agents take turns arguing about a topic. The first agent receives
the original prompt. On turn 2 and beyond, each agent receives the
original prompt, the previous speaker's name, and that speaker's
response text. The debate continues until convergence or a round cap
is reached.

```
+-------+    +--------+        +-------+        +-------+
|  E.*  | -> | Debate | -----> | alice | -----> |  bob  |
+-------+    +--------+        +-------+   ^    +-------+
                                   ^        \_____|
                                   |______________|

turn 1:  "Topic X"
         -> alice -> "opener"

turn 2:  "Topic X" + "alice: opener"
         -> bob   -> "rebuttal"

turn 3:  "Topic X" + "bob: rebuttal"
         -> alice -> "counter"

turn 4:  "Topic X" + "alice: counter"
         -> bob   -> "AGREED on Y"  (converged)

final reply: transcript of all 4 turns, or last, or synthesized.
```

Each agent's backend session retains the full back-and-forth in its
own conversation memory, so turn N sees turns 1..N-1 in context.
The first turn receives the original question unchanged. Later turns
include the original question plus the previous agent's name and response,
so each agent knows who they are responding to and what the original topic was.

## When to reach for it

- You want two perspectives to interrogate each other (proposer vs
  critic, bull vs bear, security vs feature-velocity).
- Running the same question through two different backends (Claude
  + GPT, say) surfaces disagreements you would have missed solo.
- Architecture and design decisions where the failure mode of a
  single model is overconfidence.

For more than two agents or a moderator/synthesizer, Consensus
is the better fit. For parallel fan-out, use Supervisor.

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
          {"pro-postgres", GenAgentEnsemble.Agents.Simple,
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

## Usage accounting

Every completed turn counts, including repeated turns by the same agent.
Early convergence counts only the turns that ran. All reply modes carry usage.

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

Debate partials use `:turn` and one-based chronological turn indexes. Failure phases are `:turn`, `:dispatch`, `:converge`, and `:synthesizer_reply`.

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
