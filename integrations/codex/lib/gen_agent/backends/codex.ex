defmodule GenAgent.Backends.Codex do
  @moduledoc """
  `GenAgent.Backend` implementation backed by `CodexWrapper`.

  CodexWrapper 0.5.3 streams NDJSON while closing CLI stdin. This
  backend forwards translated events as they arrive, so
  `handle_stream_event/2` can observe progress during a turn.

  ## Session continuation

  Codex reports its persistent thread identifier as `thread_id` in the
  first `thread.started` event of a turn, not in the terminal
  `turn.completed` event. The `EventTranslator` captures it and
  injects it into the `:result` event as `session_id`. Under GenAgent,
  `prompt/3` checkpoints the raw ID at `thread.started`, before a terminal
  event or interruption. This backend's `update_session/2` records a
  successful result on the session struct, and the
  next turn is dispatched via `ExecResume` with that id.

  `terminate_session/1` has no native process to close. GenAgent cancels
  its prompt task on interrupt, watchdog, stop, or agent death, but the
  default Port runner closes pipes without guaranteeing that the CLI and
  its subprocesses have exited. Choose a runner with process-group
  termination when OS-level settlement is required.

  ## Options accepted by `start_session/1`

  Config-level (forwarded to `CodexWrapper.Config.new/1`):

    * `:binary`, `:working_dir` (aliased as `:cwd`), `:env`, `:timeout`,
      `:verbose`

  Exec-level (forwarded to `CodexWrapper.Exec`):

    * `:model`, `:sandbox`, `:approval_policy`, `:full_auto`,
      `:dangerously_bypass_approvals_and_sandbox`, `:skip_git_repo_check`,
      `:ephemeral`, `:ignore_user_config`, `:profile`,
      `:config_overrides`, `:enabled_features`, `:disabled_features`,
      `:images`, `:output_schema`

  Options that cannot be preserved on `exec resume` (`:cd`,
  `:add_dirs`, `:search`) are rejected by
  `start_session/1`. Use `:working_dir` / `:cwd` for a directory that
  persists across turns. Session options are translated into supported
  resume arguments; `:sandbox` and `:approval_policy` use config
  overrides because resume does not accept their exec flags.
  `:ignore_user_config` applies to both fresh and resumed turns. The CLI
  accepts `:profile` only on the initial `exec`, so it applies to the
  first turn only.

  Backend-only:

    * `:exec_fn` -- a 2-arity function `(prompt, session) -> {:ok,
      Enumerable.t()} | {:error, term()}` that replaces the default
      `Exec`/`ExecResume` dispatch. Intended for tests.

  Codex has no equivalent of Claude's `--system-prompt`; if you need
  system-level instructions, pass them via `AGENTS.md` in the working
  directory or through Codex's configuration layer.
  """

  @behaviour GenAgent.Backend

  alias CodexWrapper.{Config, Exec, ExecResume}
  alias GenAgent.Backends.Codex.EventTranslator

  @config_keys [:binary, :working_dir, :env, :timeout, :verbose]
  @unsupported_resume_keys [:cd, :add_dirs, :search]
  @exec_keys [
    :model,
    :sandbox,
    :approval_policy,
    :full_auto,
    :dangerously_bypass_approvals_and_sandbox,
    :skip_git_repo_check,
    :ephemeral,
    :ignore_user_config,
    :profile,
    :config_overrides,
    :enabled_features,
    :disabled_features,
    :images,
    :output_schema
  ]

  defstruct [
    :config,
    :exec_opts,
    :exec_fn,
    thread_id: nil
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          exec_opts: keyword(),
          exec_fn: (String.t(), t() -> {:ok, Enumerable.t()} | {:error, term()}),
          thread_id: String.t() | nil
        }

  @impl GenAgent.Backend
  def start_session(opts) do
    {exec_fn, opts} = Keyword.pop(opts, :exec_fn, &default_exec/2)
    opts = normalize_cwd(opts)
    {config_opts, exec_opts} = Keyword.split(opts, @config_keys)

    with :ok <- validate_exec_opts(exec_opts) do
      config = Config.new(config_opts)

      {:ok,
       %__MODULE__{
         config: config,
         exec_opts: exec_opts,
         exec_fn: exec_fn
       }}
    end
  end

  @impl GenAgent.Backend
  def prompt(%__MODULE__{} = session, prompt) when is_binary(prompt) do
    do_prompt(session, prompt, nil)
  end

  # Older supported core versions do not declare these optional callbacks.
  if {:prompt, 3} in GenAgent.Backend.behaviour_info(:callbacks), do: @impl(GenAgent.Backend)

  def prompt(%__MODULE__{} = session, prompt, %{checkpoint: checkpoint})
      when is_binary(prompt) and is_function(checkpoint, 1) do
    do_prompt(session, prompt, checkpoint)
  end

  defp do_prompt(session, prompt, checkpoint) do
    case session.exec_fn.(prompt, session) do
      {:ok, json_events} ->
        stream =
          json_events
          |> Stream.each(&checkpoint_raw(&1, checkpoint))
          |> EventTranslator.translate_stream()

        {:ok, stream, session}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exec_fn_raised, Exception.message(e)}}
  end

  @impl GenAgent.Backend
  def update_session(%__MODULE__{} = session, %{session_id: sid}) when is_binary(sid) do
    %{session | thread_id: sid}
  end

  def update_session(%__MODULE__{} = session, _data), do: session

  if {:checkpoint_session, 2} in GenAgent.Backend.behaviour_info(:callbacks),
    do: @impl(GenAgent.Backend)

  def checkpoint_session(%__MODULE__{} = session, sid), do: %{session | thread_id: sid}

  @impl GenAgent.Backend
  def resume_session(session_id, opts) when is_binary(session_id) do
    case start_session(opts) do
      {:ok, session} -> {:ok, %{session | thread_id: session_id}}
      {:error, _} = error -> error
    end
  end

  @impl GenAgent.Backend
  def terminate_session(%__MODULE__{}), do: :ok

  defp checkpoint_raw(_event, nil), do: :ok

  defp checkpoint_raw(%{event_type: "thread.started", data: %{"thread_id" => id}}, checkpoint),
    do: checkpoint_present_id(id, checkpoint)

  defp checkpoint_raw(%{event_type: type, data: %{"thread_id" => id}}, checkpoint)
       when type in ["turn.completed", "turn.failed", "error"],
       do: checkpoint_present_id(id, checkpoint)

  defp checkpoint_raw(_event, _checkpoint), do: :ok

  defp checkpoint_present_id(nil, _checkpoint), do: :ok

  defp checkpoint_present_id(id, checkpoint) do
    case checkpoint.(id) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "Codex session checkpoint rejected: #{reason}"
    end
  end

  # ---------------------------------------------------------------------------
  # Default exec_fn -- routes between Exec and ExecResume based on thread_id
  # ---------------------------------------------------------------------------

  defp default_exec(prompt, %__MODULE__{thread_id: nil} = session) do
    exec = build_exec(prompt, session.exec_opts)
    {:ok, Exec.stream(exec, session.config)}
  end

  defp default_exec(prompt, %__MODULE__{thread_id: tid} = session) when is_binary(tid) do
    resume = build_exec_resume(tid, prompt, session.exec_opts)
    {:ok, ExecResume.stream(resume, session.config)}
  end

  defp build_exec(prompt, exec_opts) do
    Enum.reduce(exec_opts, Exec.new(prompt), fn
      {:model, v}, e ->
        Exec.model(e, v)

      {:sandbox, v}, e ->
        Exec.sandbox(e, v)

      {:approval_policy, v}, e ->
        Exec.approval_policy(e, v)

      {:full_auto, true}, e ->
        Exec.full_auto(e)

      {:dangerously_bypass_approvals_and_sandbox, true}, e ->
        Exec.dangerously_bypass_approvals_and_sandbox(e)

      {:skip_git_repo_check, true}, e ->
        Exec.skip_git_repo_check(e)

      {:ephemeral, true}, e ->
        Exec.ephemeral(e)

      {:ignore_user_config, true}, e ->
        Exec.ignore_user_config(e)

      {:profile, v}, e ->
        Exec.profile(e, v)

      {:config_overrides, v}, e ->
        Enum.reduce(v, e, &Exec.config(&2, &1))

      {:enabled_features, v}, e ->
        Enum.reduce(v, e, &Exec.enable(&2, &1))

      {:disabled_features, v}, e ->
        Enum.reduce(v, e, &Exec.disable(&2, &1))

      {:images, v}, e ->
        Enum.reduce(v, e, &Exec.image(&2, &1))

      {:output_schema, v}, e ->
        Exec.output_schema(e, v)

      _other, e ->
        e
    end)
  end

  defp build_exec_resume(thread_id, prompt, exec_opts) do
    resume =
      ExecResume.new()
      |> ExecResume.session_id(thread_id)
      |> ExecResume.prompt(prompt)

    resume =
      Enum.reduce(exec_opts, resume, fn
        {:model, v}, r ->
          ExecResume.model(r, v)

        {:sandbox, v}, r ->
          ExecResume.sandbox(r, v)

        {:full_auto, true}, r ->
          ExecResume.full_auto(r)

        {:dangerously_bypass_approvals_and_sandbox, true}, r ->
          ExecResume.dangerously_bypass_approvals_and_sandbox(r)

        {:skip_git_repo_check, true}, r ->
          ExecResume.skip_git_repo_check(r)

        {:ephemeral, true}, r ->
          ExecResume.ephemeral(r)

        {:ignore_user_config, true}, r ->
          ExecResume.ignore_user_config(r)

        {:config_overrides, values}, r ->
          Enum.reduce(values, r, &ExecResume.config(&2, &1))

        {:enabled_features, values}, r ->
          Enum.reduce(values, r, &ExecResume.enable(&2, &1))

        {:disabled_features, values}, r ->
          Enum.reduce(values, r, &ExecResume.disable(&2, &1))

        {:images, values}, r ->
          Enum.reduce(values, r, &ExecResume.image(&2, &1))

        {:output_schema, value}, r ->
          ExecResume.output_schema(r, value)

        _other, r ->
          r
      end)

    case exec_opts[:approval_policy] do
      nil -> resume
      policy -> ExecResume.config(resume, ~s(approval_policy="#{format_approval_policy(policy)}"))
    end
  end

  defp format_approval_policy(:on_request), do: "on-request"
  defp format_approval_policy(policy), do: Atom.to_string(policy)

  defp normalize_cwd(opts) do
    case Keyword.pop(opts, :cwd) do
      {nil, rest} -> rest
      {cwd, rest} -> Keyword.put_new(rest, :working_dir, cwd)
    end
  end

  defp validate_exec_opts(opts) do
    case Enum.find(opts, fn {key, _value} -> key not in @exec_keys end) do
      {key, _value} when key in @unsupported_resume_keys ->
        {:error, {:unsupported_resume_option, key}}

      {key, _value} ->
        {:error, {:unsupported_option, key}}

      nil ->
        if opts[:approval_policy] in [nil, :untrusted, :on_request, :never] do
          :ok
        else
          {:error, {:invalid_approval_policy, opts[:approval_policy]}}
        end
    end
  end
end
