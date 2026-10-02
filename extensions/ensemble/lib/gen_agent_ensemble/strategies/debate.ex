defmodule GenAgentEnsemble.Strategies.Debate do
  @moduledoc """
  Two agents take turns arguing about a prompt until they converge
  or a round cap is reached.

  The incoming prompt hits the first agent. That agent's response
  text becomes the prompt for the second agent, whose response
  becomes the prompt for the first again, and so on. Each agent's
  own `GenAgent` session keeps the full back-and-forth in its
  backend memory, so turn N sees turns 1..N-1 in context.

  ## Options

    * `:agents` (required) -- exactly two `{name, module, opts}`
      specs. Names must be distinct.
    * `:first` (optional) -- name of the agent who speaks first.
      Defaults to the first entry in `:agents`.
    * `:rounds` (optional) -- hard cap on total agent responses.
      Defaults to 6 (three exchanges per side).
    * `:converge` (optional) -- `(String.t() -> boolean())`. Called
      on each response's text starting from turn 2. Returning `true`
      ends the debate immediately. Defaults to `fn _ -> false end`
      (round cap only).
    * `:reply` (optional) -- how to shape the final response:
        * `:transcript` (default) -- join every turn as
          `"\#{agent}:\\n\#{text}"`, separated by blank lines.
        * `:last` -- just the last agent's response text.
        * `{:synthesize, fun}` -- call `fun.(transcript)` where
          transcript is `[{agent_name, text}, ...]` in order.

  ## Concurrency

  One debate runs at a time. Additional `tell`/`ask` calls queue FIFO
  and begin when the current debate completes.

  ## Failure semantics

    * A turn error aborts the debate: token fails with the backend
      reason; next queued prompt (if any) starts.
    * If either agent's process dies, the session halts -- neither
      agent alone can debate.
  """

  @behaviour GenAgentEnsemble.Strategy

  alias GenAgent.Response
  alias GenAgentEnsemble.Queue
  alias GenAgentEnsemble.Usage

  defstruct [
    :a,
    :b,
    :first,
    :rounds,
    :converge,
    :reply_kind,
    agents: MapSet.new(),
    phase: :idle,
    queue: nil,
    usage: Usage.new()
  ]

  @impl true
  def init(opts) do
    specs = Keyword.fetch!(opts, :agents)

    case specs do
      [{_, _, _}, {_, _, _}] ->
        :ok

      _ ->
        raise ArgumentError,
              "Debate requires exactly 2 agents, got #{length(specs)}: #{inspect(specs)}"
    end

    [{a_name, _, _}, {b_name, _, _}] = specs

    if a_name == b_name do
      raise ArgumentError, "Debate agent names must be distinct, got #{inspect(a_name)} twice"
    end

    first = Keyword.get(opts, :first, a_name)

    unless first in [a_name, b_name] do
      raise ArgumentError,
            "Debate :first must be one of #{inspect([a_name, b_name])}, got #{inspect(first)}"
    end

    rounds = Keyword.get(opts, :rounds, 6)
    converge = Keyword.get(opts, :converge, fn _ -> false end)
    reply_kind = Keyword.get(opts, :reply, :transcript)

    state = %__MODULE__{
      a: a_name,
      b: b_name,
      first: first,
      rounds: rounds,
      converge: converge,
      reply_kind: reply_kind,
      agents: MapSet.new([a_name, b_name]),
      queue: Queue.new()
    }

    {:ok, state, specs}
  end

  @impl true
  def handle_tell(prompt, _opts, token, state), do: start_or_queue(prompt, token, state)

  @impl true
  def handle_ask(prompt, _opts, token, state), do: start_or_queue(prompt, token, state)

  defp start_or_queue(prompt, token, %{phase: :idle} = state) do
    phase = {:running, token, state.first, 0, []}
    {:ok, [{:dispatch, state.first, prompt, token}], %{state | phase: phase, usage: Usage.new()}}
  end

  defp start_or_queue(prompt, token, state) do
    {:ok, [], %{state | queue: Queue.enqueue(state.queue, token, prompt)}}
  end

  @impl true
  def handle_response(agent, response, state) do
    case state.phase do
      {:running, token, awaiting, turns, transcript} when agent == awaiting ->
        advance(token, agent, response, turns, transcript, state)

      _ ->
        {:ok, [], state}
    end
  end

  defp advance(token, agent, response, turns, transcript, state) do
    state = %{state | usage: Usage.add(state.usage, agent, response.usage)}
    transcript = transcript ++ [{agent, response.text}]
    turns = turns + 1
    converged? = turns >= 2 and safely_converged?(state.converge, response.text)

    if converged? or turns >= state.rounds do
      finalize(token, transcript, state)
    else
      other = other_agent(agent, state)

      {:ok, [{:dispatch, other, response.text, token}],
       %{state | phase: {:running, token, other, turns, transcript}}}
    end
  end

  defp safely_converged?(fun, text) do
    fun.(text) == true
  end

  defp other_agent(name, %{a: a, b: b}) when name == a, do: b
  defp other_agent(name, %{a: a, b: b}) when name == b, do: a

  defp finalize(token, transcript, state) do
    text = render_reply(state.reply_kind, transcript)
    response = %Response{text: text, usage: Usage.to_usage(state.usage)}
    state = %{state | phase: :idle}
    {ops, state} = maybe_start_next(state, [{:reply, token, response}])
    {:ok, ops, state}
  end

  defp render_reply(:transcript, transcript) do
    Enum.map_join(transcript, "\n\n", fn {agent, text} -> "#{agent}:\n#{text}" end)
  end

  defp render_reply(:last, transcript) do
    case List.last(transcript) do
      {_agent, text} -> text
      nil -> ""
    end
  end

  defp render_reply({:synthesize, fun}, transcript), do: fun.(transcript)

  defp maybe_start_next(%{phase: :idle} = state, ops_so_far) do
    case Queue.pop(state.queue) do
      {:ok, {token, prompt}, rest} ->
        state = %{
          state
          | phase: {:running, token, state.first, 0, []},
            queue: rest,
            usage: Usage.new()
        }

        {ops_so_far ++ [{:dispatch, state.first, prompt, token}], state}

      :empty ->
        {ops_so_far, state}
    end
  end

  @impl true
  def handle_error(_agent, reason, state) do
    case state.phase do
      {:running, token, _, _, _} ->
        state = %{state | phase: :idle}
        {ops, state} = maybe_start_next(state, [{:reply_error, token, reason}])
        {:ok, ops, state}

      _ ->
        {:ok, [], state}
    end
  end

  @impl true
  def handle_cancel(token, state) do
    state = %{state | queue: Queue.delete(state.queue, token)}

    case state.phase do
      {:running, ^token, _, _, _} ->
        {ops, state} = maybe_start_next(%{state | phase: :idle, usage: Usage.new()}, [])
        {:ok, ops, state}

      _ ->
        {:ok, [], state}
    end
  end

  @impl true
  def handle_dispatch_rejected(agent, token, reason, state) do
    case state.phase do
      {:running, ^token, _, _, _} -> handle_error(agent, reason, state)
      _ -> {:ok, [{:reply_error, token, reason}], state}
    end
  end

  @impl true
  def handle_agent_down(_agent, reason, state) do
    {:ok, [{:halt, {:agent_down, reason}}], state}
  end

  @impl true
  def handle_notify(_event, state), do: {:ok, [], state}

  @impl true
  def handle_status(state) do
    phase =
      case state.phase do
        :idle ->
          :idle

        {:running, _token, awaiting, turns, transcript} ->
          %{awaiting: awaiting, turns: turns, transcript_len: length(transcript)}
      end

    %{
      agents: [state.a, state.b],
      first: state.first,
      rounds: state.rounds,
      phase: phase,
      queued: Queue.len(state.queue)
    }
  end
end
