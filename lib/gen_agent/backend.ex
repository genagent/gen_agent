defmodule GenAgent.Backend do
  @moduledoc """
  Behaviour for GenAgent LLM backends.

  A backend is responsible for:

    * Starting and terminating a persistent session with an LLM.
    * Translating a prompt into a stream of `GenAgent.Event` values.
    * Optionally tracking state that changes between turns (e.g. a
      session id assigned by the backend after the first response).

  The state machine owns backend lifecycle. It calls `start_session/1`
  once when the agent boots, `prompt/2` on each turn, and
  `terminate_session/1` on shutdown.

  ## Session values

  A `session` is an opaque term owned by the backend. It is passed back
  to the backend on each call so that the backend can carry private
  state across turns without needing its own process. Backends that need
  a process of their own can store its pid inside the session term.

  Because `prompt/2` can mutate session state (for example, capturing
  a `session_id` the first time the backend sees one), it returns an
  updated session alongside the event stream. The state machine
  replaces its cached session with whatever `prompt/2` returns.

  ## Event stream contract

  The enumerable returned from `prompt/2` must:

    * Yield `GenAgent.Event` values in arrival order.
    * Emit exactly one terminal event (`:result` or `:error`) as the
      final element. The state machine stops consuming the stream after
      a terminal event.
    * Be safe to consume from inside a `Task` (the state machine runs
      prompt execution under a `Task.Supervisor`).

  Streams may be lazy. A lazy stream that blocks until fresh events
  arrive is the expected shape for backends that wrap long-running CLIs.
  """

  alias GenAgent.Event

  @typedoc "Opaque session term owned by the backend."
  @type session :: term()

  @doc """
  Start a new session with the backend.

  Called once when the agent boots. `opts` are the backend options
  returned from the implementation's `c:GenAgent.init_agent/1`.
  """
  @callback start_session(opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Dispatch a prompt on a session.

  Returns an event stream and an updated session. The state machine
  replaces its cached session with the returned value before the next
  call.

  A synchronous `{:error, reason}` return indicates the prompt could
  not be dispatched at all (e.g. the backend process is down). Errors
  that occur mid-turn should be delivered via an `:error` terminal
  event on the stream instead.
  """
  @callback prompt(session(), prompt :: String.t()) ::
              {:ok, Enumerable.t(Event.t()), session()}
              | {:error, term()}

  @doc """
  Fold a terminal event's data into the session.

  Called once per turn, when the terminal `:result` event arrives,
  with the terminal event's `:data` map. Backends use this hook to
  capture identifiers assigned after the first response (for example,
  Claude's `session_id`).

  Optional. If not implemented, the session is unchanged.
  """
  @callback update_session(session(), event_data :: map()) :: session()

  @doc """
  Resume a previously-persisted session by id.

  Optional. Used by future persistence features to reattach to a
  session across restarts. v0.1 does not call this.
  """
  @callback resume_session(session_id :: String.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Tear down a session.

  Called when the agent is shutting down cleanly. Backends should
  release any resources held by the session here.
  """
  @callback terminate_session(session()) :: :ok

  @optional_callbacks [resume_session: 2, update_session: 2]
end
