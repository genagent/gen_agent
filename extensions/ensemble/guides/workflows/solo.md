# Solo workflow

## Topology

One ensemble process owning one sub-agent owning one backend
session. The simplest useful ensemble.

```
+-------+    +---------+    +----------+
|  E.*  | -> |  Solo   | -> |  agent   | -> backend
+-------+    +---------+    +----------+
```

## When to reach for it

- You want a single LLM session you can talk to by name.
- You want the conversation history to persist across turns.
- You're prototyping before adding coordination.
- You have a "REPL-for-task-X" shape: "ask the Elixir reviewer",
  "ask the docs writer", "ask the SQL coach".

For anything with concurrency or multi-stage logic, reach for Pool,
Pipeline, or Supervisor instead.

## Config

```elixir
config :gen_agent_ensemble,
  ensembles: [
    [
      name: "solo",
      strategy: GenAgentEnsemble.Strategies.Solo,
      opts: [
        agent:
          {"w", GenAgentEnsemble.Agents.Simple,
           backend: GenAgent.Backends.Anthropic,
           system: "You are a pragmatic Elixir reviewer.",
           model: "claude-sonnet-4-6"}
      ]
    ]
  ]
```

## Canonical workflow

### One-shot synchronous turn

```elixir
iex> E.ask!("solo", "what's wrong with Enum.map(list, &(&1 + 1))?")
"Nothing -- that's idiomatic Elixir..."

iex> E.ask!("solo", "now rewrite that as a Stream pipeline")
"Stream.map(list, &(&1 + 1)) |> Enum.to_list()"
```

The second call sees the first as conversation history. Token usage
grows each turn because the backend resends the full message array.

### Async (fire-and-check-later)

```elixir
iex> {:ok, token} = E.tell("solo", "explain ETS in one paragraph")
{:ok, "tok-5"}
iex> # ...do other work...
iex> E.await("solo", token) |> E.puts()
ETS (Erlang Term Storage) is an in-memory key-value store...
:ok
```

### Inspect

```elixir
iex> E.status("solo")
{:ok, %{
  session: "solo",
  strategy: GenAgentEnsemble.Strategies.Solo,
  agent: "w",
  queued_tokens: 0,
  agents: ["w"],
  in_flight: 0,
  pending_tokens: []
}}
```

## Variations

- **Swap backends.** Change `backend:` to any `GenAgent.Backend`
  implementation (`Anthropic`, `Claude`, `OpenAI`, `Codex`,
  `GenAgentEnsemble.Backends.Echo`, your own).
- **Pass cwd for file-aware backends.** Claude CLI honours `:cwd`:

  ```elixir
  agent:
    {"w", GenAgentEnsemble.Agents.Simple,
     backend: GenAgent.Backends.Claude,
     cwd: "/path/to/project",
     permission_mode: :plan,
     system_prompt: "You are a code reviewer."}
  ```

- **Custom callback module.** Replace `GenAgentEnsemble.Agents.Simple`
  with your own `use GenAgent` module when you want richer state or
  prompt-engineered behaviour between turns.

## Gotchas

- **Conversation accumulates.** Each turn's input-token count grows
  because the full history is replayed to the backend. Stop and
  restart the ensemble to reset the session. (`E.stop("solo")`
  followed by re-declaring in config or `E.start_link/1` for ad hoc.)
- **One in-flight turn at a time.** A second `tell` while a turn is
  processing is queued in `GenAgent`'s mailbox and runs after the
  first completes, not in parallel. Use Pool if you want parallelism.
