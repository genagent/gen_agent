# Consensus workflow

## Topology

N peer agents deliberate on a prompt in parallel, each returning
a **structured verdict** plus rationale. A convergence threshold
decides whether they agree; if not, the strategy composes a
re-prompt showing each agent the others' positions and runs
another round. After the round cap, it returns a divergence
report.

```
+-------+    +-----------+
|  E.*  | -> | Consensus | -> dispatch prompt to all N agents in parallel
+-------+    +-----------+
                   |
                   v
             all responded?
                   |
             +-----+-----+
             |           |
             v           v
         threshold    not converged,
          met?          round < cap?
             |           |
             v           v
        CONSENSUS:     re-prompt each agent with
        :verdict       the *others'* rationales
                       and go again
```

Unlike Debate (boolean convergence on free-form text), Consensus
produces a **programmable decision**: the caller branches on an
atom (`:approve | :revise | :reject` or whatever categorical
space the verdict parser uses) without re-parsing LLM prose.

## When to reach for it

- Architecture / design decisions where multi-model perspectives
  reduce the risk of a single model's blind spots.
- Security or safety reviews where you want multiple independent
  judgments before acting.
- Multi-reviewer code review loops (drop into a larger DevTeam
  flow as the "approve or revise?" gate).
- Any decision whose output is a categorical label with rationale.

Where it's wrong:

- You want a long free-form back-and-forth, not a vote. Use Debate.
- You want one coordinator to decompose and aggregate. Use
  Supervisor.
- You want one prompt through a linear chain. Use Pipeline.

## Config

```elixir
defmodule DecisionParser do
  def parse(text) do
    case Regex.run(~r/VERDICT:\s*(APPROVE|REVISE|REJECT)\b/i, text) do
      [_, verdict] ->
        atom = verdict |> String.downcase() |> String.to_atom()
        rationale = Regex.replace(~r/VERDICT:\s*\w+/i, text, "") |> String.trim()
        {:ok, atom, rationale}

      _ ->
        :error
    end
  end
end

config :gen_agent_ensemble,
  ensembles: [
    [
      name: "arch-review",
      strategy: GenAgentEnsemble.Strategies.Consensus,
      opts: [
        agents: [
          {"claude", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Anthropic,
            model: "claude-sonnet-4-6",
            receive_timeout: 180_000,
            system: system_prompt()},
          {"haiku", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Anthropic,
            model: "claude-haiku-4-5-20251001",
            system: system_prompt()},
          {"claude-cli", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Claude,
            system_prompt: system_prompt()}
        ],
        verdict_parser: &DecisionParser.parse/1,
        threshold: :majority,
        rounds: 3,
        reply: :synthesis
      ]
    ]
  ]
```

Where `system_prompt/0` returns something like:

```elixir
"You review technical proposals. Be concrete about tradeoffs, " <>
"specific about risks. Keep to 3-5 tight sentences. " <>
"End every response with exactly one line: " <>
"VERDICT: APPROVE, VERDICT: REVISE, or VERDICT: REJECT."
```

## Options

- `:agents` (required) -- 2+ `{name, module, opts}` specs, distinct
  names.
- `:verdict_parser` (required) -- `(text -> {:ok, atom, rationale}
  | :error)`. The atom is the verdict category; the rationale is
  the response text with verdict markers stripped (the re-prompt
  shows this to the other agents, so strip the machine-readable
  part for cleaner context).
- `:threshold` (optional) -- convergence rule. Defaults to
  `:majority`.
    * `:unanimous` -- every agent must produce the same verdict
      and nobody abstains.
    * `:majority` -- more than N/2 agents agree on the same
      verdict.
    * `{:at_least, n}` -- at least `n` agents agree.
- `:rounds` (optional) -- hard cap on rounds. Defaults to 3.
- `:reply` (optional) -- response shape:
    * `:synthesis` (default) -- converged: verdict header +
      per-agent rationale. Diverged: divergence header + each
      agent's final position.
    * `{:synthesize, fun}` -- call `fun.(summary)` where summary
      is `%{status: :converged | :diverged, verdict: atom | nil,
      rounds: integer, threshold: threshold_spec, responses:
      [{agent, verdict_or_nil, rationale, raw_text}]}`. Useful for
      piping the decision out as structured data.

