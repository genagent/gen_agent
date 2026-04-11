# Patterns

`GenAgent` is a behaviour, not a framework. It gives you a state
machine, a backend abstraction, and lifecycle hooks, and then gets
out of your way. This guide collects the common topologies people
actually build on top of it -- how a human drives a single session,
how agents work autonomously, how multiple agents cooperate, how
failures are recovered, and so on -- as complete worked examples.

Each pattern on this page is a self-contained callback module (plus
a small manager-facing facade in some cases) that you can read,
adapt, and drop into your own application. They are **not** shipped
as public API modules -- there's no `deps.get` step and no stable
module names to match against. They're reference implementations.
Copy the parts you need, simplify what you don't, and let the rest
age out.

The patterns are backend-independent. Everything demonstrated here
works against any `GenAgent.Backend` implementation, and we test
them in the playground against a mix of Claude, Codex, Anthropic
HTTP, and the in-memory Mock backend.

## Patterns at a glance

| Pattern                         | Topology                                  | Key gen_agent features                                   |
|---------------------------------|-------------------------------------------|----------------------------------------------------------|
| [Switchboard](switchboard.md)   | Human-managed named fleet                 | `tell`/`poll`, `notify`, inbox cursor, telemetry         |
| [Research](research.md)         | Autonomous self-chain (1 agent)           | `{:prompt, ..., state}` state machine, `handle_error`    |
| [Debate](debate.md)             | Two agents, cross-agent `notify`          | Cross-agent notify, `handle_event` -> prompt, mutual halt|
| [Pipeline](pipeline.md)         | Linear stage chain                        | One-way notify chain, per-stage self-halt                |
| [Supervisor](supervisor.md)     | Coordinator + dynamic worker pool         | `start_agent/2` from inside a callback, fan-out/fan-in   |
| [Pool](pool.md)                 | Reusable worker pool, round-robin         | Multi-turn workers, `tell/2` mailbox queueing            |
| [Watcher](watcher.md)           | Reactive event-driven agent               | `handle_event` filtering, idle-until-triggered           |
| [Checkpointer](checkpointer.md) | Human-in-the-loop review workflow         | Idle-with-phase-marker pause primitive                   |
| [Retry](retry.md)               | `handle_error` self-chain retry loop      | `handle_error` returning `{:prompt, ..., state}`         |
| [Workspace](workspace.md)       | Single agent + temp git workspace         | All four v0.2 lifecycle hooks                            |

## Choosing a pattern

Most real agents end up being a combination, not a pure instance of
one of these. A rough decision tree:

- **You want a human driving one or more long-lived sessions from
  iex or an MCP client.** Start with **[Switchboard](switchboard.md)**.
  It's the thinnest layer on top of `GenAgent` and matches the
  "manager is the interface" model.

- **One agent needs to walk itself through several phases of work
  without human input.** Start with **[Research](research.md)**. The
  self-chain via `{:prompt, ..., state}` is the whole move.

- **Work has to flow through a fixed sequence of distinct agents,
  each with its own role.** Start with **[Pipeline](pipeline.md)**.

- **One coordinator needs to fan work out to N variable workers and
  collect the results.** Start with **[Supervisor](supervisor.md)**
  if workers are one-shot, or **[Pool](pool.md)** if they're
  long-lived and round-robin dispatched.

- **Two agents with opposing roles need to push each other forward.**
  Use **[Debate](debate.md)**. Cross-agent `notify` is the primitive.

- **An agent should sit idle until events arrive (CI failures, file
  changes, webhooks).** Start with **[Watcher](watcher.md)**.

- **An agent should do something, then pause for human review, then
  continue based on the review decision.** Start with
  **[Checkpointer](checkpointer.md)**. The key move is
  idle-with-phase-marker rather than `{:halt, state}` -- halt is
  terminal, idle is resumable.

- **Transient failures need to trigger retries with backoff, and
  you want the retry decision to live on agent state.** Start with
  **[Retry](retry.md)**.

- **Every turn needs to run against an isolated git worktree, with
  per-turn commits and a completion hook.** Start with
  **[Workspace](workspace.md)**. This is also the best full example
  of gen_agent v0.2 lifecycle hooks in action.

## What these patterns are NOT

- **Not a cookbook you install as a dependency.** Each page is code
  you read and copy. If you want a library layer on top of
  `GenAgent`, build it in your own application with whatever
  opinionation you need.

- **Not exhaustive.** The shapes that are here are the ones that
  came up naturally while dogfooding `GenAgent` against real
  backends. If you find yourself building a topology that isn't
  here, it's not missing on purpose -- it just hasn't been needed
  yet.

- **Not opinionated about prompts.** All example prompts are
  deliberately short. Real agents have real prompt engineering
  inside them, and we assume you'll write your own.
