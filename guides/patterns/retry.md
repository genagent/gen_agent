# Retry

Failure-and-retry agent. `handle_error/3` decides whether to retry.
A retry is a delayed event: the agent schedules a timer, goes idle,
and `handle_event/2` returns `{:prompt, retry_text, state}` when the
timer fires. The retry decision lives on agent state: attempt count,
accumulated errors, and a configurable cap.

This timer-based variant settles the original ask or tell with its first
error; the later attempt is a new event-origin turn. Read the final result
from agent state or use a completion channel of your own. If the caller needs
one final result under its original request reference, use the immediate
caller-owned variant below.

## When to reach for this

You expect transient failures (rate limits, network blips,
flaky backends) and want the agent to absorb them without the
manager having to notice and retry. The retry logic benefits
from being stateful -- you want to count attempts, track the
sequence of errors, apply backoff, and give up after a cap.

The pattern hinges on two gen_agent primitives: `handle_error/3`
sees every failed turn, and `handle_event/2` has the same return
shape as `handle_response/3`, so returning `{:prompt, text, state}`
from the timer event self-chains a retry turn.

## What it exercises in gen_agent

- **`handle_error/3` plus `handle_event/2`** as a retry primitive:
  the error handler schedules, the event handler re-prompts.
- **Attempt counting and error accumulation** on agent state.
- **Giving-up semantics** via `{:halt, %{state | phase: :failed}}`
  when `max_attempts` is reached.
- **Backoff** via a timer that calls `GenAgent.notify/2`. The agent
  process never sleeps, so `status/1`, `poll/2`, `interrupt/1` and
  `stop/1` stay responsive during the wait. A callback that sleeps
  would block them, and a `stop/1` during a sleep longer than the 5
  second child shutdown timeout would kill the process before
  `terminate_agent/2` and `terminate_session/1` run.
- **Error classes.** `:interrupted` (from `interrupt/1`) and
  `:timeout` (from the watchdog) halt instead of retrying. These
  apply to an attempt that is running. While the agent waits out a
  backoff it is idle and `interrupt/1` is a no-op, so it does not
  cancel the pending retry. Send the `:cancel_retry` event instead
  (see "Using it").
- **Cancel-safe delay.** The pending timer is tracked on state with
  a token. A cancelled or stale timer is ignored, and
  `terminate_agent/2` cancels it.

## The pattern

One callback module. No facade needed -- the manager just starts
the agent and polls status.

```elixir
defmodule Retry.Agent do
  use GenAgent

  defmodule State do
    defstruct [
      :task,
      :max_attempts,
      :agent_name,
      :base_backoff_ms,
      :result,
      :timer,
      :token,
      phase: :running,
      attempts: 0,
      errors: []
    ]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      task: Keyword.fetch!(opts, :task),
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      # GenAgent strips :name before init_agent/1, so the timer needs
      # the name passed again to address the agent.
      agent_name: Keyword.fetch!(opts, :agent_name),
      base_backoff_ms: Keyword.get(opts, :base_backoff_ms, 1000)
    }

    system = "You are a persistent assistant. Answer concisely in 1-2 sentences."

    backend_opts =
      [
        system: system,
        max_tokens: Keyword.get(opts, :max_tokens, 100)
      ] ++ Keyword.get(opts, :backend_opts, [])

    {:ok, backend_opts, state}
  end

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    new_attempts = state.attempts + 1
    text = String.trim(response.text)

    {:halt,
     %{
       state
       | result: text,
         attempts: new_attempts,
         phase: :succeeded
     }}
  end

  # Work that was stopped on purpose is not retried.
  @impl true
  def handle_error(_ref, :interrupted, %State{} = state),
    do: give_up(state, :interrupted, :interrupted)

  def handle_error(_ref, :timeout, %State{} = state),
    do: give_up(state, :timeout, :timed_out)

  def handle_error(_ref, reason, %State{} = state) do
    new_attempts = state.attempts + 1
    new_state = %{state | attempts: new_attempts, errors: state.errors ++ [reason]}

    if new_attempts < state.max_attempts do
      {:noreply, schedule_retry(new_state)}
    else
      {:halt, %{new_state | phase: :failed}}
    end
  end

  # The timer fired. Ignore it unless it is the one currently pending.
  @impl true
  def handle_event({:retry, token}, %State{phase: :waiting, token: token} = state) do
    retry_prompt = "The previous attempt failed. Retry the task: #{state.task}"
    {:prompt, retry_prompt, %{state | phase: :running, timer: nil, token: nil}}
  end

  def handle_event({:retry, _stale}, %State{} = state), do: {:noreply, state}

  # Abandon a retry that is waiting out its backoff.
  def handle_event(:cancel_retry, %State{phase: :waiting} = state) do
    {:halt, %{cancel_timer(state) | phase: :cancelled}}
  end

  def handle_event(_event, %State{} = state), do: {:noreply, state}

  @impl true
  def terminate_agent(_reason, %State{} = state) do
    cancel_timer(state)
    :ok
  end

  defp give_up(state, reason, phase) do
    {:halt,
     %{
       state
       | attempts: state.attempts + 1,
         errors: state.errors ++ [reason],
         phase: phase
     }}
  end

  # Exponential backoff: base, 2x base, 4x base, ...
  defp schedule_retry(%State{} = state) do
    backoff_ms = state.base_backoff_ms * Integer.pow(2, state.attempts - 1)
    token = make_ref()

    {:ok, timer} =
      :timer.apply_after(backoff_ms, GenAgent, :notify, [state.agent_name, {:retry, token}])

    %{state | phase: :waiting, timer: timer, token: token}
  end

  defp cancel_timer(%State{timer: nil} = state), do: state

  defp cancel_timer(%State{timer: timer} = state) do
    :timer.cancel(timer)
    %{state | timer: nil, token: nil}
  end
end
```

