defmodule GenAgentEnsemble.Strategies.Switchboard do
  @moduledoc """
  Caller-routed strategy: N named sub-agents; every `tell`/`ask`
  specifies its target agent via `opts[:agent]`.

  No decomposition, no coordination across agents, no default
  target -- if the caller doesn't say which agent, the call fails
  loud with `{:error, :no_agent_specified}`. Pick this strategy
  when you want an explicit routed fleet ("the code review team")
  rather than an implicit pool or a decomposing coordinator.

  ## Options

    * `:agents` (required) -- list of `{name, module, opts}` specs,
      one per sub-agent. Must be non-empty (an empty fleet raises
      `ArgumentError` at init). Names must be unique within this ensemble.

  ## Addressing

      iex> E.ask!("reviewers", "review this API", agent: "alice")
      iex> E.tell("reviewers", "review this PR", agent: "bob")

  ## State

      %{
        agents: MapSet.of(names),
        pending: %{agent_name => :queue.queue(token)}
      }

  Tokens queue per-agent in FIFO order. When an agent completes a
  turn, the oldest queued token for that agent is replied to.

  ## Failure modes

  Routing errors close the token rather than raising. `ask` returns
  the error immediately; `tell` still returns `{:ok, token}`, and the
  error is delivered later through `await`, `poll`, or `inbox`.

    * `opts[:agent]` missing -- `{:error, :no_agent_specified}`
    * `opts[:agent]` not in the fleet -- `{:error, {:unknown_agent, name}}`
    * An agent's turn errors -- that token fails; the agent stays
      available for subsequent turns.
    * An agent dies -- its pending tokens all fail with
      `{:agent_down, reason}` and it is removed from the fleet, so
      later calls addressed to it fail with `{:unknown_agent, name}`;
      remaining agents keep serving.
    * All agents die -- the session halts.
  """

  @behaviour GenAgentEnsemble.Strategy

  defstruct [:agents, :pending]

  @impl true
  def init(opts) do
    specs = Keyword.fetch!(opts, :agents)
    names = for {name, _mod, _opts} <- specs, do: name

    if names == [] do
      raise ArgumentError, "Switchboard requires at least 1 agent, got none"
    end

    # Reject duplicate names at init time for a clear error.
    case names -- Enum.uniq(names) do
      [] -> :ok
      dupes -> raise ArgumentError, "Switchboard duplicate agents: #{inspect(dupes)}"
    end

    state = %__MODULE__{
      agents: MapSet.new(names),
      pending: Map.new(names, fn n -> {n, :queue.new()} end)
    }

    {:ok, state, specs}
  end

  @impl true
  def handle_tell(prompt, opts, token, state), do: route(prompt, opts, token, state)

  @impl true
  def handle_ask(prompt, opts, token, state), do: route(prompt, opts, token, state)

  defp route(prompt, opts, token, state) do
    case Keyword.fetch(opts, :agent) do
      :error ->
        {:ok, [{:reply_error, token, :no_agent_specified}], state}

      {:ok, name} ->
        if MapSet.member?(state.agents, name) do
          queue = Map.fetch!(state.pending, name)
          state = put_in(state.pending[name], :queue.in(token, queue))
          {:ok, [{:dispatch, name, prompt, token}], state}
        else
          {:ok, [{:reply_error, token, {:unknown_agent, name}}], state}
        end
    end
  end

  @impl true
  def handle_response(agent, response, state) do
    case pop_token(state, agent) do
      {nil, state} -> {:ok, [], state}
      {token, state} -> {:ok, [{:reply, token, response}], state}
    end
  end

  @impl true
  def handle_error(agent, reason, state) do
    case pop_token(state, agent) do
      {nil, state} -> {:ok, [], state}
      {token, state} -> {:ok, [{:reply_error, token, reason}], state}
    end
  end

  @impl true
  def handle_cancel(token, state) do
    pending =
      Map.new(state.pending, fn {agent, queue} ->
        {agent, :queue.filter(&(&1 != token), queue)}
      end)

    {:ok, [], %{state | pending: pending}}
  end

  @impl true
  def handle_dispatch_rejected(agent, token, reason, state) do
    queue = Map.fetch!(state.pending, agent)
    queue = queue |> :queue.to_list() |> Enum.reject(&(&1 == token)) |> :queue.from_list()
    {:ok, [{:reply_error, token, reason}], put_in(state.pending[agent], queue)}
  end

  @impl true
  def handle_agent_down(agent, reason, state) do
    if MapSet.member?(state.agents, agent) do
      {tokens, state} = drain_agent_tokens(state, agent)
      state = %{state | agents: MapSet.delete(state.agents, agent)}

      fail_ops =
        for token <- tokens, do: {:reply_error, token, {:agent_down, reason}}

      if MapSet.size(state.agents) == 0 do
        {:ok, fail_ops ++ [{:halt, :switchboard_exhausted}], state}
      else
        {:ok, fail_ops, state}
      end
    else
      {:ok, [], state}
    end
  end

  @impl true
  def handle_notify(_event, state), do: {:ok, [], state}

  @impl true
  def handle_status(state) do
    %{
      agents: MapSet.to_list(state.agents) |> Enum.sort(),
      pending_per_agent: Map.new(state.pending, fn {name, queue} -> {name, :queue.len(queue)} end)
    }
  end

  # --- helpers ---

  defp pop_token(state, agent) do
    case Map.fetch(state.pending, agent) do
      {:ok, queue} ->
        case :queue.out(queue) do
          {{:value, token}, rest} ->
            {token, put_in(state.pending[agent], rest)}

          {:empty, _} ->
            {nil, state}
        end

      :error ->
        {nil, state}
    end
  end

  defp drain_agent_tokens(state, agent) do
    case Map.pop(state.pending, agent) do
      {nil, pending} ->
        {[], %{state | pending: pending}}

      {queue, pending} ->
        {:queue.to_list(queue), %{state | pending: pending}}
    end
  end
end