## Canonical workflow

### Sync run

```elixir
iex> E.ask!("arch-review",
...>   "Proposal: replace ETS session store with Redis for a 500 RPS service. " <>
...>   "30min TTL, 2KB sessions, team has no Redis experience. Should this go forward?"
...> ) |> E.puts()
CONSENSUS: :revise (3 of 3 agreed via majority, round 1)

claude [REVISE]:
At 500 RPS with 2KB payloads and 30min TTL...
...
```

### Extracting the decision as a pipeable atom

```elixir
iex> summary =
...>   E.start_link(
...>     name: "scratch",
...>     strategy: GenAgentEnsemble.Strategies.Consensus,
...>     opts: [
...>       agents: [...],
...>       verdict_parser: &DecisionParser.parse/1,
...>       reply: {:synthesize, &Function.identity/1}
...>     ]
...>   )
iex> {:ok, %{text: summary}} = E.ask("scratch", "...")
iex> summary.verdict
:approve
iex> summary.status
:converged
```

Note: `{:synthesize, fn}` returns whatever the fn returns from
the ensemble as `response.text`. When the fn returns a map (as
with `&Function.identity/1`), the "text" field holds that map,
which is a minor abuse of the `%Response{}` shape but handy for
programmatic use.

### Async

```elixir
iex> {:ok, tok} = E.tell("arch-review", proposal)
iex> E.status("arch-review")
{:ok, %{phase: %{round: 1, responded: 2, expected: 3}, ...}}
iex> E.await("arch-review", tok, 600_000) |> E.puts()
```

## Variations

- **Heterogeneous backends.** The value proposition: different
  models bring different biases. Run Claude Sonnet + GPT-5-mini +
  Haiku on the same proposal and the disagreements surface risks
  a single model would have hidden.
- **Asymmetric roles.** Give each agent a different system prompt
  -- "you review for correctness", "you review for performance",
  "you review for operational risk" -- and Consensus turns into
  a multi-perspective review panel.
- **Custom verdict space.** The parser owns the atom space. You
  can use `:yes | :no`, `:ship | :hold | :kill`,
  `:red | :yellow | :green`, etc. Anything the models can be
  taught to emit.
- **Strict vs loose convergence.** `:unanimous` is strict (useful
  for high-stakes gates); `{:at_least, 2}` with N=4 is loose
  (useful for "two seconds" style reviews).

## Gotchas

- **The system prompt does the teaching.** The verdict parser
  only detects the format; the agents have to *produce* it. Be
  explicit in the system prompt about the exact format ("End with
  VERDICT: X") or unparseable responses proliferate and you burn
  rounds for no reason.
- **Abstains don't block convergence.** If one agent's response
  is unparseable, the remaining agents can still hit the threshold.
  That's by design -- one malformed response shouldn't tank the
  panel. But watch for a systemic parse-rate problem via `status`
  or logs.
- **Re-prompts are pure text.** The strategy inserts the others'
  rationales into each agent's next prompt. The agent's own
  previous response stays in its backend's conversation memory.
  This means each round's re-prompt is heavy -- expect larger
  token counts on round 2+ than round 1.
- **One consensus at a time.** Concurrent `tell`/`ask` calls
  queue. For parallel review panels, start multiple Consensus
  ensembles.
- **Agent death halts the session.** The panel size is baked in
  at init; a dead agent invalidates the threshold arithmetic.
  If an agent's backend (e.g. CLI subprocess) dies, restart the
  whole ensemble rather than expecting a partial panel.
- **Heterogeneous backends == heterogeneous timeouts.** Sonnet
  responses through `gen_agent_anthropic` need `:receive_timeout:
  180_000` to reliably complete long-context rounds. OpenAI's
  gpt-5-mini is a reasoning model and can burn output tokens on
  hidden reasoning -- set `:max_output_tokens` high enough to
  leave room for the actual message.
