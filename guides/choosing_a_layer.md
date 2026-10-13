# Choosing a layer

You can run Claude or Codex from Elixir at three levels. Pick the layer that
owns the lifecycle you need; you do not have to install all three.

| Start with | What you gain | What you own | Best fit |
| --- | --- | --- | --- |
| [`claude_wrapper`](https://github.com/genagent/claude_wrapper_ex) or [`codex_wrapper`](https://github.com/genagent/codex_wrapper_ex) | Direct CLI options, typed results, streaming, and provider-specific session controls | Scheduling, concurrency, retries, and any durable record of work | A script, a single turn, or an application with its own orchestration |
| `gen_agent` plus a [CLI backend](backends.md) | Named OTP agents, serialized turns, callbacks, supervision, events, and one interaction API for either provider | The agent's business logic, deployment, and persistence across process loss | An interactive or long-running agent inside a BEAM application |
| [`oban_claude`](https://github.com/genagent/oban_claude) or [`oban_codex`](https://github.com/genagent/oban_codex) | Provider-specific workers backed by Oban's persisted jobs, queues, retries, and scheduling | Oban setup, retry policy for side effects, and conversation state beyond each job | Background or scheduled turns that must survive a worker restart |

Both the GenAgent CLI backends and the Oban packages call the corresponding
wrapper. They are **parallel choices above the wrappers**, not a required
stack. You can also use different layers for different tasks in one
application. If you need an HTTP API instead of a local CLI, GenAgent has
[Anthropic and OpenAI HTTP backends](backends.md).

## Call a wrapper directly

Use a wrapper when you want the CLI's features without adopting another
runtime model. For example:

```elixir
{:ok, result} = ClaudeWrapper.query("Summarize this repository", working_dir: "/repo")
# or
{:ok, result} = CodexWrapper.exec("Summarize this repository", working_dir: "/repo")
```

This is the shortest path for a Mix task or a host that already handles its
own jobs. The wrappers also support multi-turn sessions; Claude offers a
long-lived duplex session. Direct use does **not** mean one-shot only. It does
mean your application decides how to supervise sessions, limit concurrent
calls, retry failures, and preserve work after a crash. The two wrapper APIs
expose their CLIs' differences rather than a common agent interface.

## Run a GenAgent

Use `gen_agent` when turns belong to an OTP agent with state and behavior
between prompts. Add `gen_agent_claude` or `gen_agent_codex`, then select its
backend when starting the agent:

```elixir
{:ok, _pid} = GenAgent.start_agent(MyApp.Assistant,
  name: "reviewer",
  backend: GenAgent.Backends.Codex,
  cwd: "/repo"
)

{:ok, response} = GenAgent.ask("reviewer", "Review the current diff")
```

The same `ask`/`tell`/`poll` API and callback lifecycle work with either CLI
backend. GenAgent serializes turns for each agent, translates provider events,
and makes its current state available by name. That is useful for interactive
work, human gates, and coordination with other OTP processes. You write the
agent module and choose the provider-specific options it passes to its
backend. GenAgent does **not** persist its agent state or pending prompts for
restart recovery; stopping or crashing an agent requires an explicit restart
and any restoration your application needs. It also does not supply a durable
job queue. See the [patterns overview](patterns/overview.md) for agent shapes.

## Enqueue an Oban worker

Use `oban_claude` or `oban_codex` when the unit of work is a queued turn. Each
package provides an Oban worker macro, validated arguments, outcome mapping,
and result helpers over its wrapper:

```elixir
defmodule MyApp.ClaudeJob do
  use ObanClaude.Worker, queue: :claude, max_attempts: 3
end

MyApp.ClaudeJob.new(%{"prompt" => "Summarize this repository", "working_dir" => "/repo"})
|> Oban.insert()
```

Oban persists the **job** and handles queue concurrency, retries, and
scheduling. A retry can issue another paid model turn and repeat file changes
or other side effects, so choose attempts and idempotency rules deliberately.
A persisted job is not a persisted Claude/Codex conversation: retain a session
identifier and arrange access to the provider's session storage if a later job
must continue the same conversation. Both Oban packages also offer an
**experimental**, opt-in Agent lifecycle for multi-turn work; its live process
state is a separate concern from the durability of individual Oban jobs.
These packages require a configured Oban instance and a working provider CLI.

If you need both interactive control and durable background work, keep their
responsibilities explicit: an application can enqueue an Oban job from a
GenAgent callback or notify a GenAgent when a job finishes. That integration
is application code, not an automatic property of either package.
