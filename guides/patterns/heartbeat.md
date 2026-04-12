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
  `notify/2` from a separate timer process. Same primitive as
  Watcher; different sender.
- **Per-tick state inspection.** The interesting logic is not
  "what does this event say" but "given where we are now, is it
  worth dispatching a turn?" Filtering happens against agent state,
  not event content.
- **Idle-until-triggered with no initial turn.** The agent does
  nothing until the first tick lands.
- **Notify deferral guarantee (v0.1.1+).** Ticks that arrive while
  the agent is in `:processing` are buffered and drained against
  post-decision state, so a long-running turn doesn't drop or
  duplicate pulses.

## The pattern

Two pieces: the agent, and a small ticker that pulses it. The
ticker is deliberately tiny -- it's just a process that calls
`GenAgent.notify/2` on an interval -- so you can swap it for
`:timer.send_interval`, `Process.send_after`, a Quantum job, or any
other timing source without touching the agent.

```elixir
defmodule Heartbeat.Agent do
  @moduledoc """
  A heartbeat-driven GenAgent that wakes up on a fixed interval and
  decides per-tick whether to dispatch a turn.

  Events:
    * :tick                    -- pulse from the ticker
    * {:observation, payload}  -- enqueue an observation between ticks
  """

  use GenAgent

  defmodule State do
    defstruct observations: [], summaries: [], min_batch: 3
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

    {:prompt, prompt, %{state | observations: []}}
  end

  def handle_event(_other, state), do: {:noreply, state}

  # --- Turn completion ---

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    summary = %{text: String.trim(response.text), at: System.system_time(:millisecond)}
    {:noreply, %{state | summaries: state.summaries ++ [summary]}}
  end
end

defmodule Heartbeat.Ticker do
  @moduledoc """
  Minimal ticker. Pulses a named GenAgent on a fixed interval via
  `GenAgent.notify/2`. Linked to its caller, so it dies when the
  caller dies. Swap for `:timer.send_interval`, Quantum, or any
  scheduler that can deliver a message.
  """

  def start_link(agent_name, interval_ms) do
    Task.start_link(fn -> loop(agent_name, interval_ms) end)
  end

  defp loop(agent_name, interval_ms) do
    Process.sleep(interval_ms)
    GenAgent.notify(agent_name, :tick)
    loop(agent_name, interval_ms)
  end
end
```

## Using it

```elixir
{:ok, _pid} = GenAgent.start_agent(Heartbeat.Agent,
  name: "ops-digest",
  backend: GenAgent.Backends.Anthropic,
  min_batch: 3
)

{:ok, _ticker} = Heartbeat.Ticker.start_link("ops-digest", 30_000)

# No initial turn. Agent is idle, ticker is counting down.
GenAgent.status("ops-digest")
# => %{state: :idle, queued: 0, ...}

# Feed observations between ticks.
GenAgent.notify("ops-digest", {:observation, %{cpu: 78}})
GenAgent.notify("ops-digest", {:observation, %{cpu: 92, alert: true}})

# ~30s later: tick fires. 2 observations < min_batch=3 -- skipped.

GenAgent.notify("ops-digest", {:observation, %{cpu: 88}})

# ~30s later: tick fires. 3 observations >= min_batch -- dispatches a
# summary turn. observations is reset to [] and the summary lands in
# state.summaries.

%{agent_state: %{summaries: summaries}} = GenAgent.status("ops-digest")
Enum.each(summaries, fn s -> IO.puts(s.text) end)

GenAgent.stop("ops-digest")
```

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
  Useful for time-boxed monitoring windows. Stop the ticker too,
  or it'll keep notifying a halted agent (harmless, but noisy).
- **Polling external state.** The most common shape: each tick
  pulls fresh data from a queue, API, or database, stuffs it into
  state, and decides whether the new data warrants a turn. The
  pull happens in `handle_event(:tick, ...)` before the
  `{:prompt, ...}` decision.
