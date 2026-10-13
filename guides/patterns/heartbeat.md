# Heartbeat

Time-driven agent. Sits idle until a synthetic `:tick` event arrives
on a fixed interval, then decides per-tick whether the accumulated
state is worth a turn. The trigger is the clock; the filter is the
agent's own state.

## When to reach for this

The agent's job is "wake up periodically and check in." Polling an
external queue or status endpoint, summarizing accumulated
observations on a schedule, decaying or pruning stale state on a
timer, periodic re-planning, scheduled health digests. Anything
where the cadence is owned by the agent rather than driven by an
external event stream.

This is the closest cousin to [Watcher](watcher.md). Both are
idle-until-triggered and both route through `handle_event/2`. The
difference is who decides when something happens:

| Aspect            | Watcher                              | Heartbeat                             |
|-------------------|--------------------------------------|---------------------------------------|
| Trigger source    | External event stream                | Internal clock                        |
| Filter lives in   | Event content (`{:ci_result, ...}`)  | Agent state at tick time              |
| Idle behavior     | Wait for the world to push an event  | Wait for the next pulse, then inspect |
| Typical use case  | React to CI, webhooks, file changes  | Poll, summarize, prune, re-plan       |

If your agent needs both -- real events and a periodic pulse --
combine them. Heartbeat is just Watcher with the clock as one of its
event sources.

## What it exercises in gen_agent

- **`handle_event/2` with a synthetic `:tick` event** delivered via
  the notification protocol from a separate timer process. Same primitive
  as Watcher; different sender.
- **Per-tick state inspection.** The interesting logic is not
  "what does this event say" but "given where we are now, is it
  worth dispatching a turn?" Filtering happens against agent state,
  not event content.
- **Idle-until-triggered with no initial turn.** The agent does
  nothing until the first tick lands.
- **Bounded notification admission.** Events received during a turn are
  deferred and handled against post-turn state. Pending notifications and
  prompts have count and byte limits. `notify/2` returns `:ok` even on
  overflow; rejection emits `[:gen_agent, :input, :rejected]` telemetry.
  `notify_ack/3` reports admission, not turn completion. A deferred event's
  generated prompt can still be rejected later through `handle_error/3`.

## The pattern

Two pieces: the agent, and a small ticker that pulses it. The
ticker monitors one agent process and sends pulses on an interval. You can swap it for
`:timer.send_interval`, `Process.send_after`, a Quantum job, or any
other timing source without touching the agent.

`GenAgent.notify/2` resolves a registered name. Before each pulse, the ticker
checks that the name still resolves to the process it monitors; it stops when
that process exits or the name changes. The ticker includes the monitored PID
in its event, and the agent ignores a targeted tick for another PID. Even if
a replacement registers between the check and the notify call, it cannot
turn the old ticker's pulse into work. Pulses can be dropped on overload;
the next pulse rechecks the retained observations.

```elixir
defmodule Heartbeat.Agent do
  @moduledoc """
  A heartbeat-driven GenAgent that wakes up on a fixed interval and
  decides per-tick whether to dispatch a turn.

  Events:
    * :tick                    -- pulse from another timing source
    * {:tick, target_pid}      -- incarnation-bound pulse from this ticker
    * {:observation, payload}  -- enqueue an observation between ticks
  """

  use GenAgent

  defmodule State do
    defstruct observations: [], in_flight: nil, summaries: [], failures: [], min_batch: 3
  end

  @impl true
  def init_agent(opts) do
    system = """
    You are an observability digest. Given a list of recent
    observations, write a 2-sentence summary highlighting anything
    that looks anomalous. No preamble.
    """

    state = %State{min_batch: Keyword.get(opts, :min_batch, 3)}
    {:ok, [system: system, max_tokens: Keyword.get(opts, :max_tokens, 200)], state}
  end

  # --- Event handling ---

  @impl true
  def handle_event({:observation, payload}, %State{} = state) do
    {:noreply, %{state | observations: state.observations ++ [payload]}}
  end

  def handle_event({:tick, target_pid}, %State{} = state) do
    if target_pid == self(), do: handle_event(:tick, state), else: {:noreply, state}
  end

  # Keep at most one summary outstanding, including while halted.
  def handle_event(:tick, %State{in_flight: batch} = state) when not is_nil(batch),
    do: {:noreply, state}

  def handle_event(:tick, %State{observations: obs, min_batch: min} = state)
      when length(obs) < min do
    # Not enough new observations -- skip this pulse.
    {:noreply, state}
  end

  def handle_event(:tick, %State{observations: obs} = state) do
    prompt = """
    Recent observations (#{length(obs)}):

    #{Enum.map_join(obs, "\n", fn o -> "- #{inspect(o)}" end)}

    Summarize anomalies in 2 sentences.
    """

    {:prompt, prompt, %{state | observations: [], in_flight: obs}}
  end

  def handle_event(_other, state), do: {:noreply, state}

  # --- Turn completion ---

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    summary = %{text: String.trim(response.text), at: System.system_time(:millisecond)}
    {:noreply, %{state | in_flight: nil, summaries: state.summaries ++ [summary]}}
  end

  @impl true
  def handle_error(_ref, reason, %State{} = state) do
    batch = state.in_flight || []
    failure = %{observations: batch, reason: reason}

    # Retry on a later tick, never in an immediate error loop.
    {:noreply,
     %{
       state
       | in_flight: nil,
         observations: batch ++ state.observations,
         failures: state.failures ++ [failure]
     }}
  end
end

defmodule Heartbeat.Ticker do
  @moduledoc """
  Pulses one agent incarnation. Stops when that process exits.
  Start a new ticker explicitly for a replacement agent.
  """
  use GenServer, restart: :temporary

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    case GenAgent.whereis(Keyword.fetch!(opts, :agent)) do
      nil ->
        {:stop, :agent_not_found}

      pid ->
        monitor = Process.monitor(pid)
        interval = Keyword.fetch!(opts, :interval_ms)
        Process.send_after(self(), :tick, interval)
        {:ok,
         %{
           agent: Keyword.fetch!(opts, :agent),
           pid: pid,
           monitor: monitor,
           interval: interval
         }}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    # Stop once the name no longer identifies the monitored process.
    if GenAgent.whereis(state.agent) == state.pid do
      # Pulses are expendable: notify/2 reports overflow only through telemetry.
      GenAgent.notify(state.agent, {:tick, state.pid})
      Process.send_after(self(), :tick, state.interval)
      {:noreply, state}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{monitor: ref, pid: pid} = state),
    do: {:stop, :normal, state}

  def handle_info(_other, state), do: {:noreply, state}
end
```

