# Supervisor

Coordinator + dynamic worker pool. One coordinator plans sub-tasks
via its own LLM turn, **spawns N worker agents from inside its own
`handle_response/3` callback**, notifies each worker with its
sub-task, collects results as they arrive via notify, and
self-chains a synthesis turn.

## When to reach for this

A task decomposes into N independent sub-tasks where N is decided
by the LLM (or by runtime conditions), each sub-task gets its own
agent, and the coordinator has to aggregate their outputs into a
final answer. You want fan-out for parallelism and fan-in for the
synthesis step. Classic map/reduce, but every worker is an agent.

This is the richest cross-agent pattern in this collection.
Everything else composes: the coordinator is a
[Research](research.md)-style self-chaining agent whose planning
turn spawns a pool of one-shot workers, each of whom is
essentially a single-item [Pipeline](pipeline.md) stage.

## What it exercises in gen_agent

- **Dynamic `GenAgent.start_agent/2` called from inside a running
  callback.** The coordinator's planning-phase `handle_response`
  spawns workers on the fly. They join the shared `GenAgent`
  supervision tree and are live from the moment they start.
- **Fan-out via notify**: the coordinator notifies each worker
  with its sub-task immediately after spawning. Workers sit idle
  until they receive the notify.
- **Fan-in via notify**: each worker notifies the coordinator
  with its result (or failure). The coordinator's `handle_event/2`
  accumulates results into a map.
- **Multi-phase coordinator state machine** with an LLM turn at
  each end (planning -> dispatch -> collect -> synthesize).
- **Self-halt workers**: each worker halts via `{:halt, state}`
  after its single turn so the coordinator doesn't have to track
  or stop them explicitly.

## The pattern

Two callback modules: a `Coordinator` that owns the phase state
machine and spawns workers, and a `Worker` that is one-shot and
notifies the coordinator with its result.

### `Supervisor.Coordinator`

```elixir
defmodule Supervisor.Coordinator do
  use GenAgent

  alias Supervisor.Worker

  defmodule State do
    defstruct [
      :topic,
      :max_workers,
      :coordinator_name,
      :final_output,
      :error,
      phase: :planning,
      sub_tasks: [],
      workers: [],
      results: %{},
      failures: %{}
    ]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      topic: Keyword.fetch!(opts, :topic),
      max_workers: Keyword.get(opts, :max_workers, 3),
      coordinator_name: Keyword.fetch!(opts, :coordinator_name)
    }

    system = """
    You are a research coordinator.

    When asked to plan sub-tasks, output them one per line, no
    numbering or bullets -- just plain sub-task text, one per line.

    When asked to synthesize worker results, write a coherent
    2-3 paragraph answer that weaves together the findings.
    """

    {:ok, [system: system, max_tokens: Keyword.get(opts, :max_tokens, 600)], state}
  end

  # Phase :planning -> spawn workers, notify each, transition to :collecting.
  @impl true
  def handle_response(_ref, response, %State{phase: :planning} = state) do
    sub_tasks =
      response.text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(state.max_workers)

    workers = spawn_workers(state.coordinator_name, sub_tasks)

    Enum.zip(workers, sub_tasks)
    |> Enum.each(fn {worker, task} ->
      GenAgent.notify(worker, {:sub_task, task})
    end)

    new_state = %{state | sub_tasks: sub_tasks, workers: workers, phase: :collecting}

    case sub_tasks do
      [] -> {:halt, %{new_state | phase: :failed, error: :no_sub_tasks}}
      _ -> {:noreply, new_state}
    end
  end

  # Phase :synthesizing -> terminal halt with the final answer.
  def handle_response(_ref, response, %State{phase: :synthesizing} = state) do
    {:halt, %{state | final_output: String.trim(response.text), phase: :done}}
  end

  # Phase :collecting -> accumulate worker results, self-chain synthesis
  # once everyone has reported.
  @impl true
  def handle_event({:worker_result, worker_name, text}, %State{phase: :collecting} = state) do
    maybe_synthesize(%{state | results: Map.put(state.results, worker_name, text)})
  end

  def handle_event({:worker_failed, worker_name, reason}, %State{phase: :collecting} = state) do
    maybe_synthesize(%{state | failures: Map.put(state.failures, worker_name, reason)})
  end

  def handle_event(_other, state), do: {:noreply, state}

  @impl true
  def handle_error(_ref, reason, %State{} = state) do
    {:halt, %{state | error: reason, phase: :failed}}
  end

  defp maybe_synthesize(%State{} = state) do
    received = map_size(state.results) + map_size(state.failures)

    cond do
      received < length(state.workers) ->
        {:noreply, state}

      state.results == %{} ->
        {:halt, %{state | phase: :failed, error: :all_workers_failed}}

      true ->
        {:prompt, synthesis_prompt(state), %{state | phase: :synthesizing}}
    end
  end

  defp synthesis_prompt(%State{} = state) do
    sections =
      state.sub_tasks
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn {task, i} ->
        worker = Enum.at(state.workers, i)
        result = Map.get(state.results, worker, "(worker failed)")
        "Sub-task: #{task}\nResult: #{result}"
      end)

    """
    Your workers have reported on all sub-tasks for the topic:
    #{state.topic}

    Here is what each worker returned:

    #{sections}

    Synthesize these into a cohesive 2-paragraph answer.
    """
  end

  defp spawn_workers(coordinator_name, sub_tasks) do
    sub_tasks
    |> Enum.with_index(1)
    |> Enum.map(fn {_task, i} ->
      worker_name = "#{coordinator_name}-worker-#{i}"

      {:ok, _pid} = GenAgent.start_agent(Worker,
        name: worker_name,
        backend: GenAgent.Backends.Anthropic,
        worker_name: worker_name,
        supervisor: coordinator_name
      )

      worker_name
    end)
  end
end
```

