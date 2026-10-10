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
  def system_prompt do
    "You review technical proposals. Be concrete about tradeoffs, " <>
      "specific about risks. Keep to 3-5 tight sentences. " <>
      "End every response with exactly one line: " <>
      "VERDICT: APPROVE, VERDICT: REVISE, or VERDICT: REJECT."
  end

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
            system: DecisionParser.system_prompt()},
          {"haiku", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Anthropic,
            model: "claude-haiku-4-5-20251001",
            system: DecisionParser.system_prompt()},
          {"claude-cli", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Claude,
            system_prompt: DecisionParser.system_prompt()}
        ],
        verdict_parser: &DecisionParser.parse/1,
        threshold: :majority,
        rounds: 3,
        reply: :synthesis
      ]
    ]
  ]
```

`DecisionParser.system_prompt/0` is defined in the same block so the
example is self-contained. Compile the module before the config is
read (or define it at the top of `config.exs`), and adjust the prompt
to your verdict space.

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

  Convergence needs a unique leading verdict that meets the
  threshold. When two verdicts tie for the highest count (for
  example 2-2 with `{:at_least, 2}`), the round does not converge:
  the panel is re-prompted, or diverges at the round cap.
- `:rounds` (optional) -- hard cap on rounds. Defaults to 3.
- `:reply` (optional) -- response shape:
    * `:synthesis` (default) -- converged: verdict header +
      per-agent rationale. Diverged: divergence header + each
      agent's final position.
    * `{:synthesize, fun}` -- call `fun.(summary)` where summary
      is `%{status: :converged | :diverged, verdict: atom | nil,
      rounds: integer, threshold: threshold_spec, responses:
      [{agent, verdict_or_nil, rationale, raw_text}]}`. The returned
      value must be a binary; the structured decision is always in
      `response.metadata.consensus` (see "Reading the decision").

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

### Rendering the decision with a custom reply

```elixir
iex> {:ok, _pid} =
...>   E.start_link(
...>     name: "scratch",
...>     strategy: GenAgentEnsemble.Strategies.Consensus,
...>     opts: [
...>       agents: [...],
...>       verdict_parser: &DecisionParser.parse/1,
...>       reply: {:synthesize, fn summary ->
...>         case summary.status do
...>           :converged -> "Decision: #{summary.verdict}"
...>           :diverged -> "No consensus reached"
...>         end
...>       end}
...>     ]
...>   )
iex> {:ok, %{text: text}} = E.ask("scratch", "...")
iex> text
"Decision: approve"
```

The callback receives the summary map and can read `summary.status` and
`summary.verdict` to choose the reply. It must return a binary, which becomes
`response.text`. Returning a map or any other non-binary fails the token with
`{:invalid_strategy_result, :synthesizer_reply}` in legacy mode. Do not put the
decision in `text`; read it from the typed metadata below.

### Reading the decision

Every successful response, whatever the `:reply`, carries the decision in
`response.metadata.consensus`. `response.text` stays a binary.

```elixir
{:ok, %{metadata: %{consensus: consensus}}} = E.ask("arch-review", proposal)

case consensus do
  %{status: :converged, verdict: :approve} -> :ship
  %{status: :converged, verdict: verdict} -> {:changes, verdict}
  %{status: :diverged, votes: votes} -> {:no_consensus, votes}
end
```

`consensus` is `%{status: :converged | :diverged, verdict: atom | nil,
rounds: integer, threshold: threshold_spec, votes: [%{agent: name,
verdict: atom | nil, rationale: String.t()}]}`. `votes` follow the configured
agent order; a `nil` verdict is an abstain. Raw agent text is not included.
Failed asks return errors and carry no decision, and each queued turn gets its
own metadata.

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
  panel. The strategy does not log parse failures and `status`
  reports no abstain count. To spot a systemic parse problem, look
  for `nil` verdicts in the `responses` of a `{:synthesize, fun}`
  summary (or the abstains in the default reply), then tighten the
  system prompt or parser.
- **Turn errors are tolerated while the threshold is reachable.**
  A provider error (rate limit, timeout) from one agent is recorded
  as an abstain for that round, with a `nil` verdict and a rationale
  describing the error. The threshold is computed from the fixed
  panel size, so errors do not lower the votes required. If the
  largest vote count plus the turns still outstanding can no longer
  meet the threshold, the ask fails with the first `{agent, reason}`
  seen in the round. `:unanimous` therefore fails on any turn error.
  Errors are tracked per round: a re-prompted round starts clean and
  dispatches to the failed agent again.
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

## Usage accounting

Every completed response in every round counts, including abstains. Both
converged and diverged replies, including custom synthesis, carry usage.

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

Consensus partials use `:turn` and one-based round indexes, ordered by round then configured agent order. Completed texts from earlier rounds are retained; tolerated turn errors add no text. Failure phases are `:turn`, `:dispatch`, `:verdict_parser`, and `:synthesizer_reply`. Parser `:error` remains an abstention, and divergence remains a successful response. In structured mode, a dispatch rejection terminally fails its token, resets the run, and advances the queue even if the voting threshold would still be reachable. Legacy dispatch behavior is preserved.

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
