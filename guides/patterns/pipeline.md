# Pipeline

Linear N-stage transformation chain. Each stage is a distinct
single-turn agent with its own role, the output of stage N becomes
the input of stage N+1 via `GenAgent.notify/2`, and the last stage
halts with the final result on state.

## When to reach for this

You have a transformation that decomposes cleanly into a fixed
sequence of steps, each step is best modeled as its own LLM with
its own system prompt and role, and the output of one step is
exactly the input to the next. Brainstorm -> edit -> headline.
Research question -> answer -> translate -> summarize. Spec ->
design -> implementation notes.

The key difference from [Research](research.md) is that pipeline
stages are **distinct agents** with **distinct roles**, not phases
inside one agent. That matters when each step benefits from a
different system prompt, different max tokens, or potentially a
different backend.

## What it exercises in gen_agent

- **One-way cross-agent notify chain**: each stage notifies the
  next with `{:pipeline_input, text}` and then halts.
- **`handle_event/2` returning `{:prompt, text, state}`**: the
  receiving stage turns the notify into its dispatch.
- **Per-stage self-halt after one turn**: each stage is
  intentionally one-and-done via `{:halt, new_state}` from
  `handle_response/3`.
- **Nil-terminator for the last stage**: the final stage has
  `next_stage: nil` and halts without notifying anyone.
- **Failure propagation**: `handle_error/3` forwards a
  `{:pipeline_failed, reason}` notify down the chain so no
  downstream stage sits waiting forever.

## The pattern

One callback module (used for every stage; the role and
instruction are per-stage config), plus a starter that wires up
the chain.

### `Pipeline.Stage`

```elixir
defmodule Pipeline.Stage do
  use GenAgent

  defmodule State do
    defstruct [
      :name,
      :next_stage,
      :role,
      :instruction,
      :input,
      :output,
      :error,
      index: 0
    ]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      name: Keyword.fetch!(opts, :agent_name),
      next_stage: Keyword.get(opts, :next_stage),
      role: Keyword.fetch!(opts, :role),
      instruction: Keyword.fetch!(opts, :instruction),
      index: Keyword.get(opts, :index, 0)
    }

    system = "You are #{state.role}. #{state.instruction}"
    {:ok, [system: system, max_tokens: Keyword.get(opts, :max_tokens, 400)], state}
  end

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    output = String.trim(response.text)
    new_state = %{state | output: output}

    case state.next_stage do
      nil ->
        # End of pipeline. Final result is on state.output.
        {:halt, new_state}

      next ->
        GenAgent.notify(next, {:pipeline_input, output})
        {:halt, new_state}
    end
  end

  @impl true
  def handle_error(_ref, reason, %State{} = state) do
    new_state = %{state | error: reason}

    case state.next_stage do
      nil ->
        {:halt, new_state}

      next ->
        GenAgent.notify(next, {:pipeline_failed, reason})
        {:halt, new_state}
    end
  end

  @impl true
  def handle_event({:pipeline_input, text}, %State{} = state) do
    {:prompt, text, %{state | input: text}}
  end

  def handle_event({:pipeline_failed, reason}, %State{} = state) do
    new_state = %{state | error: {:upstream_failed, reason}}

    case state.next_stage do
      nil -> {:halt, new_state}
      next ->
        GenAgent.notify(next, {:pipeline_failed, reason})
        {:halt, new_state}
    end
  end

  def handle_event(_other, state), do: {:noreply, state}
end
```

### Starter

```elixir
defmodule Pipeline do
  alias Pipeline.Stage

  def run(initial_input, stages_config, opts \\ []) do
    backend = Keyword.get(opts, :backend, GenAgent.Backends.Anthropic)
    id = System.unique_integer([:positive])

    # Assign unique names per stage and compute the next-stage pointer.
    stage_names =
      stages_config
      |> Enum.with_index(1)
      |> Enum.map(fn {cfg, i} -> "pipe-#{id}-#{i}-#{cfg.name}" end)

    # next_map: stage_name -> name_of_next_stage_or_nil
    next_map =
      stage_names
      |> Enum.zip(Enum.drop(stage_names, 1) ++ [nil])
      |> Map.new()

    stages_config
    |> Enum.with_index(1)
    |> Enum.each(fn {cfg, i} ->
      name = Enum.at(stage_names, i - 1)

      {:ok, _pid} = GenAgent.start_agent(Stage,
        name: name,
        agent_name: name,
        backend: backend,
        next_stage: Map.fetch!(next_map, name),
        role: cfg.role,
        instruction: cfg.instruction,
        index: i
      )
    end)

    # Kick off the first stage with the initial input.
    [first | _] = stage_names
    {:ok, _ref} = GenAgent.tell(first, initial_input)

    {:ok, %{stages: stage_names}}
  end
end
```

## Using it

```elixir
{:ok, handle} = Pipeline.run(
  "the octopus has three hearts and blue blood",
  [
    %{
      name: "brainstorm",
      role: "a creative brainstormer",
      instruction: "Given a fact, list 3 distinct angles to write about it. One per line."
    },
    %{
      name: "editor",
      role: "a sharp editor",
      instruction: "Given a list of angles, pick the most interesting and develop it into a tight paragraph."
    },
    %{
      name: "headline",
      role: "a headline writer",
      instruction: "Given a paragraph, write ONE compelling title. Output only the title."
    }
  ]
)

# Each stage notifies the next as it completes. Wait for the
# last stage to halt:
last = List.last(handle.stages)

# In practice, a small wait loop checking:
%{agent_state: %{output: output}} = GenAgent.status(last)
IO.puts(output)

# Read the trace across all stages:
Enum.map(handle.stages, fn name ->
  %{agent_state: %{input: i, output: o, role: r}} = GenAgent.status(name)
  %{stage: name, role: r, in: i, out: o}
end)

# Clean up:
Enum.each(handle.stages, &GenAgent.stop/1)
```

## Variations

- **Per-stage backend selection.** Nothing in the pattern requires
  every stage to use the same backend. Pass a `:backend` in each
  stage config and let cheap stages (brainstorm) use a faster
  model than expensive stages (synthesis).
- **Branching pipelines.** Instead of a linear chain, have one
  stage notify multiple "next" stages with the same output, then
  a later join stage collects them. You're now halfway to the
  [Supervisor](supervisor.md) shape.
- **Reusable stages.** The same callback module can be
  instantiated many times in the same pipeline with different
  roles -- e.g. two "editor" stages in sequence with different
  instructions.
- **Conditional routing.** `handle_event({:pipeline_input, text}, state)`
  can inspect `text` before deciding what to do -- dispatch,
  transform, or `{:halt, state}` early if the upstream produced
  something bad.
