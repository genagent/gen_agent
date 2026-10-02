defmodule ChaosLab.Agent do
  @moduledoc "An observable agent that retries a crashed task once."
  use GenAgent

  @impl true
  def init_agent(opts) do
    observer = Keyword.fetch!(opts, :observer)

    state = %{
      observer: observer,
      owner: self(),
      retried: false,
      responses: [],
      retry: opts[:retry] != false
    }

    {:ok, [observer: observer], state}
  end

  @impl true
  def handle_stream_event(event, state) do
    send(state.observer, {:stream, state.owner, self(), event.kind, event.data.prompt})
    state
  end

  @impl true
  def handle_response(ref, response, state) do
    send(state.observer, {:response, self(), ref, response.text})
    {:noreply, %{state | responses: state.responses ++ [response.text]}}
  end

  @impl true
  def handle_error(ref, reason, state) do
    send(state.observer, {:handle_error, self(), ref, reason})

    case {reason, state.retry, state.retried} do
      {{:task_crashed, _}, true, false} ->
        {:prompt, "retry after crash", %{state | retried: true}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate_agent(reason, state) do
    send(state.observer, {:terminated_agent, self(), reason})
    :ok
  end
end