### `Supervisor.Worker`

```elixir
defmodule Supervisor.Worker do
  use GenAgent

  defmodule State do
    defstruct [:name, :supervisor, :task, :result, :error]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      name: Keyword.fetch!(opts, :worker_name),
      supervisor: Keyword.fetch!(opts, :supervisor)
    }

    system = """
    You are a research worker. You will be given exactly one
    sub-task. Answer it in 2-3 concise sentences. No preamble.
    """

    {:ok, [system: system, max_tokens: 300], state}
  end

  @impl true
  def handle_event({:sub_task, task}, %State{} = state) do
    {:prompt, task, %{state | task: task}}
  end

  def handle_event(_other, state), do: {:noreply, state}

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    result = String.trim(response.text)
    GenAgent.notify(state.supervisor, {:worker_result, state.name, result})
    {:halt, %{state | result: result}}
  end

  @impl true
  def handle_error(_ref, reason, %State{} = state) do
    GenAgent.notify(state.supervisor, {:worker_failed, state.name, reason})
    {:halt, %{state | error: reason}}
  end
end
```

## Using it

```elixir
name = "coord-#{System.unique_integer([:positive])}"

{:ok, _pid} = GenAgent.start_agent(Supervisor.Coordinator,
  name: name,
  backend: GenAgent.Backends.Anthropic,
  topic: "why do octopuses have three hearts?",
  max_workers: 3,
  coordinator_name: name
)

# Kick off the planning turn.
{:ok, _ref} = GenAgent.tell(name,
  "Break the topic into 3 specific sub-questions. One per line.")

# The coordinator will plan, spawn 3 workers, dispatch their
# sub-tasks, wait for responses, synthesize, and halt. The manager
# just watches.

# When phase: :done, read the final output:
%{agent_state: %{final_output: output}} = GenAgent.status(name)
IO.puts(output)

GenAgent.stop(name)
```

## Variations

- **Bounded concurrency.** For very large N, instead of spawning
  N workers, spawn K and use a work-stealing loop: when one
  worker halts, the coordinator notifies a new worker with the
  next sub-task. See [Pool](pool.md) for a cleaner version of
  this shape.
- **Heterogeneous workers.** Different sub-tasks can get
  different worker modules. The coordinator's `spawn_workers`
  function decides which module to instantiate based on the
  sub-task content.
- **Partial success.** The current `maybe_synthesize` only
  proceeds if at least one worker succeeded. You could instead
  require a quorum (e.g. 2/3) or fail the whole run if any
  worker failed.
- **Nested coordinators.** Any worker could itself be a
  coordinator that fans out further. The shared supervision tree
  doesn't care -- each level just spawns agents into it.
- **Streaming synthesis.** Instead of waiting for all workers
  before synthesizing, the coordinator could start synthesis
  once the first K results are in, incorporate later results by
  editing state, and produce a final synthesis when everything
  is complete. Requires a more complex phase machine.
