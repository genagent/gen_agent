# Supervisor

Coordinator + temporary worker pool. The shipped Ensemble strategy
dispatches to a coordinator, parses its response into sub-prompts,
starts one worker per sub-prompt, and combines their replies. The
callback recipe later on this page takes a
different path: its coordinator starts workers from
`handle_response/3`, exchanges notifications, and runs a final LLM
synthesis turn.

## Using it from `gen_agent_ensemble`

This pattern ships as `GenAgentEnsemble.Strategies.Supervisor`. The
strategy handles spawning, collection, and reply synthesis. Supply
coordinator and worker agent specs, plus a `:decomposer` function
that turns the coordinator's response into sub-prompts. A
`:synthesizer` function is optional; without one, worker texts are
joined in worker-name order.

```elixir
{:ok, _pid} =
  GenAgentEnsemble.start_link(
    name: "research-squad",
    strategy: GenAgentEnsemble.Strategies.Supervisor,
    opts: [
      coordinator: {"planner", MyPlanner, backend: MyBackend},
      worker_template: {"worker", MyWorker, backend: MyBackend},
      decomposer: &MyPlanner.parse_subtasks/1,
      synthesizer: &MyPlanner.merge_results/1
    ]
  )

{:ok, result} = GenAgentEnsemble.ask("research-squad", "research X")
```

The rest of this page is a separate callback-level reference
implementation. Read the shipped strategy's module documentation for
its exact options and failure behavior.

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

## What the callback recipe exercises

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
  after its single turn. Halting retains the process, registration,
  and backend session; the watcher explicitly stops every worker.

## Callback reference implementation

Two callback modules and an OTP watcher: a `Coordinator` owns the phase
state machine, a one-shot `Worker` reports its result, and a `Watcher`
starts, monitors, and stops the workers.

### `Fanout.Coordinator`

```elixir
defmodule Fanout.Coordinator do
  use GenAgent

  defmodule State do
    defstruct [
      :topic,
      :max_workers,
      :coordinator_name,
      :final_output,
      :error,
      :worker_backend,
      :watcher,
      :run,
      :synthesis_prompt,
      synthesis_turn: false,
      worker_opts: [],
      collect_timeout: 5_000,
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
      coordinator_name: Keyword.fetch!(opts, :coordinator_name),
      worker_backend: Keyword.fetch!(opts, :worker_backend),
      worker_opts: Keyword.get(opts, :worker_opts, []),
      collect_timeout: Keyword.get(opts, :collect_timeout, 5_000),
      run: System.unique_integer([:positive, :monotonic])
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

  # Event-generated prompts may wait behind user turns. Identify synthesis
  # at dispatch, not merely when the last worker report changes the phase.
  @impl true
  def pre_turn(prompt, %State{} = state) do
    synthesis_turn = state.phase == :synthesizing and prompt == state.synthesis_prompt
    {:ok, prompt, %{state | synthesis_turn: synthesis_turn}}
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

    case sub_tasks do
      [] ->
        finish(state, :failed, :no_sub_tasks)

      _ ->
        {:ok, watcher} = Fanout.Watcher.start(self(), state)
        state = %{state | watcher: watcher, sub_tasks: sub_tasks}

        case GenServer.call(watcher, {:spawn, sub_tasks}, :infinity) do
          {:ok, workers} ->
            Enum.zip(workers, sub_tasks)
            |> Enum.each(fn {worker, task} -> GenAgent.notify(worker, {:sub_task, task}) end)

            {:noreply, %{state | workers: workers, phase: :collecting}}

          {:error, reason} ->
            finish(state, :failed, {:worker_start, reason})
        end
    end
  end

  # Phase :synthesizing -> terminal halt with the final answer.
  def handle_response(_ref, response,
        %State{phase: :synthesizing, synthesis_turn: true} = state) do
    finish(%{state | final_output: String.trim(response.text)}, :done)
  end

  # Extra ask/tell turns do not change collection or terminal results.
  def handle_response(_ref, _response, %State{phase: phase} = state)
      when phase in [:done, :failed], do: {:halt, state}

  def handle_response(_ref, _response, state), do: {:noreply, state}

  # Phase :collecting -> accumulate worker results, enqueue synthesis
  # once everyone has reported.
  @impl true
  def handle_event({kind, run, worker, value}, %State{phase: :collecting, run: run} = state)
      when kind in [:worker_result, :worker_failed, :worker_down] do
    if worker in state.workers and
         not Map.has_key?(state.results, worker) and not Map.has_key?(state.failures, worker) do
      state =
        if kind == :worker_result,
          do: %{state | results: Map.put(state.results, worker, value)},
          else: %{state | failures: Map.put(state.failures, worker, value)}

      maybe_synthesize(state)
    else
      {:noreply, state}
    end
  end

  def handle_event({:collect_timeout, run}, %State{phase: :collecting, run: run} = state) do
    failures =
      Enum.reduce(state.workers, state.failures, fn worker, failures ->
        if Map.has_key?(state.results, worker),
          do: failures,
          else: Map.put_new(failures, worker, :timeout)
      end)

    maybe_synthesize(%{state | failures: failures})
  end

  def handle_event(_other, state), do: {:noreply, state}

  @impl true
  def handle_error(_ref, reason, %State{phase: :planning} = state),
    do: finish(state, :failed, reason)

  def handle_error(_ref, reason,
        %State{phase: :synthesizing, synthesis_turn: true} = state),
    do: finish(state, :failed, reason)

  # The server can reject synthesis before pre_turn/2 marks its dispatch.
  def handle_error(_ref, {:overloaded, %{queue: queue}} = reason,
        %State{phase: :synthesizing, synthesis_turn: false} = state)
      when queue in [:prompts, :self_chain],
    do: finish(state, :failed, reason)

  def handle_error(_ref, _reason, %State{phase: phase} = state)
      when phase in [:done, :failed], do: {:halt, state}

  def handle_error(_ref, _reason, state), do: {:noreply, state}

  defp finish(state, phase, error \\ nil) do
    if state.watcher, do: send(state.watcher, :finish)
    {:halt, %{state | phase: phase, error: error, synthesis_turn: false}}
  end

  defp maybe_synthesize(%State{} = state) do
    received = map_size(state.results) + map_size(state.failures)

    cond do
      received < length(state.workers) ->
        {:noreply, state}

      state.results == %{} ->
        finish(state, :failed, :all_workers_failed)

      true ->
        prompt = synthesis_prompt(state)
        {:prompt, prompt, %{state | phase: :synthesizing, synthesis_prompt: prompt}}
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
end
```

