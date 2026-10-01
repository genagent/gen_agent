defmodule GenAgent.Backends.Claude do
  @moduledoc """
  `GenAgent.Backend` implementation backed by `ClaudeWrapper`.

  Each session wraps a set of `ClaudeWrapper` options (config +
  query-level) and threads the Claude CLI's `session_id` across turns
  so that a persistent conversation is maintained without any
  `ClaudeWrapper.Session` or `ClaudeWrapper.SessionServer` involvement.

  ## Options

  `start_session/1` accepts any option supported by `ClaudeWrapper.stream/2`:

    * Config: `:binary`, `:working_dir` (aliased as `:cwd`), `:env`,
      `:timeout`, `:verbose`, `:debug`
    * Query: `:model`, `:system_prompt`, `:append_system_prompt`,
      `:max_turns`, `:max_budget_usd`, `:permission_mode`,
      `:dangerously_skip_permissions`, `:effort`, `:json_schema`,
      `:agent`, `:brief`, `:include_partial_messages` (on by default)

  Plus a backend-only option:

    * `:stream_fn` -- a 2-arity function `(prompt, opts) -> Enumerable.t()`
      that replaces the default `&ClaudeWrapper.stream/2`. Intended for
      tests; production code should leave this alone.

  ## Session continuation

  On the first turn, no `:resume` flag is passed. When the terminal
  `:result` event arrives, `update_session/2` captures `session_id`
  from the event data and stores it on the session struct. Subsequent
  turns pass that id through Claude's `--resume` flag.

  `terminate_session/1` has no native process to close. GenAgent cancels
  its prompt task on interrupt, watchdog, stop, or agent death, but the
  default Port runner closes pipes without guaranteeing that the CLI and
  its subprocesses have exited. Choose a runner with process-group
  termination when OS-level settlement is required.
  """

  @behaviour GenAgent.Backend

  alias GenAgent.Backends.Claude.EventTranslator

  defstruct [
    :opts,
    :stream_fn,
    session_id: nil
  ]

  @type t :: %__MODULE__{
          opts: keyword(),
          stream_fn: (String.t(), keyword() -> Enumerable.t()),
          session_id: String.t() | nil
        }

  @impl GenAgent.Backend
  def start_session(opts) do
    {stream_fn, opts} = Keyword.pop(opts, :stream_fn, &ClaudeWrapper.stream/2)
    opts = normalize_opts(opts)

    {:ok,
     %__MODULE__{
       opts: opts,
       stream_fn: stream_fn
     }}
  end

  @impl GenAgent.Backend
  def prompt(%__MODULE__{} = session, prompt) when is_binary(prompt) do
    call_opts = merge_resume(session.opts, session.session_id)

    stream =
      session.stream_fn.(prompt, call_opts)
      |> EventTranslator.translate_stream()

    {:ok, stream, session}
  rescue
    e -> {:error, {:stream_fn_raised, Exception.message(e)}}
  end

  @impl GenAgent.Backend
  def update_session(%__MODULE__{} = session, %{session_id: sid}) when is_binary(sid) do
    %{session | session_id: sid}
  end

  def update_session(%__MODULE__{} = session, _data), do: session

  @impl GenAgent.Backend
  def resume_session(session_id, opts) when is_binary(session_id) do
    {:ok, session} = start_session(opts)
    {:ok, %{session | session_id: session_id}}
  end

  @impl GenAgent.Backend
  def terminate_session(%__MODULE__{}), do: :ok

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_opts(opts) do
    opts = Keyword.put_new(opts, :include_partial_messages, true)

    case Keyword.pop(opts, :cwd) do
      {nil, rest} -> rest
      {cwd, rest} -> Keyword.put_new(rest, :working_dir, cwd)
    end
  end

  defp merge_resume(opts, nil), do: opts
  defp merge_resume(opts, session_id), do: Keyword.put(opts, :resume, session_id)
end
