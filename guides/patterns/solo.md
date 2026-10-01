# Solo

`GenAgentEnsemble.Strategies.Solo` gives one `GenAgent` process the
same `ask`, `tell`, `poll`, and `inbox` interface as multi-agent
strategies. It is useful when an application may change its topology
later but wants one session API now.

```elixir
simple = GenAgentEnsemble.Agents.Simple
echo = GenAgentEnsemble.Backends.Echo

{:ok, _pid} =
  GenAgentEnsemble.start_link(
    name: "assistant",
    strategy: GenAgentEnsemble.Strategies.Solo,
    opts: [agent: {"worker", simple, backend: echo}]
  )

{:ok, response} = GenAgentEnsemble.ask("assistant", "hello")
# response.text == "echo: hello"
```

The strategy forwards each prompt to the one agent and returns its
response. Multiple submitted turns queue through that agent's
mailbox; a turn error fails its token, and agent-process death halts
the session. Replace Echo with a backend appropriate to the task and
configure its options in the agent spec.
