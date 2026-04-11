# Pool

Pre-started worker pool with round-robin task dispatch. Unlike
[Supervisor](supervisor.md) where workers are spawned per-sub-task
and halt after one turn, pool workers stay alive across many
turns.

## When to reach for this

You have a stream of independent tasks (not a planned-in-advance
batch), you want to throttle concurrency to a fixed number of
workers, and the startup cost of creating an agent is
non-negligible compared to the cost of a turn. Examples: a
question-answering bot pool, a scraping pool, a per-role expert
panel where you send each incoming question to the "next free"
expert.

The defining move is that `handle_response/3` returns
`{:noreply, state}` so the worker stays idle for the next task
instead of halting. Combined with `GenAgent.tell/2`'s natural
mailbox queueing (a busy worker buffers incoming work), you get
backpressure for free.

## What it exercises in gen_agent

- **Worker lifecycle reuse across many turns**: `{:noreply, state}`
  from `handle_response/3` sends the worker back to idle,
  accumulating results on state.
- **Per-worker mailbox queueing via `tell/2`**: `GenAgent.tell/2`
  queues when a worker is busy, so the dispatcher can fire-and-
  forget without checking for availability.
- **Round-robin dispatch via an atomic counter** (`:counters`).
- **Pool-wide quiescence detection**: "all workers are idle and
  their mailboxes are empty" -- a small loop over `status/1`.

## The pattern

One worker module (short), one pool dispatcher module (short).

### `Pool.Worker`

```elixir
defmodule Pool.Worker do
  @moduledoc """
  A pool worker that stays alive across many turns.

  handle_response returns {:noreply, state}, accumulating results
  in state. A task submitted to a busy worker waits in its
  mailbox (GenAgent.tell/2's natural queueing behavior).
  """

  use GenAgent

  defmodule State do
    defstruct [:name, :role, results: []]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      name: Keyword.fetch!(opts, :worker_name),
      role: Keyword.get(opts, :role, "research assistant")
    }

    system = """
    You are a #{state.role}. Answer each question concisely in
    1-2 sentences. No preamble.
    """

    {:ok, [system: system, max_tokens: Keyword.get(opts, :max_tokens, 150)], state}
  end

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    entry = %{
      text: String.trim(response.text),
      usage: response.usage,
      duration_ms: response.duration_ms,
      completed_at: System.system_time(:millisecond)
    }

    # NOT :halt -- the worker stays alive for the next task.
    {:noreply, %{state | results: state.results ++ [entry]}}
  end
end
```

### `Pool` dispatcher

```elixir
defmodule Pool do
  alias Pool.Worker

  @type handle :: %{workers: [String.t()], counter: :counters.counters_ref()}

  def start(size, opts \\ []) when is_integer(size) and size > 0 do
    role = Keyword.get(opts, :role, "research assistant")
    backend = Keyword.get(opts, :backend, GenAgent.Backends.Anthropic)
    id = System.unique_integer([:positive])

    workers =
      1..size
      |> Enum.map(fn i ->
        name = "pool-#{id}-#{i}"

        {:ok, _pid} = GenAgent.start_agent(Worker,
          name: name,
          backend: backend,
          worker_name: name,
          role: role
        )

        name
      end)

    counter = :counters.new(1, [:atomics])
    {:ok, %{workers: workers, counter: counter}}
  end

  @doc """
  Submit a task. Round-robins across workers and returns the ref
  so you can poll if you want.
  """
  def submit(%{workers: workers, counter: counter}, task) when is_binary(task) do
    idx = :counters.get(counter, 1)
    :counters.add(counter, 1, 1)
    worker = Enum.at(workers, rem(idx, length(workers)))
    # tell/2 naturally queues when the target is busy.
    {:ok, ref} = GenAgent.tell(worker, task)
    {:ok, {worker, ref}}
  end

  def submit_many(pool, tasks) when is_list(tasks) do
    Enum.map(tasks, fn t ->
      {:ok, tuple} = submit(pool, t)
      tuple
    end)
  end

  @doc """
  Block until every worker is idle with an empty mailbox.
  """
  def wait_for_all(pool, timeout \\ 120_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(pool, deadline)
  end

  @doc """
  Return per-worker results.
  """
  def results(%{workers: workers}) do
    Enum.map(workers, fn name ->
      %{agent_state: %Worker.State{results: r}} = GenAgent.status(name)
      %{worker: name, count: length(r), results: r}
    end)
  end

  def stop(%{workers: workers}) do
    Enum.each(workers, &GenAgent.stop/1)
  end

  defp do_wait(%{workers: workers} = pool, deadline) do
    any_busy =
      Enum.any?(workers, fn w ->
        case GenAgent.status(w) do
          %{state: :processing} -> true
          %{queued: q} when q > 0 -> true
          _ -> false
        end
      end)

    cond do
      not any_busy -> :ok
      System.monotonic_time(:millisecond) >= deadline -> {:error, :timeout}
      true ->
        Process.sleep(200)
        do_wait(pool, deadline)
    end
  end
end
```

## Using it

```elixir
{:ok, pool} = Pool.start(3, role: "trivia expert")

Pool.submit_many(pool, [
  "capital of France?",
  "who wrote Hamlet?",
  "first president of the US?",
  "speed of light in vacuum?",
  "chemical symbol for gold?",
  "tallest mountain on Earth?",
  "largest ocean?",
  "year WWII ended?",
  "composer of the Ninth Symphony?"
])

Pool.wait_for_all(pool)

Pool.results(pool)
# => [%{worker: "pool-1-1", count: 3, results: [...]},
#     %{worker: "pool-1-2", count: 3, results: [...]},
#     %{worker: "pool-1-3", count: 3, results: [...]}]

Pool.stop(pool)
```

## Variations

- **Work-stealing instead of round-robin.** Instead of assigning
  the next task to `next_idx`, ask each worker's status and pick
  the one with the smallest queue. More balanced under uneven
  task durations but adds N status calls per submit.
- **Typed workers.** Not every worker needs the same role. Start
  the pool with a map of `%{role => count}` and dispatch based
  on task metadata.
- **Rate-limited submission.** Wrap `submit/2` with a token
  bucket so you can't outpace the backend. Alternative: rely on
  `gen_agent`'s watchdog and let slow turns time out.
- **Auto-scaling.** Watch pool-wide queue depth via
  `[:gen_agent, :mailbox, :queued]` telemetry; when it grows
  past a threshold, spawn more workers; when it shrinks, halt
  the extras.
