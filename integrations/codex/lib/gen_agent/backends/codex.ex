defmodule GenAgent.Backends.Codex do
  @moduledoc """
  `GenAgent.Backend` implementation backed by `CodexWrapper`.

  CodexWrapper 0.5.6 streams NDJSON while closing CLI stdin. This
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

  ## Usage

  Codex reports `turn.completed.usage` as the thread's running total,
  including on resumed turns. The session keeps the previous completed
  total, and `:usage` events carry the increase since then for the five
  counters Codex reports (`input_tokens`, `output_tokens`,
  `cached_input_tokens`, `cache_write_input_tokens`,
  `reasoning_output_tokens`). Sessions from `start_session/1` start from
  zero. Sessions from `resume_session/2` have no known total, so the
  first completed turn reports no usage and only records the total.
  A counter that is missing or decreased (thread reset) produces no delta
  for that turn, and the new total becomes the baseline. A failed or
  interrupted turn does not update the baseline, so its consumption is
  included in the next successful delta.

  `terminate_session/1` has no native process to close. GenAgent cancels
  its prompt task on interrupt, watchdog, stop, or agent death, but the
  default Port runner closes pipes without guaranteeing that the CLI and
  its subprocesses have exited. Choose a runner with process-group
  termination when OS-level settlement is required.

  ## Options accepted by `start_session/1`

  Config-level (forwarded to `CodexWrapper.Config.new/1`):

    * `:binary`, `:working_dir` (deprecated alias `:cwd`), `:env`, `:timeout`,
      `:idle_timeout_ms`. `:timeout` bounds the whole CLI turn;
      `:idle_timeout_ms` bounds gaps between output frames and defaults to
      300,000 ms. Without `:timeout`, the Forcola runner uses a one-hour
      whole-run default; GenAgent's watchdog may end the turn earlier.

  Exec-level (forwarded to `CodexWrapper.Exec`):

    * `:model`, `:sandbox`, `:approval_policy`, `:full_auto`,
      `:dangerously_bypass_approvals_and_sandbox`, `:skip_git_repo_check`,
      `:ignore_user_config`, `:profile`,
      `:config_overrides`, `:enabled_features`, `:disabled_features`,
      `:images`, `:output_schema`

  Options that cannot be preserved on `exec resume` (`:cd`,
  `:add_dirs`, `:search`, `:ephemeral`) are rejected by
  `start_session/1` when enabled. Use `:working_dir` / `:cwd` for a directory that
  persists across turns. The CLI has no global `--verbose` flag, so
  `verbose: true` is also rejected. Explicit `false` values remain accepted as
  no-ops. Session options are translated into supported
  resume arguments; `:sandbox` and `:approval_policy` use config
  overrides because resume does not accept their exec flags.
  `:ignore_user_config` applies to both fresh and resumed turns. The CLI
  accepts `:profile` only on the initial `exec`, so it applies to the
  first turn only. Invalid `:sandbox` and `:working_dir` values return
  `{:error, {:invalid_option, key, value}}` at session startup.

  Backend-only (never forwarded to the CLI):

    * `:exec_fn` -- a 2-arity function `(prompt, session) -> {:ok,
      Enumerable.t()} | {:error, term()}` that replaces the default
      `Exec`/`ExecResume` dispatch. Intended for tests.
    * `:response_text` -- `:all_messages` (default) or `:final_message`.
      Selects what `GenAgent.Response.text` holds for a successful turn.
      See [Response text](#module-response-text).

  ## Response text

  Codex emits one `agent_message` item per assistant message, so a turn
  that narrates before answering produces several `:text` events. By
  default (`response_text: :all_messages`) the terminal `:result` carries
  no text and `GenAgent.Response.text` joins every message with a blank
  line, exactly as before.

  With `response_text: :final_message`, a successful `turn.completed`
  puts the text of the last completed `agent_message` of that turn into
  the terminal `:result` as `:text`, so `Response.text` holds only the
  final message. This is useful when the final message is structured
  output (for example JSON requested via `:output_schema`) and earlier
  commentary would break parsing. Exact semantics:

    * Only `Response.text` changes. Every `agent_message` still becomes a
      `:text` event delivered to `handle_stream_event/2` and retained in
      `Response.events`. (Core versions that expose
      `Response.final_message` derive it from the same terminal text.)
    * The last message wins even when its text is empty: an empty final
      `agent_message` yields `""`.
    * A successful turn with no `agent_message` yields `""`.
    * Text is tracked per turn. A resumed turn never reports a message
      from an earlier turn.
    * Failed turns are unchanged and still return `{:error, reason}`.
      Usage deltas and thread checkpointing are unaffected.
    * The option is validated at `start_session/1` and `resume_session/2`.
      `nil` means the default. Any other value returns
      `{:error, {:invalid_option, :response_text, value}}` before the CLI
      is called. A resumed session keeps the mode.

  Codex has no equivalent of Claude's `--system-prompt`; if you need
  system-level instructions, pass them via `AGENTS.md` in the working
  directory or through Codex's configuration layer.
  Unknown keys return `{:error, {:unknown_option, key}}`; known unsupported
  system prompt and output cap options return `{:error, {:unsupported_option, key}}`.
  """

  @behaviour GenAgent.Backend

  require Logger

  alias CodexWrapper.{Config, Exec, ExecResume}
  alias GenAgent.Backends.Codex.EventTranslator

  @config_keys [:binary, :working_dir, :env, :timeout, :idle_timeout_ms]
  @unsupported_resume_keys [:cd, :add_dirs, :search, :ephemeral]
  @exec_keys [
    :model,
    :sandbox,
    :approval_policy,
    :full_auto,
    :dangerously_bypass_approvals_and_sandbox,
    :skip_git_repo_check,
    :ignore_user_config,
    :profile,
    :config_overrides,
    :enabled_features,
    :disabled_features,
    :images,
    :output_schema
  ]

  @response_text_modes [:all_messages, :final_message]

  defstruct [
    :config,
    :exec_opts,
    :exec_fn,
    thread_id: nil,
    usage_total: %{},
    response_text: :all_messages
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          exec_opts: keyword(),
          exec_fn: (String.t(), t() -> {:ok, Enumerable.t()} | {:error, term()}),
          thread_id: String.t() | nil,
          usage_total: EventTranslator.usage_total(),
          response_text: EventTranslator.response_text()
        }

  @impl GenAgent.Backend
  def start_session(opts) do
    {exec_fn, opts} = Keyword.pop(opts, :exec_fn, &default_exec/2)
    {response_text, opts} = Keyword.pop(opts, :response_text)
    opts = opts |> normalize_cwd() |> drop_disabled_options()
    {config_opts, exec_opts} = Keyword.split(opts, @config_keys)

    with :ok <- validate_exec_opts(exec_opts),
         :ok <- validate_sandbox(exec_opts[:sandbox]),
         :ok <- validate_working_dir(config_opts[:working_dir]),
         :ok <- validate_response_text(response_text) do
      config = Config.new(config_opts)

      {:ok,
       %__MODULE__{
         config: config,
         exec_opts: exec_opts,
         exec_fn: exec_fn,
         usage_total: EventTranslator.zero_usage_total(),
         response_text: response_text || :all_messages
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
          |> EventTranslator.translate_stream(
            usage_baseline: session.usage_total,
            response_text: session.response_text
          )

        {:ok, stream, session}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exec_fn_raised, Exception.message(e)}}
  end

  @impl GenAgent.Backend
  def update_session(%__MODULE__{} = session, data) when is_map(data) do
    session =
      case data do
        %{session_id: sid} when is_binary(sid) -> %{session | thread_id: sid}
        _ -> session
      end

    case data do
      %{usage_total: %{} = total} -> %{session | usage_total: total}
      _ -> session
    end
  end

  def update_session(%__MODULE__{} = session, _data), do: session

  if {:checkpoint_session, 2} in GenAgent.Backend.behaviour_info(:callbacks),
    do: @impl(GenAgent.Backend)

  def checkpoint_session(%__MODULE__{} = session, sid), do: %{session | thread_id: sid}

  @impl GenAgent.Backend
  def resume_session(session_id, opts) when is_binary(session_id) do
    case start_session(opts) do
      {:ok, session} -> {:ok, %{session | thread_id: session_id, usage_total: %{}}}
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
      {nil, rest} ->
        rest

      {cwd, rest} ->
        Logger.warning(":cwd is deprecated; use :working_dir")
        Keyword.put_new(rest, :working_dir, cwd)
    end
  end

  defp drop_disabled_options(opts) do
    Enum.reject(opts, fn {key, value} ->
      key in [:ephemeral, :verbose] and value in [false, nil]
    end)
  end

  defp validate_exec_opts(opts) do
    case Enum.find(opts, fn {key, _value} -> key not in @exec_keys end) do
      {key, _value} when key in @unsupported_resume_keys ->
        {:error, {:unsupported_resume_option, key}}

      {key, _value}
      when key in [
             :system_prompt,
             :system,
             :instructions,
             :max_tokens,
             :max_output_tokens,
             :verbose
           ] ->
        {:error, {:unsupported_option, key}}

      {key, _value} ->
        {:error, {:unknown_option, key}}

      nil ->
        if opts[:approval_policy] in [nil, :untrusted, :on_request, :never] do
          :ok
        else
          {:error, {:invalid_approval_policy, opts[:approval_policy]}}
        end
    end
  end

  defp validate_sandbox(value)
       when value in [nil, :read_only, :workspace_write, :danger_full_access],
       do: :ok

  defp validate_sandbox(value), do: {:error, {:invalid_option, :sandbox, value}}

  defp validate_working_dir(value) when is_binary(value) or is_nil(value), do: :ok
  defp validate_working_dir(value), do: {:error, {:invalid_option, :working_dir, value}}

  defp validate_response_text(value) when is_nil(value) or value in @response_text_modes,
    do: :ok

  defp validate_response_text(value), do: {:error, {:invalid_option, :response_text, value}}
end
