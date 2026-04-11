# GenAgent

[![CI](https://github.com/joshrotenberg/gen_agent/actions/workflows/ci.yml/badge.svg)](https://github.com/joshrotenberg/gen_agent/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/gen_agent.svg)](https://hex.pm/packages/gen_agent)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/gen_agent)

A behaviour and supervision framework for long-running LLM agent processes,
modeled as OTP state machines.

Each agent is a `:gen_statem` process wrapping a persistent LLM session.
Every interaction is a prompt-response turn, and the implementation decides
what happens between turns.

> It is a GenServer but every call is a prompt.

GenAgent handles the mechanics of turns. Implementations handle the
semantics of turns.

## Installation

```elixir
def deps do
  [
    {:gen_agent, "~> 0.2.0"},
    # Plus at least one backend:
    {:gen_agent_claude, "~> 0.1.0"},
    {:gen_agent_codex, "~> 0.1.0"},
    {:gen_agent_anthropic, "~> 0.1.0"}
  ]
end
```

## Quick start

Define an implementation module by using the `GenAgent` behaviour:

```elixir
defmodule MyApp.Coder do
  use GenAgent

  defmodule State do
    defstruct [:path, responses: []]
  end

  @impl true
  def init_agent(opts) do
    path = Keyword.fetch!(opts, :cwd)

    backend_opts = [
      cwd: path,
      system_prompt: "You are a coding assistant."
    ]

    {:ok, backend_opts, %State{path: path}}
  end

  @impl true
  def handle_response(_ref, response, state) do
    {:noreply, %{state | responses: state.responses ++ [response.text]}}
  end
end
```

Start the agent under the supervision tree and interact with it by name:

```elixir
{:ok, _pid} = GenAgent.start_agent(MyApp.Coder,
  name: "my-coder",
  backend: GenAgent.Backends.Claude,
  cwd: "/path/to/project"
)

# Synchronous prompt.
{:ok, response} = GenAgent.ask("my-coder", "What does lib/foo.ex do?")
IO.puts(response.text)

# Async prompt.
{:ok, ref} = GenAgent.tell("my-coder", "Add tests for lib/foo.ex")
{:ok, :completed, response} = GenAgent.poll("my-coder", ref)

# Push an external event into handle_event/2.
GenAgent.notify("my-coder", {:ci_failed, "test_auth"})

GenAgent.stop("my-coder")
```

## State model

An agent is a state machine with two states:

```
idle --- ask/tell/notify ---> processing
                                  |
                                  v
idle <--- handle_response --- processing (turn done)
```

- **:idle** -- waiting for work. On enter, drains the mailbox (queued
  prompts) in FIFO order.
- **:processing** -- a prompt is in flight. One at a time. New prompts
  queue.
- **Self-chaining** -- `handle_response/3` can return `{:prompt, text, state}`
  to immediately dispatch another turn without going through the mailbox.
  Useful for multi-step work that the agent drives itself.
- **Halting** -- any callback can return `{:halt, state}` to go idle but
  freeze the mailbox. A halted agent ignores queued prompts until
  `GenAgent.resume/1` is called.
- **Watchdog** -- a `:state_timeout` kills any turn that runs longer than
  the configured deadline (default 10 minutes). Configurable per agent.

## Lifecycle hooks

In addition to the core callbacks, v0.2 adds four optional lifecycle
hooks for fine-grained control over what happens around each turn and
around the agent's full run:

| Hook | When it fires | Typical use |
|---|---|---|
| `pre_run/1` | Once, after `init_agent/1`, before the first turn | Slow async setup: clone a repo, create a worktree, fetch secrets |
| `pre_turn/2` | Before each prompt dispatch | Prompt augmentation, rate limiting, `:skip`/`:halt` as a gate |
| `post_turn/3` | After each turn, post-decision | State-mutating side effects: commit per turn, record usage |
| `post_run/1` | On clean `{:halt, state}` from any callback | Completion actions: open a PR, post a summary |

All four are optional with default no-op implementations. The guiding
principle is **telemetry first, callbacks for state mutation** --
observational use cases (log tokens, emit metrics) should use the
existing telemetry events; callbacks exist specifically for hooks that
need to mutate `agent_state` or block the next transition.

See the [Workspace pattern guide][workspace-guide] for a complete
example exercising all four hooks in sequence around a git workspace.

[workspace-guide]: https://hexdocs.pm/gen_agent/workspace.html

## Backends

GenAgent ships with a `GenAgent.Backend` behaviour and no built-in backend.
Pick one of the sibling packages or write your own:

| Backend | Package | Transport |
|---|---|---|
| Claude (Anthropic) | `gen_agent_claude` | `claude` CLI via `claude_wrapper` |
| Codex (OpenAI) | `gen_agent_codex` | `codex` CLI via `codex_wrapper` |
| Anthropic HTTP | `gen_agent_anthropic` | direct HTTP API via `req` |

A backend owns its session lifecycle, translates the LLM-specific event
stream into the normalized `GenAgent.Event` values the state machine
consumes, and carries any state it needs (session id, message history) in
an opaque session term.

The contract is deliberately small: five callbacks
(`start_session/1`, `prompt/2`, `update_session/2`, `resume_session/2`,
`terminate_session/1`), of which two are optional. See `GenAgent.Backend`
for details.

## Public API

| Function | What it does |
|---|---|
| `start_agent/2` | Start an agent under the supervision tree. |
| `ask/3` | Synchronous prompt. Blocks until the turn finishes. |
| `tell/3` | Async prompt. Returns a ref for `poll/3`. |
| `poll/3` | Check on a previously-issued `tell/3`. |
| `notify/2` | Push an external event into `handle_event/2`. |
| `interrupt/1` | Cancel an in-flight turn. |
| `resume/1` | Unhalt an agent and drain its mailbox. |
| `status/2` | Read the agent's current state. |
| `stop/1` | Terminate the agent. |
| `whereis/1` | Look up an agent's pid. |

Names resolve through a `Registry`. Callers hold names (any term), never
pids, so agents can be restarted without breaking callers.

## Supervision

The package starts a fixed supervision tree on application boot:

```
GenAgent.Supervisor
  GenAgent.Registry          (Registry, keys: :unique)
  GenAgent.TaskSupervisor    (Task.Supervisor)
  GenAgent.AgentSupervisor   (DynamicSupervisor)
    <your agents under here>
```

Each prompt turn runs as a Task under the shared `TaskSupervisor`. A
crashed task delivers `:DOWN` to the owning agent, which turns it into an
`{:error, {:task_crashed, reason}}` response for the caller -- it does not
take down the agent process.

## Patterns

Ten common topologies are documented as ex_doc guides shipped with
the package. Each guide is a complete worked example you can read,
copy, and adapt -- they are **not** installed as public API modules:

- **[Switchboard][sb]** -- human-managed named agent fleet with
  non-blocking send/poll/inbox, the base for manager-driven UIs
- **[Research][rs]** -- one agent self-chaining through phases
- **[Debate][db]** -- two agents pushing each other via cross-notify
- **[Pipeline][pl]** -- linear stage chain, one-way notify
- **[Supervisor][sv]** -- coordinator + dynamic workers (fan-out/in)
- **[Pool][pool]** -- reusable worker pool with round-robin dispatch
- **[Watcher][wc]** -- reactive event-driven agent, idle until triggered
- **[Checkpointer][cp]** -- human-in-the-loop review workflow
- **[Retry][rt]** -- handle_error self-chain for transient failures
- **[Workspace][ws]** -- all four lifecycle hooks around a git workspace

Start with the [patterns overview][overview] for a "choose your
pattern" decision tree.

[overview]: https://hexdocs.pm/gen_agent/overview.html
[sb]: https://hexdocs.pm/gen_agent/switchboard.html
[rs]: https://hexdocs.pm/gen_agent/research.html
[db]: https://hexdocs.pm/gen_agent/debate.html
[pl]: https://hexdocs.pm/gen_agent/pipeline.html
[sv]: https://hexdocs.pm/gen_agent/supervisor.html
[pool]: https://hexdocs.pm/gen_agent/pool.html
[wc]: https://hexdocs.pm/gen_agent/watcher.html
[cp]: https://hexdocs.pm/gen_agent/checkpointer.html
[rt]: https://hexdocs.pm/gen_agent/retry.html
[ws]: https://hexdocs.pm/gen_agent/workspace.html

## Telemetry

GenAgent emits telemetry events for observability:

```
[:gen_agent, :prompt, :start]    # %{agent, ref}
[:gen_agent, :prompt, :stop]     # %{agent, ref, duration}
[:gen_agent, :prompt, :error]    # %{agent, ref, reason}
[:gen_agent, :event, :received]  # %{agent, event}
[:gen_agent, :state, :changed]   # %{agent, from, to}
[:gen_agent, :mailbox, :queued]  # %{agent, depth}
[:gen_agent, :halted]            # %{agent}
```

Enough to build a communication graph, track latency, alert on stuck
agents. Attach handlers with `:telemetry.attach/4`.

## What GenAgent does not do

- **Prescribe agent behavior.** No retry logic, no STATUS line conventions,
  no summary format. That is all implementation concern.
- **Prescribe inter-agent communication.** Agents can `notify/2` each other
  by name, but the message format is up to you.
- **Manage persistence.** If you want to persist agent state across
  restarts, do it in `terminate_agent/2` and `init_agent/1`.
- **Manage pools.** One agent = one session = one process. If you want a
  pool, start multiple and route to them.
- **Track costs or budgets.** Usage data is in `GenAgent.Response.usage`.
  Do what you want with it.

## Testing

```bash
mix test
mix format --check-formatted
mix credo --strict
mix dialyzer
```

The test suite uses an in-process `GenAgent.Backends.Mock` (in
`test/support/`) that lets you script backend responses without any
external process. See `test/gen_agent/server_test.exs` for examples.

## License

MIT. See [LICENSE](LICENSE).
