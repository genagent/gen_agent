# Patterns

`GenAgent` gives each agent an OTP process, a backend, and lifecycle
callbacks. The patterns in this guide cover two ways to build on it:
shipped strategies in
[`gen_agent_ensemble`](https://hex.pm/packages/gen_agent_ensemble),
and callback-level reference implementations you can adapt in your own
application.

The copyable callback modules are compiled in the core test suite, and
guide-level tests exercise their behavior with local stub backends. They
do not require a Claude or Codex account to run.

An Ensemble session owns its sub-agents under one strategy. Add
`{:gen_agent_ensemble, "~> 0.7"}` to your dependencies and start a
session with `GenAgentEnsemble.start_link(name: ..., strategy: ...,
opts: ...)`. Submit with `ask` for a synchronous result or `tell`
followed by `poll` or `inbox`. An agent spec chooses its callback module
and backend options, so one session can use different backends for
different roles. The separate
[`gen_agent_server`](https://github.com/genagent/gen_agent_server)
application adds named instances, bounded result retention, CLI access,
and optional scheduling around these strategies.

## Shipped Ensemble strategies

| Strategy | Shape | When it fits |
| --- | --- | --- |
| [`Solo`](https://hexdocs.pm/gen_agent_ensemble/GenAgentEnsemble.Strategies.Solo.html) | One agent | A single session behind the Ensemble API. |
| [`Switchboard`](https://hexdocs.pm/gen_agent_ensemble/GenAgentEnsemble.Strategies.Switchboard.html) | Caller-routed named agents | A human or client chooses `agent:` on each call. |
| [`Pipeline`](https://hexdocs.pm/gen_agent_ensemble/GenAgentEnsemble.Strategies.Pipeline.html) | Ordered stages | Each stage's response text becomes the next prompt. |
| [`Supervisor`](https://hexdocs.pm/gen_agent_ensemble/GenAgentEnsemble.Strategies.Supervisor.html) | Coordinator and temporary workers | Decompose one request, run independent sub-tasks, collect replies. |
| [`Pool`](https://hexdocs.pm/gen_agent_ensemble/GenAgentEnsemble.Strategies.Pool.html) | Fixed reusable workers | Dispatch to the next free worker; queue requests FIFO when all are busy. |
| [`Debate`](https://hexdocs.pm/gen_agent_ensemble/GenAgentEnsemble.Strategies.Debate.html) | Two alternating agents | Continue until a convergence rule or round cap ends the exchange. |
| [`Consensus`](https://hexdocs.pm/gen_agent_ensemble/GenAgentEnsemble.Strategies.Consensus.html) | N agents with parsed verdicts | Compare decisions against a threshold and report divergence at the round cap. |

Each strategy's module documentation and the Ensemble workflow guides give
its exact options and failure semantics.

## Single-agent callback patterns

These pages show shapes within one agent process. Read and adapt the
callback module rather than expecting an installable strategy:

When adapting a callback example, make the options returned by
`init_agent/1` match the selected backend. Examples that return `:system`
or `:max_tokens` need different options for the Codex backend; see its
[backend options](../../integrations/codex/README.md#backend-options).

| Pattern | Use |
| --- | --- |
| [Research](research.md) | Self-chain through phases with `{:prompt, ..., state}`. |
| [Watcher](watcher.md) | Wait for an event and decide whether it starts a turn. |
| [Heartbeat](heartbeat.md) | React to periodic tick events. |
| [Checkpointer](checkpointer.md) | Pause for human input while remaining resumable. |
| [Retry](retry.md) | Decide on retry and backoff in agent state. |
| [Workspace](workspace.md) | Run turns in isolated Git workspaces with lifecycle hooks. |

## Choosing a pattern

Use **Switchboard** when the caller knows which named agent should
receive each request. Use **Pipeline** when roles have a fixed order,
and **Supervisor** when one request can be decomposed into temporary,
independent workers. Use **Pool** for a stream of independent requests
that should reuse a bounded set of workers. **Debate** and **Consensus**
add explicit convergence rules; the latter parses categorical verdicts
from two or more agents.

Use a callback pattern for behavior inside one agent: **Research** for
self-directed phases, **Watcher** or **Heartbeat** for event-driven
work, **Checkpointer** for a human pause, **Retry** for recovery, and
**Workspace** for per-turn isolation. These shapes can also be used as
sub-agents within an Ensemble strategy.

All examples use short prompts so the process and handoff remain clear.
Write task-specific instructions and verify claims against their source
when using a real backend.