## Using it

```elixir
{:ok, _pid} = GenAgent.start_agent(Retry.Agent,
  name: "retry-haiku",
  agent_name: "retry-haiku",
  backend: GenAgent.Backends.Anthropic,
  task: "write a haiku about persistence",
  max_attempts: 5
)

# Kick off the first attempt.
{:ok, _ref} = GenAgent.tell("retry-haiku",
  "write a haiku about persistence")

# Wait for phase in [:succeeded, :failed, :interrupted, :timed_out,
# :cancelled] and read the result. While phase is :waiting the agent
# is idle and answers status/1 normally.
%{agent_state: state} = GenAgent.status("retry-haiku")
IO.inspect(%{
  phase: state.phase,
  attempts: state.attempts,
  errors: state.errors,
  result: state.result
})

GenAgent.stop("retry-haiku")
```

To abandon a retry that is waiting out its backoff, send
`GenAgent.notify("retry-haiku", :cancel_retry)`. `interrupt/1` cannot
do this: the agent is idle during the backoff, so the interrupt is
ignored and the timer still starts another attempt. `:cancel_retry`
halts with `phase: :cancelled` and cancels the timer. A timer message
already in flight is ignored because its token no longer matches.

## Caller-owned retries

When a caller must receive only the final outcome, return
`{:prompt, retry_prompt, state}` directly from `handle_error/3`. For ask and
tell requests, GenAgent keeps the original ref across attempts: `ask/3`
waits, `poll/3` stays pending, and a completion recipient receives one
message after success or exhaustion. Keep a retry cap in state.

```elixir
def handle_error(_ref, reason, %State{} = state) do
  attempts = state.attempts + 1
  state = %{state | attempts: attempts, errors: state.errors ++ [reason]}

  if attempts < state.max_attempts do
    {:prompt, "Retry the task: #{state.task}", state}
  else
    {:halt, %{state | phase: :failed}}
  end
end
```

This variant dispatches the next attempt promptly, without backoff. Do not
sleep in the callback: sleeping blocks status, stop, and other callers.
Use the timer-based variant above when spacing attempts matters more than
retaining the original request's result.

## Testing without burning tokens

Use a local backend instead of a real one. It implements
`GenAgent.Backend`, fails the first N prompts with a synthetic 429
error, and then succeeds. `Retry.Agent` forwards `:backend_opts`
to it, so no credentials or network are needed.

```elixir
defmodule Retry.FlakyBackend do
  @behaviour GenAgent.Backend

  @impl true
  def start_session(opts) do
    {:ok,
     %{
       calls: :counters.new(1, []),
       fail_first: Keyword.fetch!(opts, :fail_first),
       observer: Keyword.get(opts, :observer)
     }}
  end

  @impl true
  def prompt(%{calls: calls, fail_first: fail_first, observer: observer} = session, prompt) do
    :counters.add(calls, 1, 1)
    n = :counters.get(calls, 1)
    if observer, do: send(observer, {:prompt, n, prompt, System.monotonic_time(:millisecond)})

    if n <= fail_first do
      {:error, {:http_error, 429, %{"error" => %{"type" => "rate_limit_error"}}}}
    else
      {:ok, [GenAgent.Event.new(:result, %{text: "Persistence."})], session}
    end
  end

  @impl true
  def terminate_session(%{observer: observer}) do
    if observer, do: send(observer, :session_terminated)
    :ok
  end
end
```

Start the agent with a short `base_backoff_ms`:

```elixir
{:ok, _pid} = GenAgent.start_agent(Retry.Agent,
  name: "retry-test",
  agent_name: "retry-test",
  backend: Retry.FlakyBackend,
  task: "write a haiku",
  max_attempts: 5,
  base_backoff_ms: 10,
  backend_opts: [fail_first: 2, observer: self()]
)

{:ok, _ref} = GenAgent.tell("retry-test", "write a haiku")
```

The agent fails twice, waits 10 ms and 20 ms, then succeeds with
`phase: :succeeded` and `attempts: 3`. `test/guides/retry_test.exs`
compiles both modules from this guide and also covers interruption,
the watchdog, cancellation, and stop during a backoff.

## Variations

- **Exponential backoff with jitter.** Add random jitter to the
  timer delay in `schedule_retry/1`: `backoff_ms + :rand.uniform(500)`.
  Avoids thundering-herd when many agents retry simultaneously.
- **Narrower error classes.** The guide already halts on
  `:interrupted` and `:timeout`. Add clauses to `handle_error/3`
  so only `{:http_error, 429, _}` and `{:http_error, 503, _}` retry
  and every other reason halts.
- **Retry budget.** Instead of a count cap, a time budget: halt
  if `System.monotonic_time() - state.started_at` exceeds N
  seconds. More natural for "best effort within a deadline."
- **Different prompt on retry.** The retry prompt could
  incorporate the error, e.g. "The previous attempt failed with:
  #{inspect(reason)}. Try a different approach." -- useful when
  the failure is prompt-shaped rather than transport-shaped.
- **Retry with a different backend.** If the first backend
  errors three times, swap to a fallback backend. Requires the
  callback module to track which backend it started with and
  to restart the session mid-run, which is more work than the
  minimal pattern shown here.
