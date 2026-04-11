defmodule GenAgent.Support.TestAgent do
  @moduledoc """
  A GenAgent implementation used by the state-machine tests.

  The whole point of this module is to be controllable from the test body:

    * `:responder` is a 3-arity function `(ref, response, state) -> callback_return`
      that decides what `handle_response/3` returns. Defaults to `{:noreply, state}`.
    * `:event_handler` is a 2-arity function `(event, state) -> callback_return`
      that decides what `handle_event/2` returns. Defaults to `{:noreply, state}`.
    * `:notify_pid` -- if set, all callback invocations are echoed to this
      pid as `{:test_agent, callback_name, args}` tuples so tests can assert
      on callback ordering.

  The `State` struct accumulates a full trace of everything the agent saw:
  responses, events, stream events. Tests read it via `GenAgent.Server.call`
  with `:status` to peek at `agent_state`.
  """

  @behaviour GenAgent

  defmodule State do
    @moduledoc false
    defstruct responses: [],
              errors: [],
              events: [],
              stream_events: [],
              responder: nil,
              error_handler: nil,
              event_handler: nil,
              notify_pid: nil,
              extra: %{}
  end

  @impl true
  def init_agent(opts) do
    scripts = Keyword.get(opts, :scripts, [])

    backend_opts =
      [scripts: scripts]
      |> maybe_put(:session_id, Keyword.get(opts, :session_id))

    responder =
      Keyword.get(opts, :responder, fn _ref, _response, state ->
        {:noreply, state}
      end)

    error_handler =
      Keyword.get(opts, :error_handler, fn _ref, _reason, state ->
        {:noreply, state}
      end)

    event_handler =
      Keyword.get(opts, :event_handler, fn _event, state ->
        {:noreply, state}
      end)

    notify_pid = Keyword.get(opts, :notify_pid)
    extra = Keyword.get(opts, :extra, %{})

    state = %State{
      responder: responder,
      error_handler: error_handler,
      event_handler: event_handler,
      notify_pid: notify_pid,
      extra: extra
    }

    {:ok, backend_opts, state}
  end

  @impl true
  def handle_response(ref, response, %State{} = state) do
    state = %{state | responses: state.responses ++ [{ref, response}]}
    maybe_notify(state, :handle_response, {ref, response})
    state.responder.(ref, response, state)
  end

  @impl true
  def handle_error(ref, reason, %State{} = state) do
    state = %{state | errors: state.errors ++ [{ref, reason}]}
    maybe_notify(state, :handle_error, {ref, reason})
    state.error_handler.(ref, reason, state)
  end

  @impl true
  def handle_event(event, %State{} = state) do
    state = %{state | events: state.events ++ [event]}
    maybe_notify(state, :handle_event, event)
    state.event_handler.(event, state)
  end

  @impl true
  def handle_stream_event(event, %State{} = state) do
    state = %{state | stream_events: state.stream_events ++ [event]}
    maybe_notify(state, :handle_stream_event, event)
    state
  end

  @impl true
  def terminate_agent(reason, %State{} = state) do
    maybe_notify(state, :terminate_agent, reason)
    :ok
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)

  defp maybe_notify(%State{notify_pid: nil}, _, _), do: :ok

  defp maybe_notify(%State{notify_pid: pid}, callback, payload) do
    send(pid, {:test_agent, callback, payload})
    :ok
  end
end
