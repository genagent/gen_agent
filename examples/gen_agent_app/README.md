# GenAgent application example

This local Mix application is a small composition test for a future
`gen_agent_app`. Its own `Application` starts a named Switchboard session and
exposes one API for whichever agents are configured. The default Echo backend
lets you run it without a CLI login or API key.

```sh
cd examples/gen_agent_app
mix deps.get
mix test
iex -S mix
```

```elixir
iex> GenAgentApp.agents()
{:ok, ["echo"]}
iex> {:ok, response} = GenAgentApp.ask("echo", "hello")
iex> response.text
"echo: hello"
iex> {:ok, token} = GenAgentApp.tell("echo", "later")
iex> GenAgentApp.poll(token)
```

To use locally authenticated Claude and Codex CLI backends in the same
running application, point them at a working directory and start IEx:

```sh
GEN_AGENT_APP_PROVIDERS=claude,codex \
GEN_AGENT_APP_CWD=/path/to/project \
iex -S mix
```

```elixir
iex> GenAgentApp.agents()
{:ok, ["claude", "codex"]}
iex> GenAgentApp.ask("claude", "Summarize this project")
iex> GenAgentApp.ask("codex", "Find the test entry points")
```

The CLI backends keep separate provider sessions. They use their normal
project instruction mechanisms, including `CLAUDE.md` and `AGENTS.md` where
applicable. This example supplies no agent persona or workflow. To embed it
in another Elixir application, configure `:gen_agent_app` with a session name
and `{name, callback_module, backend_options}` specs, then depend on the
components that those specs use.

This is a single-instance, process-local example. A completed `poll/1` removes
that result, and `inbox/0` drains all completed results. Tokens and results
disappear when the application restarts. Those semantics are useful for one
local caller, but are not a shared result API for multiple clients.

This proves the **application** boundary: configured agents, supervision, and
one local control API. A future `gen_agent_server` can package that app as a
standalone release with configuration, a CLI, and optional dashboard. An MCP
adapter can live in this repository and expose an allowlisted, instance-scoped
control API using [Snodo](https://github.com/joshrotenberg/snodo) for protocol
and transport. Before sharing it across a CLI, MCP clients, and a dashboard,
the host needs non-destructive result reads, explicit invocation lifecycle and
expiry, and a clear cancellation contract. MCP does not need to own agent
lifecycle or behavior.
