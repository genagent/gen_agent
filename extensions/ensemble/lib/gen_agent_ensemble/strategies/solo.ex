defmodule GenAgentEnsemble.Strategies.Solo do
  @moduledoc """
  Trivial single-agent strategy. Every `tell`/`ask` dispatches the
  prompt straight to the one sub-agent; every response closes the
  most recent pending token.

  ## Options

    * `:agent` -- required. `{name, module, opts}` spec for the one
      sub-agent.

  ## State

      %{agent: name, tokens: :queue.queue(token)}

  Tokens are tracked in a single FIFO queue. If a second `tell`/`ask`
  arrives while one is in flight, the new prompt is dispatched and
  queues up inside `GenAgent`'s own mailbox; each response or error
  closes the oldest queued token.
  """

  @behaviour GenAgentEnsemble.Strategy

  @impl true
  def init(opts) do
    {name, module, agent_opts} = Keyword.fetch!(opts, :agent)
    state = %{agent: name, tokens: :queue.new()}
    {:ok, state, [{name, module, agent_opts}]}
  end

  @impl true
  def handle_tell(prompt, _opts, token, state) do
    state = %{state | tokens: :queue.in(token, state.tokens)}
    {:ok, [{:dispatch, state.agent, prompt, token}], state}
  end

  @impl true
  def handle_ask(prompt, _opts, token, state) do
    state = %{state | tokens: :queue.in(token, state.tokens)}
    {:ok, [{:dispatch, state.agent, prompt, token}], state}
  end

  @impl true
  def handle_response(_agent, response, state) do
    case :queue.out(state.tokens) do
      {{:value, token}, rest} ->
        {:ok, [{:reply, token, response}], %{state | tokens: rest}}

      {:empty, _} ->
        {:ok, [], state}
    end
  end

  @impl true
  def handle_error(_agent, reason, state) do
    case :queue.out(state.tokens) do
      {{:value, token}, rest} ->
        {:ok, [{:reply_error, token, reason}], %{state | tokens: rest}}

      {:empty, _} ->
        {:ok, [], state}
    end
  end

  @impl true
  def handle_cancel(token, state) do
    {:ok, [], %{state | tokens: :queue.filter(&(&1 != token), state.tokens)}}
  end

  @impl true
  def handle_dispatch_rejected(_agent, token, reason, state) do
    tokens = state.tokens |> :queue.to_list() |> Enum.reject(&(&1 == token)) |> :queue.from_list()
    {:ok, [{:reply_error, token, reason}], %{state | tokens: tokens}}
  end

  @impl true
  def handle_notify(event, state) do
    {:ok, [{:forward, state.agent, event}], state}
  end

  @impl true
  def handle_agent_down(_agent, reason, state) do
    {:ok, [{:halt, {:agent_down, reason}}], state}
  end

  @impl true
  def handle_status(state) do
    %{agent: state.agent, queued_tokens: :queue.len(state.tokens)}
  end
end
