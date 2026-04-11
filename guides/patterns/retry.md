# Retry

Failure-and-retry agent. `handle_error/3` returns
`{:prompt, retry_text, state}` to self-chain a new attempt. The
retry decision lives on agent state: attempt count, accumulated
errors, and a configurable cap.

## When to reach for this

You expect transient failures (rate limits, network blips,
flaky backends) and want the agent to absorb them without the
manager having to notice and retry. The retry logic benefits
from being stateful -- you want to count attempts, track the
sequence of errors, apply backoff, and give up after a cap.

The pattern hinges on one gen_agent primitive: `handle_error/3`
has the same return shape as `handle_response/3`, so returning
`{:prompt, text, state}` from `handle_error` self-chains a retry
turn just as cleanly as self-chaining after a success.

## What it exercises in gen_agent

- **`handle_error/3` returning `{:prompt, ..., state}`** as a
  retry primitive -- the whole pattern is this one return shape.
- **Attempt counting and error accumulation** on agent state.
- **Giving-up semantics** via `{:halt, %{state | phase: :failed}}`
  when `max_attempts` is reached.
- **Backoff** via `Process.sleep/1` inside `handle_error/3`
  before returning the retry prompt (the agent's own process is
  the one doing the sleep, so it's naturally rate-limited).

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
      :result,
      phase: :running,
      attempts: 0,
      errors: []
    ]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      task: Keyword.fetch!(opts, :task),
      max_attempts: Keyword.get(opts, :max_attempts, 3)
    }

    system = "You are a persistent assistant. Answer concisely in 1-2 sentences."

    backend_opts = [
      system: system,
      max_tokens: Keyword.get(opts, :max_tokens, 100)
    ]

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

  @impl true
  def handle_error(_ref, reason, %State{} = state) do
    new_attempts = state.attempts + 1
    new_errors = state.errors ++ [reason]
    new_state = %{state | attempts: new_attempts, errors: new_errors}

    if new_attempts < state.max_attempts do
      # Optional: exponential backoff before retrying.
      backoff_ms = :math.pow(2, new_attempts - 1) |> round() |> Kernel.*(1000)
      Process.sleep(backoff_ms)

      retry_prompt = "The previous attempt failed. Retry the task: #{state.task}"
      {:prompt, retry_prompt, new_state}
    else
      {:halt, %{new_state | phase: :failed}}
    end
  end
end
```

## Using it

```elixir
{:ok, _pid} = GenAgent.start_agent(Retry.Agent,
  name: "retry-haiku",
  backend: GenAgent.Backends.Anthropic,
  task: "write a haiku about persistence",
  max_attempts: 5
)

# Kick off the first attempt.
{:ok, _ref} = GenAgent.tell("retry-haiku",
  "write a haiku about persistence")

# Wait for phase in [:succeeded, :failed] and read the result.
%{agent_state: state} = GenAgent.status("retry-haiku")
IO.inspect(%{
  phase: state.phase,
  attempts: state.attempts,
  errors: state.errors,
  result: state.result
})

GenAgent.stop("retry-haiku")
```

## Testing without burning tokens

In the playground we test this pattern by injecting a stateful
`http_fn` into the Anthropic backend. The function counts calls
and fails the first N with a synthetic `{:http_error, 429, ...}`,
then succeeds. No real backend calls, no tokens spent.

```elixir
defp failing_http_fn(fail_count) do
  {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

  fn _request ->
    n = Elixir.Agent.get_and_update(counter, fn n -> {n, n + 1} end)

    if n < fail_count do
      {:error,
       {:http_error, 429,
        %{"error" => %{"type" => "rate_limit_error",
                       "message" => "simulated (call #{n + 1})"}}}}
    else
      {:ok, canned_success_response(n + 1)}
    end
  end
end
```

Pass it as `http_fn: failing_http_fn(2)` in your start opts when
testing. Worth cribbing for any unit/integration test of
retry logic.

## Variations

- **Exponential backoff with jitter.** Instead of a fixed
  `2^(n-1) * 1000`, add random jitter: `sleep(backoff + :rand.uniform(500))`.
  Avoids thundering-herd when many agents retry simultaneously.
- **Error-class-aware retry.** Not every error should be
  retried. Pattern-match on the reason in `handle_error/3`:
  `:interrupted` and `:timeout` should probably not retry,
  `{:http_error, 429, _}` and `{:http_error, 503, _}` should.
  Treat non-retryable errors as immediate halt.
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