## Using it

```elixir
{:ok, _pid} = GenAgent.start_agent(Heartbeat.Agent,
  name: "ops-digest",
  backend: GenAgent.Backends.Anthropic,
  min_batch: 3
)

# The temporary child is removed when the monitored agent stops.
{:ok, ticker_supervisor} = Supervisor.start_link(
  [{Heartbeat.Ticker, agent: "ops-digest", interval_ms: 30_000}],
  strategy: :one_for_one
)

# No initial turn. Agent is idle, ticker is counting down.
GenAgent.status("ops-digest")
# => %{state: :idle, queued: 0, ...}

# Feed observations between ticks.
:ok = GenAgent.notify_ack("ops-digest", {:observation, %{cpu: 78}})
:ok = GenAgent.notify_ack("ops-digest", {:observation, %{cpu: 92, alert: true}})

# ~30s later: tick fires. 2 observations < min_batch=3 -- skipped.

:ok = GenAgent.notify_ack("ops-digest", {:observation, %{cpu: 88}})

# ~30s later: tick fires. 3 observations >= min_batch -- dispatches a
# summary turn. The batch stays in in_flight until success; a failure
# restores it to observations for a later tick and records the reason.

%{agent_state: %{summaries: summaries}} = GenAgent.status("ops-digest")
Enum.each(summaries, fn s -> IO.puts(s.text) end)

GenAgent.stop("ops-digest")
Supervisor.stop(ticker_supervisor)
```

The ticker is a temporary child: if the agent process is restarted, its owner
must start a new ticker for that new incarnation. The batch and failure
history are in-memory only. Repeated failures can grow both lists until a
prompt exceeds the configured byte limit; cap or persist them in production.
This example is driven only by events; do not mix unrelated `tell`/`ask`
turns into its callbacks.
Use `runtime_snapshot/2` (timeout optional) for queue counts and lifecycle
inspection without copying the observation history. Its current request ref
can be passed to `interrupt_request/3` to interrupt the active turn.
`tell_with_completion/4` and `cancel_request/3` apply to caller-owned prompts
on a separate agent, not to this event-driven recipe. Notification admission
is not completion.

## Variations

- **Different timing sources.** Replace `Heartbeat.Ticker` with
  `:timer.send_interval/3` from a GenServer, a Quantum cron job, a
  systemd timer pinging an HTTP endpoint that calls `notify/2`, or
  an external scheduler. The agent doesn't care.
- **Adaptive interval.** Track recent activity in state and have the
  ticker query the agent for its preferred next-tick delay
  (`Process.send_after` from inside `handle_response/3` to a ticker
  GenServer). Slow down when idle, speed up when something
  interesting just happened.
- **Multiple cadences.** Distinct tick events --
  `:tick_fast`, `:tick_slow`, `:tick_daily` -- each on its own
  ticker, each with its own `handle_event/2` clause. One agent,
  several rhythms.
- **Per-Nth-tick deep work.** Track a tick counter in state. Most
  ticks are cheap state checks; every 10th tick triggers a deeper
  re-plan or full summary. The pattern matches against the counter
  value in `handle_event(:tick, %State{ticks: n})`.
- **Combine with Watcher.** A single agent can take both real
  external events (`{:ci_result, ...}`) and `:tick` from a ticker.
  The two `handle_event/2` clauses don't interfere. This is the
  natural shape for "react when something happens, otherwise check
  in every N minutes anyway."
- **Self-halting heartbeat.** Agent halts after N ticks or after a
  deadline (`{:halt, state}` from `handle_event(:tick, ...)`).
  Useful for time-boxed monitoring windows. Halting is not stopping:
  notifications still run `handle_event/2`, applying state changes and
  queueing generated prompts until `resume/1`. This example keeps at most
  one batch outstanding; ticks without enough observations also queue
  nothing. The ticker's owner should stop it with `GenServer.stop/1` after
  observing the halt (for example, through status or halt telemetry); its
  monitor only stops it when the agent process exits.
- **Polling external state.** The most common shape: each tick
  pulls fresh data from a queue, API, or database, stuffs it into
  state, and decides whether the new data warrants a turn. The
  pull happens in `handle_event(:tick, ...)` before the
  `{:prompt, ...}` decision.
