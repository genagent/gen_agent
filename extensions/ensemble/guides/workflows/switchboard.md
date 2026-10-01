# Switchboard workflow

## Topology

One ensemble process owning N named sub-agents. The caller specifies
which agent should handle each prompt via `opts[:agent]`. No
coordination across agents, no decomposition, no default target.

```
                                +---------------+
                       +------> |   alice       |
                       |        +---------------+
   +-------+   +-------+----+   +---------------+
   |  E.*  |-->| Switchboard|-->|   bob         |
   +-------+   +-------+----+   +---------------+
    (agent: x)         |        +---------------+
                       +------> |   carol       |
                                +---------------+
```

## When to reach for it

- You have a fixed team of specialised agents and want to direct
  questions to specific members explicitly.
- The split is editorial: "ask Alice for API review, ask Bob for
  perf review." A human or an orchestrator picks the target.
- You want each agent to maintain its own long-running conversation
  (Switchboard does, same as Solo).

For parallel fan-out of homogeneous work, use Pool. For LLM-driven
decomposition, use Supervisor. For a single agent, use Solo.

## Config

```elixir
config :gen_agent_ensemble,
  ensembles: [
    [
      name: "reviewers",
      strategy: GenAgentEnsemble.Strategies.Switchboard,
      opts: [
        agents: [
          {"alice", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Anthropic,
            system: "You review API design. Be blunt about naming and shape.",
            model: "claude-sonnet-4-6"},
          {"bob", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Anthropic,
            system: "You review performance. Look for O(n^2), allocation, IO.",
            model: "claude-sonnet-4-6"},
          {"carol", GenAgentEnsemble.Agents.Simple,
            backend: GenAgent.Backends.Anthropic,
            system: "You review tests. Flag missing edge cases and weak assertions.",
            model: "claude-sonnet-4-6"}
        ]
      ]
    ]
  ]
```

Agent names must be unique within the ensemble. Switchboard
namespacing (via the Server) means the same sub-agent name can be
reused in a different ensemble without collision.

## Canonical workflow

### Route a single sync turn

```elixir
iex> E.ask!("reviewers", "is `/api/v2/users?archive=1` a good shape?", agent: "alice")
"Two issues with that URL..."

iex> E.ask!("reviewers", "this query runs n+1 -- how bad?", agent: "bob")
"Bad. Here's the fix..."
```

### Address all three in iex

```elixir
iex> code = File.read!("lib/some_module.ex")
iex> for reviewer <- ~w(alice bob carol) do
...>   {reviewer, E.ask!("reviewers", code, agent: reviewer, timeout: 60_000)}
...> end
```

Sequential because Elixir's `for` is. Each call blocks until its
agent responds, then the next one starts.

### Async parallel round

```elixir
iex> tokens =
...>   for reviewer <- ~w(alice bob carol) do
...>     {reviewer, elem(E.tell("reviewers", code, agent: reviewer), 1)}
...>   end

iex> E.status("reviewers")
{:ok, %{
  agents: ["alice", "bob", "carol"],
  pending_per_agent: %{"alice" => 1, "bob" => 1, "carol" => 1},
  ...
}}

iex> for {name, token} <- tokens do
...>   {name, E.await("reviewers", token, 60_000).text}
...> end
```

All three fire before any can complete -- real parallel fan-out
across the three backend sessions.

### Inspect

```elixir
iex> E.status("reviewers")
{:ok, %{
  session: "reviewers",
  strategy: GenAgentEnsemble.Strategies.Switchboard,
  agents: ["alice", "bob", "carol"],
  pending_per_agent: %{"alice" => 0, "bob" => 0, "carol" => 0},
  ...
}}
```

## Failure modes

| Error                              | Cause                                            |
|------------------------------------|--------------------------------------------------|
| `{:error, :no_agent_specified}`    | `tell`/`ask` called without `opts[:agent]`       |
| `{:error, {:unknown_agent, name}}` | `opts[:agent]` not in the fleet                  |
| `{:error, reason}`                 | The agent's turn errored (that agent only fails) |
| `{:error, {:agent_down, reason}}`  | An agent crashed mid-turn; queued tokens fail    |
| session halts                      | Last agent dies; session exits                   |

A single agent's trouble does not take down the fleet. When the
last agent dies, the whole ensemble halts with
`{:halt, :switchboard_exhausted}`.

## Variations

- **Mix agent types.** Each slot takes its own `module` -- one agent
  can be a Simple wrapper over Anthropic, another a custom
  GenAgent callback, another a Claude-CLI agent with a `cwd`.
- **Specialisation by system prompt.** Same model, different
  prompts gets you most of the benefit for most tasks.
- **External router.** Pair Switchboard with a separate "router"
  Solo that classifies the prompt and picks a target -- then
  forward with `E.ask!("reviewers", text, agent: chosen)`.

## Gotchas

- **No default target.** If you forget `agent:`, you get
  `{:error, :no_agent_specified}` immediately. Intentional -- it
  prevents silent misrouting. If you want a "primary" fallback,
  wrap with your own helper.
- **No broadcast (yet).** v1 routes to exactly one agent per call.
  Hitting all three is a `for` comprehension from the caller. A
  future `tell_all/2` might ship if demand appears.
- **Agent conversations accumulate.** Like Solo, each agent's
  backend session retains history across turns. Input tokens grow
  over time. Stop and re-start the ensemble to reset.
- **Ordering is per-agent FIFO.** Multiple tells to the same agent
  queue in order; their reply tokens come back in the same order.
  Tells to different agents run in parallel -- the order they
  *return* depends on backend latency, not dispatch order.
