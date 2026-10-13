# Pool

Pre-started workers stay alive across many turns. The shipped Ensemble
strategy dispatches to the next free worker and queues requests FIFO
when all are busy. The callback recipe later on this page uses
round-robin assignment instead. Unlike [Supervisor](supervisor.md),
Pool does not start a new worker for each sub-task.

## Using it from `gen_agent_ensemble`

This pattern ships as `GenAgentEnsemble.Strategies.Pool`. The
strategy owns the N workers, FIFO queueing, and parallel dispatch;
you supply a worker agent spec.

```elixir
{:ok, _pid} =
  GenAgentEnsemble.start_link(
    name: "qa-pool",
    strategy: GenAgentEnsemble.Strategies.Pool,
    opts: [
      worker_count: 4,
      worker_template: {"worker", MyWorker, backend: MyBackend}
    ]
  )

{:ok, tok1} = GenAgentEnsemble.tell("qa-pool", "question one")
{:ok, tok2} = GenAgentEnsemble.tell("qa-pool", "question two")
# After the workers finish, inbox drains completed results.
{:ok, inbox} = GenAgentEnsemble.inbox("qa-pool")
```

The rest of this page is a separate callback-level reference
implementation. Read the shipped strategy's module documentation for
its exact options and failure behavior.

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
bounded pending queue, a busy worker can buffer incoming work up to
its configured limits. The defaults are 1,000 pending prompts and
1,048,576 bytes (measured with `:erlang.external_size/1`); the active
turn is excluded. Callers must handle overload rejections by slowing
down, retrying later, or reporting the rejection.

## What the callback recipe exercises

- **Worker lifecycle reuse across many turns**: `{:noreply, state}`
  from `handle_response/3` sends the worker back to idle,
  accumulating results on state.
- **Per-worker mailbox queueing via `tell/2`**: `GenAgent.tell/2`
  queues when a worker is busy, or returns an overload error when
  its pending queue is full.
- **Round-robin dispatch via an atomic increment** (`:atomics.add_get/3`).
  Concurrent attempts take distinct positions in the rotation;
  arrival and completion order can differ. Rejections also consume a position.
- **Pool-wide quiescence detection**: "all workers are idle and
  their pending queues are empty" -- a loop over `runtime_snapshot/1`
  that does not copy accumulated results. Stop submitting before waiting;
  this is not a barrier against concurrent submissions.

## Callback reference implementation

One worker module (short), one pool dispatcher module (short).

### `Pool.Worker`

```elixir
defmodule Pool.Worker do
  @moduledoc """
  A pool worker that stays alive across many turns.

  Successes and failures accumulate in state, identified by prompt
  and request ref. Accepted tasks wait in the bounded pending queue
  while the worker is busy.
  """

  use GenAgent

  defmodule State do
    defstruct [:name, :role, :task, results: []]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      name: GenAgent.current_name(),
      role: Keyword.get(opts, :role, "research assistant")
    }

    system = """
    You are a #{state.role}. Answer each question concisely in
    1-2 sentences. No preamble.
    """

    {:ok, [system: system, max_tokens: Keyword.get(opts, :max_tokens, 150)], state}
  end

  @impl true
  def pre_turn(task, %State{} = state) do
    {:ok, task, %{state | task: task}}
  end

  @impl true
  def handle_response(ref, response, %State{} = state) do
    entry = %{
      ref: ref,
      task: state.task,
      status: :ok,
      text: String.trim(response.text),
      usage: response.usage,
      duration_ms: response.duration_ms,
      completed_at: System.system_time(:millisecond)
    }

    # NOT :halt -- the worker stays alive for the next task.
    {:noreply, %{state | task: nil, results: [entry | state.results]}}
  end

  @impl true
  def handle_error(ref, reason, %State{} = state) do
    entry = %{
      ref: ref,
      task: state.task,
      status: :error,
      reason: reason,
      completed_at: System.system_time(:millisecond)
    }

    {:noreply, %{state | task: nil, results: [entry | state.results]}}
  end
end
```

### `Pool` dispatcher

