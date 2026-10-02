# Consensus review loop

A reduced, keyless proposal review workflow. A drafter produces a change
proposal for a task. A panel of GenAgent reviewers uses Ensemble's Consensus
strategy to return a parsed `:approve` or `:revise` verdict with rationales.
On revision, the drafter receives the task, previous draft, and all reviewers'
rationales. Each run owns fresh agents and stops them when it returns,
including when a backend returns an error.

This example works on proposal text. It does not edit a git workspace or
persist conversations. Session resume and a persistent conversation store
are separate follow-up work.

## Run offline

With the scaffold's dependencies already fetched, run from this directory:

```sh
export MIX_OS_CONCURRENCY_LOCK=0
mix test
mix test
mix test
mix format --check-formatted
mix compile --warnings-as-errors
iex -S mix
```

In IEx, run a deterministic revision followed by approval:

```elixir
ConsensusReview.run("Add input validation",
  drafter: [script: ["Validate inputs", "Validate inputs and test invalid values"]],
  reviewers: [
    {"correctness", script: ["Add tests\nVERDICT: REVISE", "Covered\nVERDICT: APPROVE"]},
    {"usability", script: ["Explain errors\nVERDICT: REVISE", "Clear\nVERDICT: APPROVE"]}
  ]
)
```

The result is `{:ok, %{draft: final_text, history: entries, stopped: reason}}`.
History is chronological. Each entry contains the outer `:round`, parsed
`:verdict`, Consensus `:status`, number of internal `:consensus_rounds`, and
`:rationales` containing each reviewer's name, verdict, and rationale.
History and revision prompts use the supplied reviewer names. Ensemble
namespaces their registrations under a unique panel name to isolate runs.

Stop reasons are `:approved`, `:max_rounds` (still needs revision), and
`:no_consensus` (the panel diverged, with a `nil` verdict). Approval on the
last permitted round still counts as approval. Backend failures return
`{:error, reason}` instead of a completed result.

The `:timeout` option defaults to `:infinity` and controls each panel ask,
including all internal Consensus rounds. This matches the drafter's unlimited
call wait. A finite timeout is in milliseconds; expiry exits the caller rather
than returning `{:error, reason}`. Cleanup still stops the owned agents.
Backend watchdogs and provider timeouts remain independent of this call timeout.

## Consensus options

- `:agents`: at least two distinct reviewer names, each using
  `GenAgentEnsemble.Agents.Simple` with its own backend session.
- `:verdict_parser`: `ConsensusReview.parse_verdict/1` accepts a final line
  exactly matching `VERDICT: APPROVE` or `VERDICT: REVISE`. Preceding text is
  the rationale. Malformed replies abstain.
- `:threshold`: configurable through `run/2`, defaults to `:majority` (more
  than half the panel). `:unanimous` requires every reviewer, with no abstains.
  `{:at_least, n}` is also supported by Consensus.
- `:rounds`: supplied by `:consensus_rounds`, default 1. If reviewers disagree,
  Consensus can re-prompt them with peer responses up to this internal cap.
  Exhausting it stops the outer workflow with `:no_consensus`.
- `:reply`: `{:synthesize, fun}` encodes the structured Consensus summary as
  a Base64 Erlang term because `GenAgent.Response.text` must be a string.
  The loop decodes only this locally produced envelope using the safe term
  decoder. Reviewer text is never evaluated or decoded as a term.

The outer `:max_rounds` defaults to 3 and bounds draft/review cycles. It is
independent of Consensus's internal deliberation cap. Both caps must be
positive integers. Scripts need one drafter reply per outer round and one
reviewer reply per internal round actually used. Each script element can
also be a function receiving the prompt and returning text. Script exhaustion
returns `{:error, :script_exhausted}` for the drafter or
`{:error, {reviewer_name, :script_exhausted}}` for a reviewer, exposing
unexpected turns without sleeps or shared counters.

Tests cover first-round approval, revision with feedback then approval,
reaching the outer bound, internal divergence, abstention, and cleanup.

## Use real backends

Replace `script:` with provider options and set `backend:` on the drafter
and each reviewer. The Simple agent forwards these options to the backend.
For Anthropic, first add its integration to `deps/0` in this project's
`mix.exs` alongside the existing dependencies:

```elixir
{:gen_agent_anthropic, path: "../../integrations/anthropic"}
```

Fetch the added dependencies when network access is available, and set
`ANTHROPIC_API_KEY` in your environment before starting the application.
The keyless example does not need this dependency or credential.
Then use the authenticated backend:

```elixir
ConsensusReview.run("Propose input validation for the supplied module",
  drafter: [
    backend: GenAgent.Backends.Anthropic,
    system: "Produce a concrete change proposal. Incorporate review feedback."
  ],
  reviewers: [
    {"correctness",
     backend: GenAgent.Backends.Anthropic,
     system: "Review correctness. End with VERDICT: APPROVE or VERDICT: REVISE."},
    {"tests",
     backend: GenAgent.Backends.Anthropic,
     system: "Review test coverage. End with VERDICT: APPROVE or VERDICT: REVISE."}
  ],
  threshold: :unanimous,
  consensus_rounds: 2,
  max_rounds: 3
)
```

Configure provider credentials and model as required by the chosen backend.
Real backends require their normal provider access and are not deterministic.
Include the source or relevant context in the task when reviewing real code.
The outer loop supplies the verdict format in every review prompt as well.
