defmodule GenAgent.Backends.Mock do
  @moduledoc """
  In-memory `GenAgent.Backend` for testing application agents without a
  provider account or CLI. Start an agent with `backend: GenAgent.Backends.Mock`
  and pass `scripts:` through its `init_agent/1` backend options.

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
    * `gate(tag, events)` -- announce `{:mock_blocked, tag, task_pid}` to
      the process that constructs the script, then wait for
      `{:mock_release, tag}` sent to `task_pid` before yielding `events`.
      The wait has a five-second safety timeout by default.

  Scripts are consumed in order. A prompt with no matching script
  returns `{:error, :no_script}`.

  ## Helpers

  Tests can use `history/1` with a running agent's registered name or a
  session struct to inspect dispatched prompts; `remaining/1` counts
  unconsumed scripts. `start_error: reason` simulates a backend startup
  failure without creating a session process.
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
    if Keyword.has_key?(opts, :start_error) do
      {:error, Keyword.fetch!(opts, :start_error)}
    else
      scripts = Keyword.get(opts, :scripts, [])
      session_id = Keyword.get(opts, :session_id)

      {:ok, agent} =
        Agent.start_link(fn ->
          %{scripts: scripts, history: []}
        end)

      {:ok, %__MODULE__{agent: agent, session_id: session_id}}
    end
  end

  @impl true
  def prompt(%__MODULE__{agent: agent} = session, prompt) when is_binary(prompt) do
    next =
      Agent.get_and_update(agent, fn state ->
        case state.scripts do
          [] ->
            {:no_script, %{state | history: [prompt | state.history]}}

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
  Return attempted prompts in order, including attempts after scripts run out.

  Accepts a session struct or a registered GenAgent name. Name lookup
  returns `{:error, :not_found}` if the agent is gone and
  `{:error, :not_mock_backend}` if it uses another backend.
  """
  @spec history(t() | GenAgent.name()) :: [String.t()] | {:error, atom()}
  def history(%__MODULE__{agent: agent}) do
    agent
    |> Agent.get(& &1.history)
    |> Enum.reverse()
  end

  def history(name) do
    with {:ok, session} <- session_for(name), do: history(session)
  end

  @doc """
  Return the number of unconsumed scripts remaining.
  """
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{agent: agent}) do
    Agent.get(agent, fn %{scripts: s} -> length(s) end)
  end

  @doc """
  Return a script that pauses an in-flight turn until the test releases it.

  Construct the script in the test process and include it in `scripts:`.
  After receiving `{:mock_blocked, tag, task_pid}`, send
  `{:mock_release, tag}` to `task_pid`. The returned stream then yields
  `events`. The safety timeout raises in the prompt task if no release
  arrives; pass a different positive timeout when a test needs one.
  """
  @spec gate(term(), [GenAgent.Event.t()], pos_integer()) ::
          (String.t() -> Enumerable.t())
  def gate(tag, events, timeout \\ 5_000)
      when is_list(events) and is_integer(timeout) and timeout > 0 do
    observer = self()

    fn _prompt ->
      Stream.resource(
        fn -> :waiting end,
        fn
          :waiting ->
            send(observer, {:mock_blocked, tag, self()})

            receive do
              {:mock_release, ^tag} -> {events, :done}
            after
              timeout -> raise "mock gate #{inspect(tag)} timed out"
            end

          :done ->
            {:halt, :done}
        end,
        fn _ -> :ok end
      )
    end
  end

  defp session_for(name) do
    case GenAgent.whereis(name) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          case :gen_statem.call(pid, :get_backend_session) do
            %__MODULE__{} = session -> {:ok, session}
            _ -> {:error, :not_mock_backend}
          end
        catch
          :exit, _ -> {:error, :not_found}
        end
    end
  end
end
