defmodule GenAgent.Backends.Mock do
  @moduledoc """
  In-memory `GenAgent.Backend` for testing.

  A mock session holds a list of **scripts**, one per upcoming turn.
  Each call to `prompt/2` consumes the head of the list and turns it
  into an event stream.

  ## Script shapes

    * `[%GenAgent.Event{}, ...]` -- a static list of events. The last
      event should be a terminal event (`:result` or `:error`).
    * `fun` where `fun` is `(String.t() -> Enumerable.t())` -- the
      prompt is passed in and the function returns the event stream.
      Useful for asserting on the prompt text or emitting dynamic
      events.
    * `{:error, reason}` -- `prompt/2` returns `{:error, reason}`
      synchronously, without producing a stream.
    * `{:raise, reason}` -- the returned stream raises when consumed,
      simulating an in-flight backend crash.

  Scripts are consumed in order. A prompt with no matching script
  returns `{:error, :no_script}`.

  ## Helpers

  Tests can use `history/1` to inspect the prompts that have been
  dispatched on a session, and `remaining/1` to count unconsumed
  scripts.
  """

  @behaviour GenAgent.Backend

  defstruct [:agent, :session_id]

  @type script ::
          [GenAgent.Event.t()]
          | (String.t() -> Enumerable.t())
          | {:error, term()}
          | {:raise, term()}

  @type t :: %__MODULE__{
          agent: pid(),
          session_id: String.t() | nil
        }

  @impl true
  def start_session(opts) do
    scripts = Keyword.get(opts, :scripts, [])
    session_id = Keyword.get(opts, :session_id)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{scripts: scripts, history: []}
      end)

    {:ok, %__MODULE__{agent: agent, session_id: session_id}}
  end

  @impl true
  def prompt(%__MODULE__{agent: agent} = session, prompt) when is_binary(prompt) do
    next =
      Agent.get_and_update(agent, fn state ->
        case state.scripts do
          [] ->
            {:no_script, state}

          [script | rest] ->
            new_state = %{state | scripts: rest, history: [prompt | state.history]}
            {{:ok, script}, new_state}
        end
      end)

    case next do
      :no_script ->
        {:error, :no_script}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, {:raise, reason}} ->
        stream =
          Stream.resource(
            fn -> nil end,
            fn _ -> raise "mock backend raised: #{inspect(reason)}" end,
            fn _ -> :ok end
          )

        {:ok, stream, session}

      {:ok, script} when is_function(script, 1) ->
        {:ok, script.(prompt), session}

      {:ok, script} when is_list(script) ->
        {:ok, script, session}
    end
  end

  @impl true
  def update_session(%__MODULE__{} = session, event_data) do
    case Map.get(event_data, :session_id) do
      nil -> session
      sid when is_binary(sid) -> %{session | session_id: sid}
    end
  end

  @impl true
  def terminate_session(%__MODULE__{agent: agent}) do
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  end

  @doc """
  Return the list of prompts dispatched on this session, in order.
  """
  @spec history(t()) :: [String.t()]
  def history(%__MODULE__{agent: agent}) do
    agent
    |> Agent.get(& &1.history)
    |> Enum.reverse()
  end

  @doc """
  Return the number of unconsumed scripts remaining.
  """
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{agent: agent}) do
    Agent.get(agent, fn %{scripts: s} -> length(s) end)
  end
end
