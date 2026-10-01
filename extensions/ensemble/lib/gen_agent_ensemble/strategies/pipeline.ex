defmodule GenAgentEnsemble.Strategies.Pipeline do
  @moduledoc """
  Linear stage chain.

  N agents run in order. The incoming prompt hits stage 1. Each
  stage's response text becomes the prompt for the next stage. The
  last stage's response is the reply returned to the caller.

  ## Options

    * `:stages` (required) -- a list of `{name, module, opts}` specs,
      one per stage, in order. Must be non-empty.

  ## Concurrency

  At most one prompt is in-flight at a time. Additional `tell`/`ask`
  calls queue FIFO and begin when the current pipeline completes.

  ## Failure semantics

  A stage's turn error aborts the pipeline: the token fails with
  `{stage_name, reason}` and the next queued prompt (if any) starts.
  Stage process death halts the session (the chain is unrepairable).
  """

  @behaviour GenAgentEnsemble.Strategy

  alias GenAgentEnsemble.Queue

  defstruct stages: [],
            phase: :idle,
            queue: nil

  @impl true
  def init(opts) do
    stages = Keyword.fetch!(opts, :stages)

    if stages == [], do: raise(ArgumentError, "pipeline requires at least one stage")

    stage_names = Enum.map(stages, fn {name, _, _} -> name end)

    state = %__MODULE__{stages: stage_names, queue: Queue.new()}
    {:ok, state, stages}
  end

  @impl true
  def handle_tell(prompt, _opts, token, state), do: dispatch_or_queue(prompt, token, state)

  @impl true
  def handle_ask(prompt, _opts, token, state), do: dispatch_or_queue(prompt, token, state)

  defp dispatch_or_queue(prompt, token, %{phase: :idle} = state) do
    first = hd(state.stages)
    {:ok, [{:dispatch, first, prompt, token}], %{state | phase: {:in_stage, 0, token}}}
  end

  defp dispatch_or_queue(prompt, token, state) do
    {:ok, [], %{state | queue: Queue.enqueue(state.queue, token, prompt)}}
  end

  @impl true
  def handle_response(stage, response, state) do
    case state.phase do
      {:in_stage, idx, token} ->
        expected = Enum.at(state.stages, idx)

        if stage == expected do
          advance(idx, token, response, state)
        else
          {:ok, [], state}
        end

      _ ->
        {:ok, [], state}
    end
  end

  defp advance(idx, token, response, state) do
    next_idx = idx + 1

    if next_idx < length(state.stages) do
      next_stage = Enum.at(state.stages, next_idx)

      {:ok, [{:dispatch, next_stage, response.text, token}],
       %{state | phase: {:in_stage, next_idx, token}}}
    else
      state = %{state | phase: :idle}
      {ops, state} = maybe_start_next(state, [{:reply, token, response}])
      {:ok, ops, state}
    end
  end

  @impl true
  def handle_error(stage, reason, state) do
    case state.phase do
      {:in_stage, _idx, token} ->
        state = %{state | phase: :idle}
        {ops, state} = maybe_start_next(state, [{:reply_error, token, {stage, reason}}])
        {:ok, ops, state}

      _ ->
        {:ok, [], state}
    end
  end

  @impl true
  def handle_dispatch_rejected(stage, token, reason, state) do
    case state.phase do
      {:in_stage, _idx, ^token} -> handle_error(stage, reason, state)
      _ -> {:ok, [{:reply_error, token, {stage, reason}}], state}
    end
  end

  @impl true
  def handle_agent_down(_stage, reason, state) do
    {:ok, [{:halt, {:stage_down, reason}}], state}
  end

  @impl true
  def handle_notify(_event, state), do: {:ok, [], state}

  @impl true
  def handle_status(state) do
    phase =
      case state.phase do
        :idle -> :idle
        {:in_stage, idx, _token} -> {:in_stage, Enum.at(state.stages, idx)}
      end

    %{stages: state.stages, phase: phase, queued: Queue.len(state.queue)}
  end

  defp maybe_start_next(%{phase: :idle} = state, ops_so_far) do
    case Queue.pop(state.queue) do
      {:ok, {token, prompt}, rest} ->
        first = hd(state.stages)

        state = %{state | phase: {:in_stage, 0, token}, queue: rest}
        {ops_so_far ++ [{:dispatch, first, prompt, token}], state}

      :empty ->
        {ops_so_far, state}
    end
  end
end
