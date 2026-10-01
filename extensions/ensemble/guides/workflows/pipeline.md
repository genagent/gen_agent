# Pipeline workflow

## Topology

A linear chain of N stages. Each stage is its own sub-agent with its
own system prompt. The output text of stage K becomes the input
prompt of stage K+1. The last stage's response is what the caller
gets.

```
+-------+    +---------+    +-----------+    +-----------+    +-----------+
|  E.*  | -> |Pipeline | -> | stage 1   | -> | stage 2   | -> | stage N   |
+-------+    |         |    | (ideator) |    | (editor)  |    |(headliner)|
             +---------+    +-----------+    +-----------+    +-----------+
                                  |               |                |
                                  v               v                v
                             "5 ideas..."  "best one is..."  "one-liner..."
                                                                    |
                                                  final reply to caller
```

## When to reach for it

- You have a known, ordered sequence of transformations.
- Each stage has a distinct role best expressed by a different
  system prompt.
- You don't need to see the intermediate outputs -- only the final
  is returned.

Classic shapes:

- brainstorm -> rank -> headline
- extract -> structure -> summarise
- draft -> critique -> revise
- translate -> refine -> back-translate

For parallel fan-out, use Pool or Supervisor. For a single-stage
conversation, use Solo.

## Config

```elixir
config :gen_agent_ensemble,
  ensembles: [
    [
      name: "brainstorm",
      strategy: GenAgentEnsemble.Strategies.Pipeline,
      opts: [
        stages: [
          {"ideator", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Anthropic,
            system: "List 5 ideas for the given topic."},
          {"editor", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Anthropic,
            system: "Pick the best idea from this list and explain why."},
          {"headliner", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Anthropic,
            system: "Write a single punchy one-line headline."}
        ]
      ]
    ]
  ]
```

Stage names must be distinct within the pipeline. Sub-agent
namespacing handles isolation from other ensembles automatically.

## Canonical workflow

### Full chain, sync

```elixir
iex> E.ask!("brainstorm", "writing a tech blog that people actually read")
"# Tutorials turn strangers into believers by proving you can solve their problems right now."
```

Single call, multiple backend calls inside. Wall clock is the sum
of all stage latencies.

### Async

```elixir
iex> {:ok, tok} = E.tell("brainstorm", "shipping incidents without blame")
iex> E.await("brainstorm", tok, 60_000) |> E.puts()
```

### Inspect

```elixir
iex> E.status("brainstorm")
{:ok, %{
  session: "brainstorm",
  strategy: GenAgentEnsemble.Strategies.Pipeline,
  phase: :idle,
  stages: ["ideator", "editor", "headliner"],
  agents: ["editor", "headliner", "ideator"],
  in_flight: 0,
  queued: 0,
  pending_tokens: []
}}
```

During a run, `phase:` transitions through each stage's name so you
can see which stage is currently executing.

## Variations

- **Any number of stages.** Two is enough for a
  draft-then-critique shape; five or more for heavier pipelines.
- **Different backends per stage.** Nothing requires them to match.
  An `anthropic` ideator into a `claude` editor into an `openai`
  headliner is fine.
- **Stage-level max_turns / model.** Each stage's backend opts are
  independent, so you can use a bigger model for the heavy-lifting
  stage and a smaller one for the trimming.

## Gotchas

- **Only the last stage's response is returned.** Intermediate
  outputs are consumed silently. If you need to see them, read
  telemetry events (`[:gen_agent, :prompt, :stop]`) or write a
  custom strategy.
- **Errors short-circuit the pipeline.** If any stage's turn errors,
  the whole ensemble replies `{:error, {stage_name, reason}}` and
  the later stages never run.
- **Latency compounds.** Three 5-second stages = ~15 seconds
  wall clock. Not parallelisable by nature -- each stage needs the
  previous stage's output as its input.
- **Stages are stateful across runs.** Like Solo workers, each
  stage agent retains its own conversation history. A second
  `ask!` on the same pipeline replays all stage turns with
  accumulated context. Restart the ensemble if you want clean stages
  for the next run.
