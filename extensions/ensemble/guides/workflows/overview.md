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

## Custom agent request boundaries

Ensemble tracks each child dispatch by its GenAgent request reference.
A token result means the strategy finished that request; it does not imply
that the child is idle or all autonomous work has finished.

A custom agent's `handle_response/3` returning
`{:prompt, next_prompt, state}` completes the dispatched request with the
current response, then starts an **independent follow-up** with a fresh
reference. That follow-up runs before prompts queued in the child. Its result
reaches the agent's callbacks, but cannot complete an Ensemble token, replace
a retained result, or consume another token's reply. Solo, Pool and
Switchboard use the original response; Pipeline passes that response to its
next stage. Pool can dispatch new work to the logically free worker while its
follow-up is still running; that work queues inside the child.

Error retries have a different contract, introduced in **GenAgent 0.8**.
For a dispatched ask/tell, `handle_error/3` returning
`{:prompt, retry_prompt, state}` retains the original request reference.
Ensemble waits for the final success or error instead of completing on the
first failed attempt. Keep a retry budget in agent state; GenAgent supplies
no automatic retry cap, and the watchdog applies to each attempt. Interrupted
requests and retries rejected by admission limits are exceptions; see
`c:GenAgent.handle_error/3` for their terminal outcomes.

**With supported GenAgent 0.7, the first error completes the dispatch and a
callback-generated retry is an independent follow-up.** Installing Ensemble
alone does not change this older core behavior. Ensemble admits core 0.7 and
0.8; the final-outcome retry contract requires actually loading core 0.8.
Do not infer it from an Ensemble upgrade that still resolves core 0.7.

For a result assembled from several successful turns, use explicit Pipeline
stages or a custom strategy that owns the workflow. A response-generated
self-chain does not automatically extend the original caller's request.

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

The public `GenAgentEnsemble.status/1` returns `{:ok, status_map}` on success.
A custom strategy status callback that raises, throws or exits returns
`{:error, {:strategy_callback_failed, :handle_status, kind}}` with `kind` equal
to `:error`, `:throw` or `:exit`. Any non-map return produces
`{:error, {:invalid_strategy_result, :handle_status}}`. A failed query has no
successful status map and leaves the Ensemble process, framework state, pending
work and retained results intact. Callers can retry status later. The callback
still runs synchronously and can block the server; containment cannot undo its
side effects. See `GenAgentEnsemble.status/1` for the full inspection contract.

**Limits on outstanding requests.** Every strategy shares one admission gate.
A session accepts at most `max_pending_prompts` (default 1_000) calls to
`ask`/`tell` that have not yet reached a result, and at most
`max_pending_prompt_bytes` (default 1_048_576) of their original serialized
prompts, counting active and queued requests together. A call beyond either
limit returns `{:error, {:overloaded, info}}` and does nothing else, so a
batch submit larger than the limit must check each `tell` result or raise the
limit. Unconfirmed cancellation retains capacity until the captured requests
have terminal evidence; consuming the cancelled result does not release it.
The `:admission` key of `E.status("name")` shows the current counters. See
`GenAgentEnsemble` for the full contract and what it does not bound.

Runtime child start/shutdown supervisor waits suspend only their operation batch.
Status, poll, inbox, await timers and unrelated cancellation controls remain
responsive. Independent callback batches may interleave; runtime starts and stops
share one ordered lane. A start, stop, dispatch or forward targeting a member
currently reserved by a start or stop waits, along with its remaining batch tail,
until that reservation clears. Members named only later in an unexecuted batch tail are not reserved.
Custom strategies with cross-batch dependencies on those future targets must
sequence the operations themselves. Strategy callbacks and custom child-spec
construction still run synchronously. Initialization and graceful shutdown still wait for owned children.
Cancellation confirmation covers captured request ownership, not completion of
strategy cleanup.

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

## Usage accounting

Debate, Consensus, Supervisor, and Pipeline sum numeric usage fields over
all successful turns in one invocation, preserving provider keys:

```elixir
%{
  input_tokens: 30,
  output_tokens: 12,
  by_agent: %{
    "reviewer" => %{input_tokens: 10, output_tokens: 4},
    "writer" => %{input_tokens: 20, output_tokens: 8}
  }
}
```

`Response.usage` remains a map or `nil`, compatible with `gen_agent ~> 0.6.0`.
The reserved `:by_agent` map attributes totals by configured agent name
(including Supervisor's coordinator and generated worker names). Its numeric
fields sum to the top-level totals. Repeated turns by the same agent accumulate;
fresh and queued invocations each start at zero, including after errors.

If no turn reports usage, `usage` stays `nil`. Non-map usage is ignored.
A reported empty map, or a map with only nonnumeric values, retains an empty
entry for that agent. Nonnumeric fields and nested metadata are dropped;
`:by_agent` is reserved and never treated as a numeric provider total.
Solo, Pool, and Switchboard pass their selected response through unchanged.

Only successful responses can be counted: failed turns expose no response to
the strategy. Usage must be **per turn**. Core keeps the latest usage event
within each turn; summing session-cumulative backend reports would overcount.

## Member names and migration

Use `GenAgentEnsemble.member_name(session, bare_member)` for core calls, Registry
lookups and telemetry filters. Members now use tagged tuple keys rather than
handwritten `"session/member"` strings. See the [member-name migration guide](../member-names.md)
for the public helper, status mapping, collision errors and ownership boundaries.