### `Fanout.Worker`

```elixir
defmodule Fanout.Worker do
  use GenAgent

  defmodule State do
    defstruct [:name, :coordinator, :run, :task, :result, :error]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      name: Keyword.fetch!(opts, :worker_name),
      coordinator: Keyword.fetch!(opts, :coordinator),
      run: Keyword.fetch!(opts, :run)
    }

    system = """
    You are a research worker. You will be given exactly one
    sub-task. Answer it in 2-3 concise sentences. No preamble.
    """

    {:ok, Keyword.merge(Keyword.get(opts, :backend_opts, []), system: system, max_tokens: 300),
     state}
  end

  @impl true
  def handle_event({:sub_task, task}, %State{} = state) do
    {:prompt, task, %{state | task: task}}
  end

  def handle_event(_other, state), do: {:noreply, state}

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    result = String.trim(response.text)
    GenAgent.notify(state.coordinator, {:worker_result, state.run, state.name, result})
    {:halt, %{state | result: result}}
  end

  @impl true
  def handle_error(_ref, reason, %State{} = state) do
    GenAgent.notify(state.coordinator, {:worker_failed, state.run, state.name, reason})
    {:halt, %{state | error: reason}}
  end
end
```

### `Fanout.Watcher`

GenAgent has no `handle_info/2` callback. This ordinary GenServer owns
worker creation so even a coordinator exit during startup cannot lose
track of a worker. It monitors the coordinator and each worker.

```elixir
defmodule Fanout.Watcher do
  use GenServer

  def start(coordinator, config), do: GenServer.start(__MODULE__, {coordinator, config})

  @impl true
  def init({coordinator, config}) do
    ref = Process.monitor(coordinator)
    {:ok, %{coordinator: coordinator, ref: ref, config: config, workers: %{}, pending: []}}
  end

  @impl true
  def handle_call({:spawn, tasks}, _from, state) do
    result =
      Enum.reduce_while(Enum.with_index(tasks, 1), {:ok, state}, fn {_task, i}, {:ok, s} ->
        c = s.config
        name = "#{c.coordinator_name}-#{c.run}-worker-#{i}"

        opts =
          Keyword.merge(c.worker_opts,
            name: name,
            backend: c.worker_backend,
            worker_name: name,
            coordinator: c.coordinator_name,
            run: c.run
          )

        case GenAgent.start_agent(Fanout.Worker, opts) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            {:cont, {:ok, %{s | workers: Map.put(s.workers, ref, {i, name})}}}

          {:error, reason} ->
            {:halt, {:error, reason, s}}
        end
      end)

    case result do
      {:ok, s} ->
        Process.send_after(self(), :deadline, s.config.collect_timeout)
        names = s.workers |> Map.values() |> Enum.sort() |> Enum.map(&elem(&1, 1))
        {:reply, {:ok, names}, s}

      {:error, reason, s} ->
        cleanup(s)
        {:stop, :normal, {:error, reason}, s}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state) do
    cleanup(state)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.workers, ref) do
      {:ok, {_, name}} ->
        enqueue(state, {:worker_down, state.config.run, name, reason})

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:deadline, state) do
    # Stop unfinished work even if notification admission is currently blocked.
    cleanup(state)
    enqueue(state, {:collect_timeout, state.config.run})
  end

  def handle_info(:deliver, %{pending: []} = state), do: {:noreply, state}

  def handle_info(:deliver, state) do
    [event | rest] = state.pending
    c = state.config

    # Never deliver an old run's event to a replacement registration.
    admitted =
      if GenAgent.whereis(c.coordinator_name) == state.coordinator do
        try do
          GenAgent.notify_ack(c.coordinator_name, event, 100) == :ok
        catch
          :exit, _ -> false
        end
      else
        false
      end

    pending = if admitted, do: rest, else: state.pending
    if pending != [], do: Process.send_after(self(), :deliver, 10)
    {:noreply, %{state | pending: pending}}
  end

  def handle_info(:finish, state) do
    cleanup(state)
    {:stop, :normal, state}
  end

  defp enqueue(state, event) do
    if state.pending == [], do: send(self(), :deliver)
    {:noreply, %{state | pending: state.pending ++ [event]}}
  end

  defp cleanup(state) do
    Enum.each(state.workers, fn {_ref, {_, name}} -> GenAgent.stop(name) end)
  end
end
```

