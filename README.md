# GenAgent

[![CI](https://github.com/genagent/gen_agent/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/gen_agent/actions/workflows/ci.yml)
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
    {:gen_agent, "~> 0.3.0"}, # x-release-please-version
    # Plus at least one backend:
    {:gen_agent_claude, "~> 0.1.0"},
    {:gen_agent_codex, "~> 0.1.0"},
    {:gen_agent_anthropic, "~> 0.1.0"},
    {:gen_agent_openai, "~> 0.1.0"}
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

## One interface for Claude and Codex

Use the same callback module and `GenAgent` API for both providers. Select
the backend when starting each agent:

`gen_agent` owns the agent process, prompt tasks, callbacks, and queue.
`gen_agent_claude` and `gen_agent_codex` implement the backend contract,
translate provider events, and retain each provider's session identifier.
Those backends call `claude_wrapper` and `codex_wrapper`, respectively;
the wrappers build CLI arguments, parse output, and select a runner for
the external process. Add both backend packages to one application when
agents need both CLIs. Select a backend per agent, then use the same
`GenAgent.ask/3`, `tell/3`, `poll/3`, and interruption APIs for either.

```elixir
defmodule MyApp.Assistant do
  use GenAgent

  @impl true
  def init_agent(opts) do
    {:ok, [cwd: Keyword.fetch!(opts, :cwd)], %{}}
  end

  @impl true
  def handle_response(_ref, _response, state), do: {:noreply, state}
end

for {name, backend} <- [
      {"claude", GenAgent.Backends.Claude},
      {"codex", GenAgent.Backends.Codex}
    ] do
  {:ok, _pid} = GenAgent.start_agent(MyApp.Assistant,
    name: name, backend: backend, cwd: "/path/to/project"
  )
end

{:ok, response} = GenAgent.ask("claude", "Explain this project")
{:ok, ref} = GenAgent.tell("codex", "Explain this project")
GenAgent.poll("codex", ref) # {:ok, :pending} while queued or running
```

Either agent supports `ask`, `tell`, and `poll`; the interaction style is
independent of the provider. Install both backend packages and configure
their CLIs before starting them. Backend-specific options and capabilities
can differ: return the appropriate options from `init_agent/1` when adding
model settings, instructions, or permissions. Each agent keeps its own
provider session.

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
- **Halting** -- `handle_response/3`, `handle_error/3`, `handle_event/2`,
  or `pre_turn/2` can return `{:halt, state}` to go idle but freeze the
  mailbox. A halted agent ignores queued prompts until `GenAgent.resume/1`
  is called.
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
| `post_run/1` | On clean `{:halt, state}` from a decision callback or `pre_turn/2` | Completion actions: open a PR, post a summary |

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
| OpenAI HTTP | `gen_agent_openai` | Responses API via `req` |

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
| `tell_with_completion/4` | Async prompt with a request-scoped completion message. |
| `poll/3` | Check on a previously-issued `tell/3`. |
| `notify/2` | Push an external event into `handle_event/2`. |
| `notify_ack/3` | Wait for an in-memory notification admission result. |
| `interrupt/1` | Cancel an in-flight turn. |
| `interrupt_request/3` | Acknowledge cancellation only if the active request ref matches. |
| `resume/1` | Unhalt an agent and drain its mailbox. |
| `status/2` | Read the agent's current state. |
| `runtime_snapshot/2` | Read bounded runtime metadata and pending-input counts. |
| `stop/1` | Terminate the agent. |
| `child_spec/2` | Build an agent child spec for a caller-owned supervisor. |
| `stop/2` | Terminate an agent under a caller-owned supervisor. |
| `whereis/1` | Look up an agent's pid. |

Names resolve through a `Registry`, so callers address agents by name
(any term). Agents use `restart: :temporary`: a crashed or stopped agent
must be started explicitly, and its previous state is not restored.

`runtime_snapshot/2` reports the coordinator's current phase, halted
flag, queued prompt and buffered notification counts, pending self-chain,
and active request ref, origin and elapsed/watchdog time. It contains no
prompt, callback state, backend session or event payload. It is a
point-in-time observation, not durable state or permission to dispatch.
The older `status/2` API remains available; its `agent_state` is the
server's latest retained state, not a live read of an in-flight task.

## Request completion messages

Use `tell_with_completion/4` when a caller needs the exact request ref
and an asynchronous terminal outcome:

```elixir
{:ok, ref} = GenAgent.tell_with_completion("my-coder", "Run the tests")

receive do
  {:gen_agent, :completion, "my-coder", ^ref, {:ok, response}} ->
    IO.puts(response.text)

  {:gen_agent, :completion, "my-coder", ^ref, {:error, reason}} ->
    IO.inspect(reason)
end
```

The optional third argument selects a recipient pid; it defaults to the
caller. The agent registers that recipient when it accepts the request,
so a fast response or `pre_turn/2` skip can send the completion before
the call returns. Match on the ref, which also works with
`interrupt_request/3`. Pending-queue overload returns an error without
a ref or completion message. Accepted queued requests deliver after
their turn; backend errors, gate skip/halt/invalid, interruption, and
watchdog expiry deliver error outcomes. The message is sent after turn
decision and `post_turn/3` callbacks, at most once for each accepted
request. Existing `tell/3` and `poll/3` behavior stays unchanged.

Delivery does not depend on the bounded poll-result cache. It is an
in-memory BEAM send, not durable delivery: a dead recipient loses its
message, and agent death before a terminal outcome leaves the request
uncertain. Monitor the agent if its death matters; a replacement under
the same name uses new refs. A crashing decision callback stops the
agent before completion. Neither a completion nor an agent monitor
proves that an external provider process has settled.

## Pending input bounds

Each agent admits at most 1,000 pending prompts and 1,000 deferred
notifications by default, with a separate 1,048,576-byte payload cap
for each queue. Configure `:max_pending_prompts`,
`:max_pending_prompt_bytes`, `:max_pending_notifications`, and
`:max_pending_notification_bytes` in `start_agent/2` or `child_spec/2`.
Values must be non-negative integers; zero disables the corresponding
pending queue. Byte use is the sum of `:erlang.external_size/1` for
queued prompt strings or event terms. The active prompt and events
handled immediately while idle are outside these pending caps.

`ask/3` and `tell/3` return `{:error, {:overloaded, info}}` before
acceptance when a pending prompt does not fit. A rejected `tell/3`
returns no pollable ref. `info` identifies the queue, count or byte
limit, current count and bytes, incoming bytes, and configured maxima.
`notify_ack/3` returns `:ok` after the event is handled or retained, or
the same typed overload error if admission fails. It acknowledges
in-memory processing, not durable delivery. Existing `notify/2` is a
best-effort cast: its immediate `:ok` does not mean the event fit. Use
the rejection telemetry event to observe cast overloads.

Deferred event callbacks may generate prompts when a turn finishes.
Those prompts use the bounded pending-prompt queue; on overload,
`handle_error/3` receives the reason. Self-chain prompts from
`handle_response/3` or `handle_error/3` use one reserved slot outside
the prompt count cap, but must fit the prompt byte cap. A halted agent
retains admitted work until `resume/1`; interruption or completion
releases queue capacity as work is drained. These limits bound accepted
internal storage, not arbitrary messages already waiting in the BEAM
process mailbox before admission is processed. Stream-output capture
and external provider cancellation have their own contracts.

## Event capture bounds

Successful responses contain a complete normalized event list. To keep
that list and cached `tell/3` results bounded, each turn retains at most
1,000 events and 1,048,576 bytes of event terms by default. Override
these positive-integer limits with `:max_events_per_turn` and
`:max_event_bytes_per_turn` in `start_agent/2` or `child_spec/2`. Byte
usage is the sum of `:erlang.external_size/1` for accepted events, so a
single oversized terminal event is rejected too.

An event that exceeds either limit ends the turn with
`{:error, {:event_capture_overflow, diagnostics}}`. The diagnostics
contain the limit type, configured limits, retained counts/bytes, and
the rejected event's kind and size, but no event payload. There is no
truncated success response. Stream callbacks run for accepted events;
the rejected event is not passed to `handle_stream_event/2`. A terminal
`:error` reason is preserved when that event fits; if its event exceeds
the limit, the overflow diagnostic records its kind without retaining
its potentially oversized reason. The stream enumerable is halted, but
settlement of provider subprocesses or remote work remains the backend's
responsibility.

## Supervision

The package starts a fixed supervision tree on application boot:

```
GenAgent.Supervisor
  GenAgent.Registry          (Registry, keys: :unique)
  GenAgent.TaskSupervisor    (Task.Supervisor)
  GenAgent.AgentSupervisor   (DynamicSupervisor)
    <your agents under here>
```

To own agent and prompt-task lifetimes in your application, start a
`Task.Supervisor` before a `DynamicSupervisor` in your supervision tree:

```elixir
children = [
  {Task.Supervisor, name: MyApp.AgentTasks},
  {DynamicSupervisor, name: MyApp.Agents, strategy: :one_for_one}
]

{:ok, _owner} = Supervisor.start_link(children, strategy: :rest_for_one)

spec =
  GenAgent.child_spec(MyAgent,
    name: "worker-1",
    backend: MyBackend,
    task_supervisor: MyApp.AgentTasks
  )

{:ok, _agent} = DynamicSupervisor.start_child(MyApp.Agents, spec)
{:ok, response} = GenAgent.ask("worker-1", "Hello")
:ok = GenAgent.stop("worker-1", MyApp.Agents)
```

`child_spec/2` requires an explicit, running task supervisor; it never
silently uses the global one. Both globally and caller-owned agents use
`GenAgent.Registry`, so names must be unique across them and normal
name-based calls work for either. `stop/1` targets only the global agent
supervisor; pass the caller's `DynamicSupervisor` to `stop/2`.
The agent child is temporary and is never automatically replayed after
a crash. With `:rest_for_one`, failure of the task supervisor also stops
the agent supervisor. On ordinary shutdown, the agent supervisor stops
first so its agents can cancel in-flight tasks while their task supervisor
is still running. An application must reconstruct state and consumed work
from its own durable records; supervision alone does not provide recovery.

Each prompt turn runs as a Task under its selected `Task.Supervisor`. A
crashed task delivers `:DOWN` to the owning agent, which turns it into an
`{:error, {:task_crashed, reason}}` response for the caller -- it does not
take down the agent process.

The prompt task belongs to its agent: it is stopped when the agent exits,
including abrupt exits that bypass termination callbacks. Interruption and
the watchdog also stop the active prompt task. Stopping a BEAM task does
not establish that a provider's subprocess or remote request has stopped;
external cancellation and resource cleanup belong to the backend and its
transport.

## Patterns

Eleven common topologies are documented as ex_doc guides shipped with
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
- **[Heartbeat][hb]** -- periodic agent driven by timer events
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
[hb]: https://hexdocs.pm/gen_agent/heartbeat.html
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
[:gen_agent, :input, :rejected]  # %{agent, reason: {:overloaded, info}}
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
