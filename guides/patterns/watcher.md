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

## Admission and state

Notifications received during a turn are deferred and handled against
post-turn state. Pending notifications and prompts are bounded by count
and bytes (`max_pending_notifications`, `max_pending_prompts`, and their
byte limits). `notify/2` returns `:ok` even when input is dropped, with
`[:gen_agent, :input, :rejected]` telemetry. Use `notify_ack/3` for admission
results. A rejected notification may be safe to retry if it never reached
`handle_event/2`; a generated prompt rejected after `handle_event/2` is
already recorded in `failures`, so blind retry would duplicate it. Inspect
that state or use event IDs before retrying. Admission is not completion:
a deferred event's generated prompt can later be rejected with
`{:overloaded, info}` through `handle_error/3`.

The example records pending events before dispatch, then records either
an action or a failure. A rejected new prompt is removed from the tail;
turns that start consume the head in FIFO order. Failures are retained for
inspection or explicit replay, without an automatic retry loop. This is
in-memory history, not durable delivery. Drive this agent only through
events so unrelated `tell`/`ask` turns cannot consume its pending events.

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
    defstruct actions: [], pending: [], active: nil, failures: []
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

  def handle_event({:ci_result, :failed, details} = event, state) do
    prompt = """
    CI build failed with this error:

    #{details}

    Diagnose the likely cause and first debugging step.
    """

    {:prompt, prompt, %{state | pending: state.pending ++ [{event, prompt}]}}
  end

  def handle_event({:pr_opened, author, title} = event, state) do
    prompt = ~s|#{author} just opened a PR titled: "#{title}". Welcome them in one sentence.|
    {:prompt, prompt, %{state | pending: state.pending ++ [{event, prompt}]}}
  end

  def handle_event({:timer, _label}, state), do: {:noreply, state}

  def handle_event(_other, state), do: {:noreply, state}

  # A queue rejection happens before pre_turn; an executing turn owns active.
  # Match the generated prompt so an unrelated direct prompt cannot claim an event.
  @impl true
  def pre_turn(prompt, %State{pending: [{event, prompt} | rest]} = state) do
    {:ok, prompt, %{state | pending: rest, active: event}}
  end

  # This recipe processes event-generated prompts only. Unmatched direct
  # prompts are skipped explicitly, rather than claiming a queued event.
  def pre_turn(_prompt, %State{} = state), do: {:skip, state}

  # --- Turn completion ---

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    action = %{
      event: state.active,
      text: String.trim(response.text),
      at: System.system_time(:millisecond)
    }

    {:noreply, %{state | active: nil, actions: state.actions ++ [action]}}
  end

  @impl true
  def handle_error(_ref, reason, %State{} = state) do
    {event, pending} =
      if is_nil(state.active) do
        {{event, _prompt}, rest} = List.pop_at(state.pending, -1)
        {event, rest}
      else
        {state.active, state.pending}
      end

    failure = %{event: event, reason: reason, at: System.system_time(:millisecond)}
    {:noreply, %{state | active: nil, pending: pending, failures: state.failures ++ [failure]}}
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

Use `runtime_snapshot/2` (timeout optional) to inspect queue counts without
copying action history. Its current request ref can be passed to
`interrupt_request/3` to interrupt the active turn. `tell_with_completion/4`
and `cancel_request/3` apply to caller-owned prompts on a separate agent, not
to this event-driven recipe. Notification admission is not completion.

## Variations

- **External signal sources.** Hook a GenServer or a Task that
  tails GitHub webhooks, inotify, a Kafka topic, or a cron-style
  scheduler, and have it call `GenAgent.notify/2` on every
  event. The watcher doesn't care where events come from.
- **Routing to multiple watchers.** If you want different
  watchers for different event classes, start N named watchers
  and have the dispatcher pattern-match events to routes.
- **Rate limiting.** If the event stream is bursty, the watcher's
  bounded pending queues can reject input. Handle `notify_ack/3` overload
  at the source, or use
  `handle_event({:ci_result, :failed, _}, %{recent: ts})` with a
  state-tracked cooldown.
- **Combine with Pool.** A single watcher can receive events and
  `GenAgent.tell/2` them into a worker pool for parallel
  processing. The watcher becomes pure dispatch logic; the pool
  does the work.
- **Self-destructing watcher.** A watcher that halts itself after
  receiving N events or after a certain time, so you can start
  short-lived scoped watchers for narrow windows of interest.