### Failure and cleanup boundaries

Supply `worker_backend:` explicitly: GenAgent consumes the coordinator's
`backend:` before `init_agent/1`. Optional `worker_opts:` configure worker
startup (for example, `worker_opts: [backend_opts: [model: "my-model"]]`);
`collect_timeout:` bounds collection (default 5 seconds).
Duplicate, unknown, and stale reports are ignored. A worker exit counts as
a failure; a missing or rejected report becomes a timeout. Partial success
still synthesizes; no successful reports halts as failed.

Cleanup is asynchronous on every terminal path and on external coordinator
stop or crash. Do not stop workers inside `terminate_agent/2`: the shared
DynamicSupervisor can be waiting for that callback to return. Unique names
per run permit immediate reuse of the coordinator name during cleanup.
Stopping the coordinator during worker startup can stall for the shared
DynamicSupervisor's 5-second shutdown timeout: the coordinator waits for
the watcher, which may be waiting for that supervisor to start a worker.
The watcher exits after cleanup. This small unlinked helper is not durable:
a watcher crash or VM loss needs an application-owned supervision design.

Notification admission is not execution. While the coordinator is busy,
the watcher retries rejected notifications; the deadline stops workers,
but the coordinator can transition only once it processes the event. Keep
GenAgent's turn watchdog enabled and callbacks nonblocking. This is not a
hard wall-clock deadline for planning, startup, synthesis, or hung backend
termination. Extra ask/tell turns during collection or queued synthesis
still run on the backend and can delay synthesis or affect its session
history, but their responses and ordinary turn errors do not finish the workflow.
Buffered worker events enqueue synthesis behind any already queued user
turns; `pre_turn/2` recognizes the stored synthesis prompt before allowing
its response or error to finish synthesis. This matches prompt text, so
reserve that exact prompt for internal use. If the prompt queue rejects
synthesis before dispatch (count or byte limit), the coordinator fails with the overload
error and cleans up the watcher and workers. The first turn is the planning
turn; resuming a terminal coordinator halts it again without replacing
its output.

## Using it

```elixir
name = "coord-#{System.unique_integer([:positive])}"

{:ok, _pid} = GenAgent.start_agent(Fanout.Coordinator,
  name: name,
  backend: MyBackend,
  worker_backend: MyBackend,
  collect_timeout: 5_000,
  topic: "why do octopuses have three hearts?",
  max_workers: 3,
  coordinator_name: name
)

# Kick off the planning turn.
{:ok, _ref} = GenAgent.tell(name,
  "Break the topic into 3 specific sub-questions. One per line.")

# Bound the manager's wait too, including planning and synthesis.
try do
  status = Enum.reduce_while(1..300, nil, fn _, _ ->
    status = GenAgent.status(name)
    if status.agent_state.phase in [:done, :failed] do
      {:halt, status}
    else
      Process.sleep(100)
      {:cont, nil}
    end
  end)
  IO.inspect(status && status.agent_state, label: "result (nil means manager timeout)")
after
  GenAgent.stop(name)
end
```

## Variations

- **Bounded concurrency.** For very large N, instead of spawning
  N workers, spawn K and use a work-stealing loop: when one
  worker halts, the coordinator notifies a new worker with the
  next sub-task. See [Pool](pool.md) for a cleaner version of
  this shape.
- **Heterogeneous workers.** Different sub-tasks can get
  different worker modules. Adapt `Fanout.Watcher.handle_call({:spawn, ...})`
  to choose the module based on each sub-task's content.
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
