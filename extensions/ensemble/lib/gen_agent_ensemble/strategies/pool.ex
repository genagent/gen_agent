defmodule GenAgentEnsemble.Strategies.Pool do
  @moduledoc """
  Fixed-size worker pool strategy.

  N identical workers are started on init. Each `tell`/`ask` lands on
  the next free worker; idle workers rotate FIFO. When all are busy,
  prompts queue FIFO and dispatch as workers free up. Workers are
  reused across turns (their `GenAgent` processes stay alive).

  ## Options

    * `:worker_count` (required) -- integer, number of workers to
      start.
    * `:worker_template` (required) -- `{name_prefix, module, opts}`.
      Workers are named `"\#{prefix}-1"`, ..., `"\#{prefix}-N"`.

  ## Failure semantics

    * A worker's turn error fails the token it was running, and the
      worker returns to the free pool (it may recover on the next
      prompt).
    * If a worker's process dies, its in-flight token fails as
      `{:worker_down, reason}`. A fresh worker starts from the template
      under the same name and can take the next queued prompt. Its
      previous backend session and conversation history are lost.
  """

  @behaviour GenAgentEnsemble.Strategy

  alias GenAgentEnsemble.Queue

  defstruct [
    :worker_module,
    :worker_opts,
    workers: MapSet.new(),
    free: [],
    busy: %{},
    queue: nil
  ]

  @impl true
  def init(opts) do
    count = Keyword.fetch!(opts, :worker_count)
    {prefix, mod, w_opts} = Keyword.fetch!(opts, :worker_template)

    names = for i <- 1..count, do: "#{prefix}-#{i}"
    start_specs = for n <- names, do: {n, mod, w_opts}

    state = %__MODULE__{
      worker_module: mod,
      worker_opts: w_opts,
      workers: MapSet.new(names),
      free: names,
      queue: Queue.new()
    }

    {:ok, state, start_specs}
  end

  @impl true
  def handle_tell(prompt, _opts, token, state), do: dispatch_or_queue(prompt, token, state)

  @impl true
  def handle_ask(prompt, _opts, token, state), do: dispatch_or_queue(prompt, token, state)

  defp dispatch_or_queue(prompt, token, %{free: [worker | rest]} = state) do
    state = %{state | free: rest, busy: Map.put(state.busy, worker, token)}
    {:ok, [{:dispatch, worker, prompt, token}], state}
  end

  defp dispatch_or_queue(prompt, token, %{free: []} = state) do
    {:ok, [], %{state | queue: Queue.enqueue(state.queue, token, prompt)}}
  end

  @impl true
  def handle_response(worker, response, state) do
    case Map.pop(state.busy, worker) do
      {nil, _} ->
        {:ok, [], state}

      {token, busy} ->
        state = %{state | busy: busy}
        ops = [{:reply, token, response}]
        {ops, state} = maybe_dispatch_next(state, worker, ops)
        {:ok, ops, state}
    end
  end

  @impl true
  def handle_error(worker, reason, state) do
    case Map.pop(state.busy, worker) do
      {nil, _} ->
        {:ok, [], state}

      {token, busy} ->
        state = %{state | busy: busy}
        ops = [{:reply_error, token, reason}]
        {ops, state} = maybe_dispatch_next(state, worker, ops)
        {:ok, ops, state}
    end
  end

  @impl true
  def handle_dispatch_rejected(worker, token, reason, state) do
    if Map.get(state.busy, worker) == token do
      state = %{state | busy: Map.delete(state.busy, worker)}
      {ops, state} = maybe_dispatch_next(state, worker, [{:reply_error, token, reason}])
      {:ok, ops, state}
    else
      {:ok, [{:reply_error, token, reason}], state}
    end
  end

  @impl true
  def handle_agent_down(worker, reason, state) do
    if MapSet.member?(state.workers, worker) do
      free = Enum.reject(state.free, &(&1 == worker))
      {in_flight_token, busy} = Map.pop(state.busy, worker)

      fail_ops =
        case in_flight_token do
          nil -> []
          token -> [{:reply_error, token, {:worker_down, reason}}]
        end

      state = %{state | free: free, busy: busy}
      spec = {worker, state.worker_module, state.worker_opts}
      {dispatch_ops, state} = maybe_dispatch_next(state, worker, [])

      {:ok, fail_ops ++ [{:start, spec}] ++ dispatch_ops, state}
    else
      {:ok, [], state}
    end
  end

  @impl true
  def handle_notify(_event, state), do: {:ok, [], state}

  @impl true
  def handle_status(state) do
    %{
      workers: MapSet.to_list(state.workers) |> Enum.sort(),
      free: length(state.free),
      busy: map_size(state.busy),
      queued: Queue.len(state.queue)
    }
  end

  # --- helpers ---

  defp maybe_dispatch_next(state, worker, ops_so_far) do
    case Queue.pop(state.queue) do
      {:ok, {token, prompt}, rest} ->
        state = %{state | queue: rest, busy: Map.put(state.busy, worker, token)}
        {ops_so_far ++ [{:dispatch, worker, prompt, token}], state}

      :empty ->
        state = %{state | free: state.free ++ [worker]}
        {ops_so_far, state}
    end
  end
end