```elixir
defmodule Pool do
  alias Pool.Worker

  @type handle :: %{workers: [String.t()], counter: :atomics.atomics_ref()}

  def start(size, opts \\ []) when is_integer(size) and size > 0 do
    role = Keyword.get(opts, :role, "research assistant")
    backend = Keyword.get(opts, :backend, GenAgent.Backends.Anthropic)
    id = System.unique_integer([:positive])
    limits = Keyword.take(opts, [:max_pending_prompts, :max_pending_prompt_bytes])

    result =
      Enum.reduce_while(1..size, {:ok, []}, fn i, {:ok, started} ->
        name = "pool-#{id}-#{i}"

        case GenAgent.start_agent(
               Worker,
               [name: name, backend: backend, role: role] ++ limits
             ) do
          {:ok, pid} -> {:cont, {:ok, [{name, pid} | started]}}
          {:error, reason} -> {:halt, {:error, reason, started}}
        end
      end)

    case result do
      {:ok, started} ->
        workers = started |> Enum.reverse() |> Enum.map(&elem(&1, 0))
        {:ok, %{workers: workers, counter: :atomics.new(1, [])}}

      {:error, reason, started} ->
        Enum.each(started, fn {_name, pid} ->
          DynamicSupervisor.terminate_child(GenAgent.AgentSupervisor, pid)
        end)

        {:error, reason}
    end
  end

  @doc """
  Submit a task. Returns {:ok, {worker, ref}} for accepted work,
  or {:error, reason}, including {:error, {:overloaded, info}}.
  Rejected tasks have no ref and will not appear in results/1.
  """
  def submit(%{workers: workers, counter: counter}, task) when is_binary(task) do
    idx = :atomics.add_get(counter, 1, 1) - 1
    worker = Enum.at(workers, rem(idx, length(workers)))

    case GenAgent.tell(worker, task) do
      {:ok, ref} -> {:ok, {worker, ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  def submit_many(pool, tasks) when is_list(tasks) do
    Enum.map(tasks, fn task -> {task, submit(pool, task)} end)
  end

  @doc """
  Wait for accepted work to finish. Call after all submitters have finished.
  """
  def wait_for_all(pool, timeout \\ 120_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(pool, deadline)
  end

  @doc """
  Return per-worker successes and failures in completion order.
  """
  def results(%{workers: workers}) do
    Enum.map(workers, fn name ->
      %{agent_state: %Worker.State{results: r}} = GenAgent.status(name)
      %{worker: name, count: length(r), results: Enum.reverse(r)}
    end)
  end

  def stop(%{workers: workers}) do
    Enum.each(workers, &GenAgent.stop/1)
  end

  defp do_wait(%{workers: workers} = pool, deadline) do
    any_busy =
      Enum.any?(workers, fn w ->
        snapshot = GenAgent.runtime_snapshot(w)

        snapshot.phase != :idle or snapshot.pending_prompts > 0 or
          snapshot.pending_notifications > 0 or snapshot.self_chain_pending
      end)

    cond do
      not any_busy ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(200)
        do_wait(pool, deadline)
    end
  end
end
```

## Using it

```elixir
{:ok, pool} =
  Pool.start(3,
    role: "trivia expert",
    max_pending_prompts: 100,
    max_pending_prompt_bytes: 262_144
  )

submissions =
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

# Keep each task paired with its admission outcome; surface rejections.
Enum.each(submissions, fn
  {_task, {:ok, {_worker, _ref}}} -> :ok
  {task, {:error, reason}} -> IO.inspect({task, reason}, label: "rejected")
end)

:ok = Pool.wait_for_all(pool)

Pool.results(pool)
# => [%{worker: "pool-1-1", count: 3, results: [...]},
#     %{worker: "pool-1-2", count: 3, results: [...]},
#     %{worker: "pool-1-3", count: 3, results: [...]}]

Pool.stop(pool)
```

Each result includes `task`, `ref`, and `status: :ok | :error`.
Failures include `reason` and count toward the worker's total. The ref
distinguishes repeated identical prompts. Results accumulate for the lifetime
of this simple example; a long-running service should drain or persist them.
Cancelling a request while it is still queued bypasses the worker callbacks,
so it does not create a result entry; use the returned ref to check that outcome.

## Variations

- **Work-stealing instead of round-robin.** Instead of assigning
  the next task to `idx`, read each worker's `runtime_snapshot/1` and
  pick the one with the smallest `pending_prompts` count, preferring
  idle workers. More balanced under uneven task durations but adds N
  snapshot calls per submit. These observations can race with other
  submitters, so overload handling is still required.
- **Typed workers.** Not every worker needs the same role. Start
  the pool with a map of `%{role => count}` and dispatch based
  on task metadata.
- **Rate-limited submission.** Wrap `submit/2` with a token
  bucket so you can't outpace the backend. Alternative: rely on
  `gen_agent`'s watchdog and let slow turns time out.
- **Auto-scaling.** Watch pool-wide queue depth via
  `[:gen_agent, :mailbox, :queued]` telemetry; when it grows
  past a threshold, spawn more workers; when it shrinks, remove the
  extras from dispatch, drain their accepted work, then stop them with
  `GenAgent.stop/1` (or `Pool.stop/1` on the removed subset). Coordinate
  worker-list changes with submitters; halting alone leaves processes alive.
