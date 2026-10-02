defmodule GenAgent.Backends.Claude do
  @moduledoc """
  `GenAgent.Backend` implementation backed by `ClaudeWrapper`.

  Each session wraps a set of `ClaudeWrapper` options (config +
  query-level) and threads the Claude CLI's `session_id` across turns
  so that a persistent conversation is maintained without any
  `ClaudeWrapper.Session` or `ClaudeWrapper.SessionServer` involvement.

  ## Options

  `start_session/1` accepts `ClaudeWrapper.stream/2` options except
  `:no_session_persistence`, which cannot be enabled because this backend
  resumes the CLI session on later turns. Unknown keys return
  `{:error, {:unknown_option, key}}` and malformed values return
  `{:error, {:invalid_option, key, value}}`:

    * Config: `:binary` (a path or `:bundled`), `:working_dir` (aliased as
      `:cwd`), `:env` (a map or `{name, value}` list; `false` unsets),
      `:timeout`, `:verbose`, `:debug`
    * Query: every key `ClaudeWrapper.Query.apply_opts/2` handles, such as
      `:model`, `:system_prompt`, `:append_system_prompt`, `:settings`,
      `:max_turns`, `:max_budget_usd`, `:permission_mode`, `:effort`,
      `:json_schema`, `:allowed_tools`, `:files`, `:output_format`,
      `:include_partial_messages` (on by default)

  Plus a backend-only option:

    * `:stream_fn` -- a 2-arity function `(prompt, opts) -> Enumerable.t()`
      that replaces the default `&ClaudeWrapper.stream/2`. Intended for
      tests; production code should leave this alone.

  ## Session continuation

  On the first turn, no `:resume` flag is passed. When the terminal
  `:result` event arrives, `update_session/2` captures `session_id`
  from the event data and stores it on the session struct. Under GenAgent,
  `prompt/3` also checkpoints a raw `system` or terminal ID as soon as it
  arrives, so failed and interrupted turns can resume. Subsequent
  turns pass that id through Claude's `--resume` flag, without forwarding
  the first turn's `:session_id` or `:continue_session` options.

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
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_options, opts}}

      Keyword.get(opts, :no_session_persistence) ->
        {:error, {:unsupported_option, :no_session_persistence}}

      true ->
        {stream_fn, opts} = Keyword.pop(opts, :stream_fn, &ClaudeWrapper.stream/2)

        with :ok <- validate_opts(opts) do
          {:ok,
           %__MODULE__{
             opts: normalize_opts(opts),
             stream_fn: stream_fn
           }}
        end
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
    call_opts = merge_resume(session.opts, session.session_id)

    stream =
      session.stream_fn.(prompt, call_opts)
      |> Stream.each(&checkpoint_raw(&1, checkpoint))
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

  if {:checkpoint_session, 2} in GenAgent.Backend.behaviour_info(:callbacks),
    do: @impl(GenAgent.Backend)

  def checkpoint_session(%__MODULE__{} = session, sid), do: %{session | session_id: sid}

  @impl GenAgent.Backend
  def resume_session(session_id, opts) when is_binary(session_id) do
    with {:ok, session} <- start_session(opts) do
      {:ok, %{session | session_id: session_id}}
    end
  end

  @impl GenAgent.Backend
  def terminate_session(%__MODULE__{}), do: :ok

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @permission_modes [:default, :accept_edits, :bypass_permissions, :plan, :dont_ask, :auto]
  @efforts [:low, :medium, :high, :xhigh, :max]

  @binary_opts [
    :working_dir,
    :cwd,
    :model,
    :fallback_model,
    :system_prompt,
    :system_prompt_file,
    :append_system_prompt,
    :append_system_prompt_file,
    :permission_prompt_tool,
    :json_schema,
    :agent,
    :agents_json,
    :setting_sources,
    :settings,
    :resume,
    :session_id,
    :from_pr,
    :debug_filter,
    :debug_file,
    :name
  ]
  @boolean_opts [
    :debug,
    :verbose,
    :brief,
    :strict_mcp_config,
    :dangerously_skip_permissions,
    :include_partial_messages,
    :continue_session,
    :no_session_persistence,
    :fork_session,
    :tmux,
    :prompt_suggestions,
    :replay_user_messages,
    :bare,
    :disable_slash_commands,
    :include_hook_events,
    :safe_mode,
    :exclude_dynamic_system_prompt_sections
  ]
  @list_opts [:tools, :allowed_tools, :disallowed_tools, :files, :plugin_dirs, :plugin_urls]
  @binary_or_list_opts [:add_dir, :mcp_config, :betas]
  @known_opts @binary_opts ++
                @boolean_opts ++
                @list_opts ++
                @binary_or_list_opts ++
                [
                  :binary,
                  :env,
                  :timeout,
                  :output_format,
                  :input_format,
                  :max_turns,
                  :max_budget_usd,
                  :max_thinking_tokens,
                  :permission_mode,
                  :effort,
                  :hermetic,
                  :worktree
                ]

  defp validate_opts(opts) do
    Enum.find_value(opts, :ok, fn {key, value} ->
      case validate_opt(key, value) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp validate_opt(key, _value) when key not in @known_opts,
    do: {:error, {:unknown_option, key}}

  defp validate_opt(_key, nil), do: :ok

  defp validate_opt(:binary, v), do: check(:binary, v, v == :bundled or is_binary(v))
  defp validate_opt(:worktree, v), do: check(:worktree, v, is_boolean(v) or is_binary(v))

  defp validate_opt(:max_thinking_tokens, v),
    do: check(:max_thinking_tokens, v, is_integer(v) and v > 0)

  defp validate_opt(:input_format, v), do: check(:input_format, v, v in [:text, :stream_json])
  defp validate_opt(:permission_mode, v), do: check(:permission_mode, v, v in @permission_modes)
  defp validate_opt(:effort, v), do: check(:effort, v, v in @efforts)
  defp validate_opt(:hermetic, v), do: check(:hermetic, v, v in [true, false, :full, :project])
  defp validate_opt(:max_turns, v), do: check(:max_turns, v, is_integer(v) and v > 0)
  defp validate_opt(:max_budget_usd, v), do: check(:max_budget_usd, v, is_number(v) and v > 0)
  defp validate_opt(:timeout, v), do: check(:timeout, v, is_integer(v) and v > 0)
  defp validate_opt(:env, v), do: check(:env, v, valid_env?(v))

  defp validate_opt(:output_format, v),
    do: check(:output_format, v, v in [:text, :json, :stream_json])

  defp validate_opt(key, v) when key in @binary_opts, do: check(key, v, is_binary(v))
  defp validate_opt(key, v) when key in @boolean_opts, do: check(key, v, is_boolean(v))

  defp validate_opt(key, v) when key in [:allowed_tools, :disallowed_tools],
    do: check(key, v, tool_pattern_list?(v))

  defp validate_opt(key, v) when key in @list_opts, do: check(key, v, binary_list?(v))

  defp validate_opt(key, v) when key in @binary_or_list_opts,
    do: check(key, v, is_binary(v) or binary_list?(v))

  # Environment entries as the wrapper runner consumes them: a map or a list of
  # `{name, value}` tuples, names as strings or atoms, values as strings, or
  # `false` to unset the variable.
  defp valid_env?(env) when is_map(env) and not is_struct(env) do
    valid_env_entries?(env)
  end

  defp valid_env?(env) when is_list(env) do
    valid_env_entries?(env)
  end

  defp valid_env?(_env), do: false

  defp valid_env_entries?(env) do
    Enum.all?(env, fn
      {key, value} -> (is_binary(key) or is_atom(key)) and (is_binary(value) or value == false)
      _ -> false
    end)
  end

  defp binary_list?(v), do: is_list(v) and Enum.all?(v, &is_binary/1)

  defp tool_pattern_list?(v) do
    is_list(v) and
      Enum.all?(v, fn
        value when is_binary(value) -> true
        %ClaudeWrapper.ToolPattern{value: value} when is_binary(value) -> true
        _ -> false
      end)
  end

  defp check(_key, _value, true), do: :ok
  defp check(key, value, false), do: {:error, {:invalid_option, key, value}}

  defp normalize_opts(opts) do
    opts = Keyword.put_new(opts, :include_partial_messages, true)

    case Keyword.pop(opts, :cwd) do
      {nil, rest} -> rest
      {cwd, rest} -> Keyword.put_new(rest, :working_dir, cwd)
    end
  end

  defp merge_resume(opts, nil), do: opts

  defp merge_resume(opts, session_id) do
    opts
    |> Keyword.drop([:session_id, :continue_session])
    |> Keyword.put(:resume, session_id)
  end

  defp checkpoint_raw(_event, nil), do: :ok

  defp checkpoint_raw(%{type: type, data: %{"session_id" => id}}, checkpoint)
       when type in ["system", "result", "error"] do
    checkpoint_present_id(id, checkpoint)
  end

  defp checkpoint_raw(_event, _checkpoint), do: :ok

  defp checkpoint_present_id(nil, _checkpoint), do: :ok

  defp checkpoint_present_id(id, checkpoint) do
    case checkpoint.(id) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "Claude session checkpoint rejected: #{reason}"
    end
  end
end
