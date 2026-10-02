defmodule GenAgentEnsemble.Strategies.Supervisor do
  @moduledoc """
  Deterministic fan-out strategy: one coordinator agent decomposes a
  prompt, the strategy spawns N worker agents with the decomposed
  sub-prompts, and a reply lands when all workers have responded.

  The first `handle_response` comes from the coordinator and carries
  the full decomposition output. A user-supplied `:decomposer` function
  turns that output into a list of sub-prompts. The strategy then
  issues `{:start, ...}` + `{:dispatch, ...}` ops for each worker.

  When every worker has reported back, the strategy concatenates their
  responses (or runs a user-supplied `:synthesizer` if given) and
  issues `{:reply, token, response}` plus `{:stop, worker}` per worker.

  ## Options

    * `:coordinator` (required) -- `{name, module, opts}` spec for the
      coordinator agent.
    * `:worker_template` (required) -- `{name_prefix, module, opts}`.
      Workers are named `"\#{prefix}-1"`, `"\#{prefix}-2"`, ...
    * `:decomposer` (required) -- `(String.t() -> [String.t()])` that
      turns coordinator output into sub-prompts.
    * `:synthesizer` (optional) -- `([{worker_name, String.t()}] -> String.t())`.
      Defaults to joining worker outputs with "\\n\\n".

  ## Limits

  Only one in-flight prompt at a time in this first version. If a
  second `tell`/`ask` arrives while a fan-out is in progress, it is
  queued and dispatched after the current one completes.

  If a worker process dies during fan-out, the current run and every
  queued request fail with `{:worker_down, worker, reason}`. Remaining
  workers are stopped, and a later fresh request may start a new run.
  """

  @behaviour GenAgentEnsemble.Strategy

  alias GenAgent.Response
  alias GenAgentEnsemble.Queue
  alias GenAgentEnsemble.Usage

  defstruct [
    :coordinator,
    :worker_prefix,
    :worker_module,
    :worker_opts,
    :decomposer,
    :synthesizer,
    phase: :idle,
    queue: nil,
    usage: Usage.new()
  ]

  @impl true
  def init(opts) do
    {c_name, c_mod, c_opts} = Keyword.fetch!(opts, :coordinator)
    {w_prefix, w_mod, w_opts} = Keyword.fetch!(opts, :worker_template)
    decomposer = Keyword.fetch!(opts, :decomposer)
    synthesizer = Keyword.get(opts, :synthesizer, &default_synthesizer/1)

    state = %__MODULE__{
      coordinator: c_name,
      worker_prefix: w_prefix,
      worker_module: w_mod,
      worker_opts: w_opts,
      decomposer: decomposer,
      synthesizer: synthesizer,
      queue: Queue.new()
    }

    {:ok, state, [{c_name, c_mod, c_opts}]}
  end

  @impl true
  def handle_tell(prompt, _opts, token, state), do: start_or_queue(prompt, token, state)

  @impl true
  def handle_ask(prompt, _opts, token, state), do: start_or_queue(prompt, token, state)

  defp start_or_queue(prompt, token, %{phase: :idle} = state) do
    state = %{state | usage: Usage.new(), phase: {:decomposing, token}}
    {:ok, [{:dispatch, state.coordinator, prompt, token}], state}
  end

  defp start_or_queue(prompt, token, state) do
    {:ok, [], %{state | queue: Queue.enqueue(state.queue, token, prompt)}}
  end

  @impl true
  def handle_response(agent, response, state) do
    case state.phase do
      {:decomposing, token} when agent == state.coordinator ->
        decompose(token, response, state)

      {:fanning_out, token, progress} ->
        collect_worker(agent, response, token, progress, state)

      _ ->
        {:ok, [], state}
    end
  end

  defp decompose(token, response, state) do
    state = %{state | usage: Usage.add(state.usage, state.coordinator, response.usage)}
    sub_prompts = state.decomposer.(response.text)

    {op_lists, progress} =
      sub_prompts
      |> Enum.with_index(1)
      |> Enum.map_reduce(%{}, fn {prompt, i}, prog_acc ->
        worker = "#{state.worker_prefix}-#{i}"
        spec = {worker, state.worker_module, state.worker_opts}
        ops = [{:start, spec}, {:dispatch, worker, prompt, token}]
        {ops, Map.put(prog_acc, worker, :pending)}
      end)

    ops = Enum.concat(op_lists)

    case map_size(progress) do
      0 ->
        response = %{response | usage: Usage.to_usage(state.usage)}
        # Nothing to fan out; reply immediately with coordinator's text.
        state = %{state | phase: :idle}
        {ops, state} = maybe_prepend_next(state, [{:reply, token, response}])
        {:ok, ops, state}

      _ ->
        {:ok, ops, %{state | phase: {:fanning_out, token, progress}}}
    end
  end

  defp collect_worker(agent, response, token, progress, state) do
    state = %{state | usage: Usage.add(state.usage, agent, response.usage)}
    progress = Map.put(progress, agent, {:done, response})

    if Enum.all?(progress, fn {_, v} -> match?({:done, _}, v) end) do
      finalize(token, progress, state)
    else
      {:ok, [], %{state | phase: {:fanning_out, token, progress}}}
    end
  end

  defp finalize(token, progress, state) do
    worker_outputs =
      progress
      |> Enum.map(fn {worker, {:done, resp}} -> {worker, resp.text} end)
      |> Enum.sort_by(fn {worker, _} ->
        worker
        |> String.replace_prefix("#{state.worker_prefix}-", "")
        |> String.to_integer()
      end)

    combined = state.synthesizer.(worker_outputs)
    final_response = %Response{text: combined, usage: Usage.to_usage(state.usage)}
    stop_ops = Enum.map(progress, fn {worker, _} -> {:stop, worker} end)

    state = %{state | phase: :idle}
    {ops, state} = maybe_prepend_next(state, stop_ops ++ [{:reply, token, final_response}])
    {:ok, ops, state}
  end

  defp maybe_prepend_next(%{phase: :idle} = state, ops_so_far) do
    case Queue.pop(state.queue) do
      {:ok, {token, prompt}, rest} ->
        state = %{state | usage: Usage.new(), phase: {:decomposing, token}, queue: rest}
        {ops_so_far ++ [{:dispatch, state.coordinator, prompt, token}], state}

      :empty ->
        {ops_so_far, state}
    end
  end

  @impl true
  def handle_error(agent, reason, state) do
    case state.phase do
      {:decomposing, token} when agent == state.coordinator ->
        state = %{state | phase: :idle}
        {ops, state} = maybe_prepend_next(state, [{:reply_error, token, reason}])
        {:ok, ops, state}

      {:fanning_out, token, progress} ->
        stop_ops = for {worker, _} <- progress, do: {:stop, worker}
        state = %{state | phase: :idle}

        {ops, state} =
          maybe_prepend_next(state, stop_ops ++ [{:reply_error, token, {agent, reason}}])

        {:ok, ops, state}

      _ ->
        {:ok, [], state}
    end
  end

  @impl true
  def handle_dispatch_rejected(agent, token, reason, state) do
    case state.phase do
      {:decomposing, ^token} -> handle_error(agent, reason, state)
      {:fanning_out, ^token, _} -> handle_error(agent, reason, state)
      _ -> {:ok, [{:reply_error, token, {agent, reason}}], state}
    end
  end

  @impl true
  def handle_notify(_event, state), do: {:ok, [], state}

  @impl true
  def handle_agent_down(agent, reason, state) do
    cond do
      agent == state.coordinator ->
        {:ok, [{:halt, {:coordinator_down, reason}}], state}

      match?({:fanning_out, _, _}, state.phase) ->
        fail_fan_out_on_worker_down(agent, reason, state)

      true ->
        {:ok, [], state}
    end
  end

  defp fail_fan_out_on_worker_down(agent, reason, state) do
    {:fanning_out, token, progress} = state.phase

    if Map.has_key?(progress, agent) do
      failure = {:worker_down, agent, reason}
      stop_ops = for {worker, _} <- progress, worker != agent, do: {:stop, worker}
      fail_ops = [{:reply_error, token, failure} | queued_fail_ops(state.queue, failure)]
      state = %{state | phase: :idle, queue: Queue.new()}
      {:ok, stop_ops ++ fail_ops, state}
    else
      {:ok, [], state}
    end
  end

  defp queued_fail_ops(queue, reason), do: queued_fail_ops(queue, reason, [])

  defp queued_fail_ops(queue, reason, acc) do
    case Queue.pop(queue) do
      {:ok, {token, _prompt}, rest} ->
        queued_fail_ops(rest, reason, [{:reply_error, token, reason} | acc])

      :empty ->
        Enum.reverse(acc)
    end
  end

  @impl true
  def handle_status(state) do
    %{
      coordinator: state.coordinator,
      phase: phase_summary(state.phase),
      queued: Queue.len(state.queue)
    }
  end

  defp phase_summary(:idle), do: :idle
  defp phase_summary({:decomposing, _}), do: :decomposing

  defp phase_summary({:fanning_out, _, progress}) do
    done = Enum.count(progress, fn {_, v} -> match?({:done, _}, v) end)
    {:fanning_out, done, map_size(progress)}
  end

  defp default_synthesizer(worker_outputs) do
    Enum.map_join(worker_outputs, "\n\n", fn {_worker, text} -> text end)
  end
end
