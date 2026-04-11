# Watcher

Reactive event-driven agent. Starts idle with no initial prompt
and sits waiting until events are pushed at it via
`GenAgent.notify/2`. `handle_event/2` filters events -- interesting
ones dispatch a turn, boring ones no-op.

## When to reach for this

The agent exists to react to an external signal stream, not to
drive work on its own. CI status changes, PR events, file system
changes, scheduled triggers, webhook deliveries, queue arrivals.
The "decide when to do something" is outside the agent -- the
agent's job is just to decide what to do with each event as it
lands.

This is the only pattern in the collection where the agent has no
initial turn at all. `GenAgent.start_agent/2` returns, the agent
sits in `:idle`, and it stays there until `notify/2` is called.

## What it exercises in gen_agent

- **`handle_event/2` as the primary trigger mechanism** -- all
  dispatches come through notify, never through `ask/2` or
  `tell/2` from the manager.
- **Event filtering via pattern matching** -- one
  `handle_event/2` clause per interesting event shape plus a
  catchall returning `{:noreply, state}`.
- **Idle-until-triggered**: no initial `tell/2` call, no
  self-chain, no phase machine. The agent is a pure reducer over
  incoming events.
- **`handle_event` returning `{:prompt, text, state}`** to turn
  an interesting event into a dispatched turn.

## State mutation caveat (pre-v0.2)

On gen_agent v0.1, `handle_event/2` state mutations could be
silently overwritten by an in-flight turn's `handle_response`
state. That was fixed in the notify-deferral patch (v0.1.1): events
arriving during `:processing` are buffered into `pending_events`
and drained synchronously against post-decision state before the
transition to `:idle`.

**If you're on gen_agent v0.1.1 or later, you can mutate state
from `handle_event/2` freely.** The example below is conservative
and only mutates state from `handle_response/3`, which still works
as a style choice if you want a single place for state writes.

## The pattern

One callback module. The manager never sends prompts directly;
everything is driven by `notify/2`.

```elixir
defmodule Watcher.Agent do
  @moduledoc """
  A reactive GenAgent that starts idle and only wakes up when
  interesting events arrive.

  Events this agent understands:
    * {:ci_result, :passed}             -- ignored
    * {:ci_result, :failed, details}    -- diagnosis turn
    * {:pr_opened, author, title}       -- welcome turn
    * {:timer, label}                   -- ignored
  """

  use GenAgent

  defmodule State do
    defstruct actions: []
  end

  @impl true
  def init_agent(opts) do
    system = """
    You are a CI/PR watcher. When asked to diagnose a build
    failure, respond in 2 short sentences: likely cause +
    suggested first step. When asked to welcome a PR, respond in
    one sentence. No preamble.
    """

    {:ok, [system: system, max_tokens: Keyword.get(opts, :max_tokens, 120)], %State{}}
  end

  # --- Event filtering ---

  @impl true
  def handle_event({:ci_result, :passed}, state), do: {:noreply, state}

  def handle_event({:ci_result, :failed, details}, state) do
    prompt = """
    CI build failed with this error:

    #{details}

    Diagnose the likely cause and first debugging step.
    """

    {:prompt, prompt, state}
  end

  def handle_event({:pr_opened, author, title}, state) do
    prompt = ~s|#{author} just opened a PR titled: "#{title}". Welcome them in one sentence.|
    {:prompt, prompt, state}
  end

  def handle_event({:timer, _label}, state), do: {:noreply, state}

  def handle_event(_other, state), do: {:noreply, state}

  # --- Turn completion ---

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    action = %{text: String.trim(response.text), at: System.system_time(:millisecond)}
    {:noreply, %{state | actions: state.actions ++ [action]}}
  end
end
```

## Using it

```elixir
{:ok, _pid} = GenAgent.start_agent(Watcher.Agent,
  name: "ci-watcher",
  backend: GenAgent.Backends.Anthropic
)

# No initial turn. The agent is idle.
GenAgent.status("ci-watcher")
# => %{state: :idle, queued: 0, ...}

# Push events.
GenAgent.notify("ci-watcher", {:ci_result, :passed})
# -> ignored, agent stays idle

GenAgent.notify("ci-watcher", {:pr_opened, "alice", "fix: auth header bug"})
# -> dispatches a welcome turn

GenAgent.notify("ci-watcher", {:ci_result, :failed, "test_auth.ex:42: assertion failed"})
# -> dispatches a diagnosis turn

# Read the log of actions the agent has produced.
%{agent_state: %{actions: actions}} = GenAgent.status("ci-watcher")
Enum.each(actions, fn a -> IO.puts(a.text) end)

GenAgent.stop("ci-watcher")
```

## Variations

- **External signal sources.** Hook a GenServer or a Task that
  tails GitHub webhooks, inotify, a Kafka topic, or a cron-style
  scheduler, and have it call `GenAgent.notify/2` on every
  event. The watcher doesn't care where events come from.
- **Routing to multiple watchers.** If you want different
  watchers for different event classes, start N named watchers
  and have the dispatcher pattern-match events to routes.
- **Rate limiting.** If the event stream is bursty, the watcher's
  mailbox can fill up. Drop-on-busy at the notify source, or use
  `handle_event({:ci_result, :failed, _}, %{recent: ts})` with a
  state-tracked cooldown.
- **Combine with Pool.** A single watcher can receive events and
  `GenAgent.tell/2` them into a worker pool for parallel
  processing. The watcher becomes pure dispatch logic; the pool
  does the work.
- **Self-destructing watcher.** A watcher that halts itself after
  receiving N events or after a certain time, so you can start
  short-lived scoped watchers for narrow windows of interest.
