# Consensus

`GenAgentEnsemble.Strategies.Consensus` asks two or more agents for
categorical verdicts on the same prompt. Each round dispatches in
parallel. A `:verdict_parser` converts each response to
`{:ok, verdict_atom, rationale}` or `:error`; unparseable responses
abstain. When the configured threshold agrees, the strategy replies
with a synthesis. At the round cap, it returns a divergence report.

```elixir
simple = GenAgentEnsemble.Agents.Simple
echo = GenAgentEnsemble.Backends.Echo

parse_verdict = fn text ->
  case String.split(String.replace_prefix(text, "echo: ", ""), ":", parts: 2) do
    ["APPROVE", rationale] -> {:ok, :approve, String.trim(rationale)}
    ["REVISE", rationale] -> {:ok, :revise, String.trim(rationale)}
    _ -> :error
  end
end

{:ok, _pid} =
  GenAgentEnsemble.start_link(
    name: "panel",
    strategy: GenAgentEnsemble.Strategies.Consensus,
    opts: [
      agents: [{"first", simple, backend: echo}, {"second", simple, backend: echo}],
      verdict_parser: parse_verdict,
      threshold: :unanimous,
      rounds: 2
    ]
  )

{:ok, response} = GenAgentEnsemble.ask("panel", "APPROVE: the example is sound")
```

Echo makes the parsing example deterministic. With real backends,
give each agent clear output instructions and make the parser strict:
prose that does not match the requested format should abstain instead
of being guessed into a decision. The available thresholds are
`:unanimous`, `:majority` (the default), and `{:at_least, n}`. The
strategy keeps each backend session across rounds and can pass other
agents' prior responses into a revision round. Its module
documentation defines the reply formats and failure behavior.
