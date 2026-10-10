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
  issues `{:reply, token, response}` first, then `{:stop, worker}` per
  worker, so the caller is not delayed by worker shutdown. Stops precede
  the dispatch of the next queued run.

  ## Options

    * `:coordinator` (required) -- `{name, module, opts}` spec for the
      coordinator agent.
    * `:worker_template` (required) -- `{name_prefix, module, opts}`.
      Workers are named `"\#{prefix}-1"`, `"\#{prefix}-2"`, ...
    * `:decomposer` (required) -- `(String.t() -> [String.t()])` that
      turns coordinator output into sub-prompts.
    * `:synthesizer` (optional) -- a function accepting ordered
      `[{worker_name, text}]`, or a two-argument function also accepting
      the corresponding ordered sub-prompts. The default labels each
      worker response with its assigned sub-prompt.
    * `:max_subtasks` (optional) -- positive integer upper bound on the
      number of sub-prompts a decomposition may return. Defaults to 10.
      A decomposition with more sub-prompts fails the run with
      `{:too_many_subtasks, count, max}`; no workers are started and the
      sub-prompts are not truncated. Any other value raises
      `ArgumentError` at init.

  ## Limits

  Only one in-flight prompt at a time. If a
  second `tell`/`ask` arrives while a fan-out is in progress, it is
  queued and dispatched after the current one completes.

  If a worker that has not yet responded dies during fan-out, the current
  run and every queued request fail with `{:worker_down, worker, reason}`.
  Remaining workers are stopped, and a later fresh request may start a new
  run. The death of a worker that already responded does not fail the run
  or queued requests; it is cleaned up at fan-in.

  A `:decomposer` that raises, throws or exits, or returns anything but a
  proper list of binaries, fails the run before any worker starts. A
  caller-supplied `:synthesizer` that fails or returns a non-binary fails the run after fan-in: the caller
  gets the error first, then every worker is stopped. Either way the caller
  receives `{:error, {:strategy_function_failed, label, kind, class}}` or
  `{:error, {:invalid_strategy_result, label}}` with `label` `:decomposer` or
  `:synthesizer`, `kind` `:error`, `:throw` or `:exit`, and `class` the
  exception module or `:other`. Messages, stacktraces and returned values are
  never included. The session keeps running and queued requests proceed.

  The coordinator name must not equal a generated worker name
  (`"\#{prefix}-N"` for N in `1..max_subtasks`); init raises
  `ArgumentError` otherwise.
  """

  @behaviour GenAgentEnsemble.Strategy

  alias GenAgent.Response
  alias GenAgentEnsemble.Queue
  alias GenAgentEnsemble.Strategies.Guard
  alias GenAgentEnsemble.Usage

  @default_max_subtasks 10

  defstruct [
    :coordinator,
    :worker_prefix,
    :worker_module,
    :worker_opts,
    :decomposer,
    :synthesizer,
    max_subtasks: @default_max_subtasks,
    custom_synthesizer?: false,
    subtasks: [],
    phase: :idle,
    queue: nil,
    usage: Usage.new()
  ]

  @impl true
  def init(opts) do
    {c_name, c_mod, c_opts} = Keyword.fetch!(opts, :coordinator)
    {w_prefix, w_mod, w_opts} = Keyword.fetch!(opts, :worker_template)
    decomposer = Keyword.fetch!(opts, :decomposer)
    synthesizer = Keyword.get(opts, :synthesizer, &default_synthesizer/2)
    max_subtasks = Keyword.get(opts, :max_subtasks, @default_max_subtasks)

    unless is_function(decomposer, 1) do
      raise ArgumentError,
            "Supervisor :decomposer must be a 1-arity function, got: #{inspect(decomposer)}"
    end

    unless is_function(synthesizer, 1) or is_function(synthesizer, 2) do
      raise ArgumentError,
            "Supervisor :synthesizer must be a 1- or 2-arity function, got: " <>
              inspect(synthesizer)
    end

    unless is_integer(max_subtasks) and max_subtasks > 0 do
      raise ArgumentError,
            "Supervisor :max_subtasks must be a positive integer, got: #{inspect(max_subtasks)}"
    end

    if generated_worker_name?(c_name, w_prefix, max_subtasks) do
      raise ArgumentError,
            "Supervisor :coordinator name #{inspect(c_name)} collides with a generated " <>
              "worker name (#{inspect(w_prefix)}-1 .. #{inspect(w_prefix)}-#{max_subtasks})"
    end

    state = %__MODULE__{
      coordinator: c_name,
      worker_prefix: w_prefix,
      worker_module: w_mod,
      worker_opts: w_opts,
      decomposer: decomposer,
      synthesizer: synthesizer,
      custom_synthesizer?: Keyword.has_key?(opts, :synthesizer),
      max_subtasks: max_subtasks,
      queue: Queue.new()
    }

    {:ok, state, [{c_name, c_mod, c_opts}]}
  end

  # Parses the name instead of enumerating 1..max_subtasks, so a large limit
  # costs nothing. Only the canonical form "prefix-N" (N in 1..max) collides.
  defp generated_worker_name?(name, prefix, max_subtasks) do
    with true <- is_binary(name),
         marker = "#{prefix}-",
         true <- String.starts_with?(name, marker),
         suffix = binary_part(name, byte_size(marker), byte_size(name) - byte_size(marker)),
         {index, ""} <- Integer.parse(suffix) do
      index >= 1 and index <= max_subtasks and Integer.to_string(index) == suffix
    else
      _ -> false
    end
  end

  @impl true
  def handle_tell(prompt, _opts, token, state), do: start_or_queue(prompt, token, state)

  @impl true
  def handle_ask(prompt, _opts, token, state), do: start_or_queue(prompt, token, state)

  defp start_or_queue(prompt, token, %{phase: :idle} = state) do
    state = %{state | usage: Usage.new(), subtasks: [], phase: {:decomposing, token}}
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

    case Guard.call(:decomposer, state.decomposer, [response.text], &sub_prompts?/1) do
      {:ok, sub_prompts} when length(sub_prompts) > state.max_subtasks ->
        reject_decomposition(
          token,
          {:too_many_subtasks, length(sub_prompts), state.max_subtasks},
          state
        )

      {:ok, sub_prompts} ->
        fan_out(token, response, sub_prompts, state)

      {:error, reason} ->
        reject_decomposition(token, reason, state)
    end
  end

  # Total: any term, including an improper list, yields a boolean.
  defp sub_prompts?([]), do: true
  defp sub_prompts?([head | tail]), do: is_binary(head) and sub_prompts?(tail)
  defp sub_prompts?(_), do: false

  defp reject_decomposition(token, reason, state) do
    state = %{state | phase: :idle, subtasks: []}
    {ops, state} = maybe_append_next(state, [{:reply_error, token, reason}])
    {:ok, ops, state}
  end

  defp fan_out(token, response, sub_prompts, state) do
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
        state = %{state | phase: :idle, subtasks: []}
        {ops, state} = maybe_append_next(state, [{:reply, token, response}])
        {:ok, ops, state}

      _ ->
        {:ok, ops, %{state | phase: {:fanning_out, token, progress}, subtasks: sub_prompts}}
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

    args =
      if is_function(state.synthesizer, 2),
        do: [worker_outputs, state.subtasks],
        else: [worker_outputs]

    # Reply (or error) first, then worker cleanup, then the next queued run.
    reply_op =
      case synthesize(state, args) do
        {:ok, combined} ->
          {:reply, token, %Response{text: combined, usage: Usage.to_usage(state.usage)}}

        {:error, reason} ->
          {:reply_error, token, reason}
      end

    stop_ops = Enum.map(progress, fn {worker, _} -> {:stop, worker} end)

    state = %{state | phase: :idle, subtasks: []}
    {ops, state} = maybe_append_next(state, [reply_op | stop_ops])
    {:ok, ops, state}
  end

  # Only a caller-supplied synthesizer is user code. The built-in default
  # runs unguarded so its own failures (corrupted strategy state) propagate.
  defp synthesize(%{custom_synthesizer?: true} = state, args),
    do: Guard.call(:synthesizer, state.synthesizer, args, &is_binary/1)

  defp synthesize(state, args), do: {:ok, apply(state.synthesizer, args)}

  defp maybe_append_next(%{phase: :idle} = state, ops_so_far) do
    case Queue.pop(state.queue) do
      {:ok, {token, prompt}, rest} ->
        state = %{
          state
          | usage: Usage.new(),
            subtasks: [],
            phase: {:decomposing, token},
            queue: rest
        }

        {ops_so_far ++ [{:dispatch, state.coordinator, prompt, token}], state}

      :empty ->
        {ops_so_far, state}
    end
  end

  @impl true
  def handle_error(agent, reason, state) do
    case state.phase do
      {:decomposing, token} when agent == state.coordinator ->
        state = %{state | phase: :idle, subtasks: []}
        {ops, state} = maybe_append_next(state, [{:reply_error, token, reason}])
        {:ok, ops, state}

      {:fanning_out, token, progress} ->
        stop_ops = for {worker, _} <- progress, do: {:stop, worker}
        state = %{state | phase: :idle, subtasks: []}

        {ops, state} =
          maybe_append_next(state, stop_ops ++ [{:reply_error, token, {agent, reason}}])

        {:ok, ops, state}

      _ ->
        {:ok, [], state}
    end
  end

  @impl true
  def handle_cancel(token, state) do
    state = %{state | queue: Queue.delete(state.queue, token)}

    case state.phase do
      {:decomposing, ^token} ->
        cancel_run(state, [])

      {:fanning_out, ^token, progress} ->
        cancel_run(state, Enum.map(progress, fn {worker, _} -> {:stop, worker} end))

      _ ->
        {:ok, [], state}
    end
  end

  defp cancel_run(state, stop_ops) do
    state = %{state | phase: :idle, subtasks: [], usage: Usage.new()}
    {ops, state} = maybe_append_next(state, stop_ops)
    {:ok, ops, state}
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

    # A worker that already reported (`{:done, _}`) has nothing left to lose;
    # its later death must not fail the run or the queued requests.
    if Map.get(progress, agent) == :pending do
      failure = {:worker_down, agent, reason}
      stop_ops = for {worker, _} <- progress, worker != agent, do: {:stop, worker}
      fail_ops = [{:reply_error, token, failure} | queued_fail_ops(state.queue, failure)]
      state = %{state | phase: :idle, subtasks: [], queue: Queue.new()}
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

  defp default_synthesizer(worker_outputs, subtasks) do
    worker_outputs
    |> Enum.zip(subtasks)
    |> Enum.map_join("\n\n", fn {{_worker, text}, subtask} ->
      "### #{subtask}\n\n#{text}"
    end)
  end
end
