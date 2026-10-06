defmodule GenAgent.Server do
  @moduledoc false

  # The :gen_statem process that implements the GenAgent state machine.
  #
  # States:
  #
  #   :idle       -- no prompt in flight; on enter, attempts to drain the next
  #                 piece of pending work (self-chain or mailbox head).
  #   :processing -- a prompt is in flight as a Task under the agent's shared
  #                 TaskSupervisor; a state_timeout acts as the watchdog.
  #
  # This module owns the mechanics of turns. The caller's implementation
  # module owns the semantics via the GenAgent behaviour callbacks.

  @behaviour :gen_statem

  alias GenAgent.{Event, Response}
  require Logger

  @default_watchdog_ms :timer.minutes(10)
  @default_max_tell_results 100
  @default_max_tell_result_bytes 8_388_608
  @default_max_events_per_turn 1_000
  @default_max_event_bytes_per_turn 1_048_576
  @default_event_retention :compact
  @default_max_pending_prompts 1_000
  @default_max_pending_prompt_bytes 1_048_576
  @default_max_pending_notifications 1_000
  @default_max_pending_notification_bytes 1_048_576

  defmodule Data do
    @moduledoc false

    defstruct [
      :name,
      :registered,
      :backend,
      :backend_session,
      :task_supervisor,
      :agent_module,
      :agent_state,
      :current_request,
      :watchdog_ms,
      :max_tell_results,
      :max_tell_result_bytes,
      :max_events_per_turn,
      :max_event_bytes_per_turn,
      :event_retention,
      :max_pending_prompts,
      :max_pending_prompt_bytes,
      :max_pending_notifications,
      :max_pending_notification_bytes,
      halted: false,
      draining: false,
      # Flipped to true after `c:GenAgent.pre_run/1` has run successfully.
      # No prompts are dispatched before pre_run completes -- since pre_run
      # runs synchronously inside the agent process at init time, in practice
      # external calls that arrive during pre_run are held in the gen_statem
      # message queue and processed once pre_run returns.
      pre_run_done: false,
      self_chain: nil,
      mailbox: :queue.new(),
      ask_monitors: %{},
      pending_prompt_bytes: 0,
      # Events delivered via `GenAgent.notify/2` that arrived while
      # the agent was in `:processing` are buffered here instead of
      # having their `handle_event/2` callback invoked immediately.
      # Without this deferral, state mutations from `handle_event`
      # that happen during an in-flight turn are silently overwritten
      # when the task's `handle_response/3` runs with the snapshot
      # state from turn dispatch. The buffer is drained synchronously
      # at turn completion, before the agent transitions to `:idle`.
      pending_events: :queue.new(),
      pending_notification_bytes: 0,
      tell_results: %{},
      tell_result_order: :queue.new(),
      tell_result_bytes: 0,
      # Opt-in stream recipients by request ref. An entry exists from
      # admission until the request is dispatched, cancelled or failed.
      stream_recipients: %{}
    ]
  end

  # ---------------------------------------------------------------------------
  # Startup
  # ---------------------------------------------------------------------------

  def child_spec(opts) do
    shutdown = Keyword.get(opts, :shutdown, 5_000)

    unless shutdown == :infinity or (is_integer(shutdown) and shutdown >= 0) do
      raise ArgumentError, ":shutdown must be a non-negative integer or :infinity"
    end

    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [Keyword.delete(opts, :shutdown)]},
      # :temporary means the DynamicSupervisor does not auto-restart a dead
      # agent. This is the safer default for a framework where agents carry
      # conversation state (backend session id, message history, summary)
      # that cannot be rebuilt without persistence -- an auto-restart would
      # silently lose everything. Users who kill or crash an agent should
      # explicitly call `start_agent/2` again to get a fresh one.
      restart: :temporary,
      shutdown: shutdown,
      type: :worker
    }
  end

  def start_link(opts) do
    case Keyword.get(opts, :register) do
      nil ->
        :gen_statem.start_link(__MODULE__, opts, [])

      via ->
        :gen_statem.start_link(via, __MODULE__, opts, [])
    end
  end

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl :gen_statem
  def init(opts) do
    init_impl(opts)
  catch
    kind, reason ->
      reason_kind = callback_failure_kind(reason)
      Logger.error("GenAgent initialization failed (#{kind}: #{inspect(reason_kind)})")
      {:stop, {:init_failed, kind, reason_kind}}
  end

  defp init_impl(opts) do
    # Trap exits so that supervisor-initiated shutdowns via
    # `exit(pid, :shutdown)` arrive as {:EXIT, parent, :shutdown}
    # messages and trigger terminate/3 instead of killing the process
    # outright. Without this, `DynamicSupervisor.terminate_child/2`
    # bypasses our terminate callback and the in-flight task becomes
    # an orphan.
    Process.flag(:trap_exit, true)

    name = Keyword.fetch!(opts, :name)
    backend = Keyword.fetch!(opts, :backend)
    module = Keyword.fetch!(opts, :module)
    # Applications decide which metadata to render; a library must not change
    # the VM-wide Logger formatter to make its own keys visible by default.
    # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
    Logger.metadata(gen_agent: name, gen_agent_module: module)
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    init_opts = Keyword.get(opts, :init_opts, [])
    watchdog_ms = Keyword.get(opts, :watchdog_ms, @default_watchdog_ms)
    max_tell_results = Keyword.get(opts, :max_tell_results, @default_max_tell_results)

    max_tell_result_bytes =
      Keyword.get(opts, :max_tell_result_bytes, @default_max_tell_result_bytes)

    max_events_per_turn = Keyword.get(opts, :max_events_per_turn, @default_max_events_per_turn)

    max_event_bytes_per_turn =
      Keyword.get(opts, :max_event_bytes_per_turn, @default_max_event_bytes_per_turn)

    event_retention = Keyword.get(opts, :event_retention, @default_event_retention)

    max_pending_prompts = Keyword.get(opts, :max_pending_prompts, @default_max_pending_prompts)

    max_pending_prompt_bytes =
      Keyword.get(opts, :max_pending_prompt_bytes, @default_max_pending_prompt_bytes)

    max_pending_notifications =
      Keyword.get(opts, :max_pending_notifications, @default_max_pending_notifications)

    max_pending_notification_bytes =
      Keyword.get(opts, :max_pending_notification_bytes, @default_max_pending_notification_bytes)

    validate_watchdog!(watchdog_ms)
    validate_pending_limit!(max_tell_results, :max_tell_results)
    validate_pending_limit!(max_tell_result_bytes, :max_tell_result_bytes)
    validate_capture_limit!(max_events_per_turn, :max_events_per_turn)
    validate_capture_limit!(max_event_bytes_per_turn, :max_event_bytes_per_turn)
    validate_event_retention!(event_retention)
    validate_pending_limit!(max_pending_prompts, :max_pending_prompts)
    validate_pending_limit!(max_pending_prompt_bytes, :max_pending_prompt_bytes)
    validate_pending_limit!(max_pending_notifications, :max_pending_notifications)
    validate_pending_limit!(max_pending_notification_bytes, :max_pending_notification_bytes)

    with {:ok, backend_opts, agent_state} <- initialize_agent(module, init_opts),
         {:ok, backend_session} <- initialize_backend(backend, backend_opts) do
      data = %Data{
        name: name,
        registered:
          Keyword.get(opts, :register) ==
            {:via, Registry, {GenAgent.Registry, name}},
        backend: backend,
        backend_session: backend_session,
        task_supervisor: task_supervisor,
        agent_module: module,
        agent_state: agent_state,
        watchdog_ms: watchdog_ms,
        max_tell_results: max_tell_results,
        max_tell_result_bytes: max_tell_result_bytes,
        max_events_per_turn: max_events_per_turn,
        max_event_bytes_per_turn: max_event_bytes_per_turn,
        event_retention: event_retention,
        max_pending_prompts: max_pending_prompts,
        max_pending_prompt_bytes: max_pending_prompt_bytes,
        max_pending_notifications: max_pending_notifications,
        max_pending_notification_bytes: max_pending_notification_bytes
      }

      emit_state_change(name, nil, :idle)
      {:ok, :idle, data, [{:next_event, :internal, :pre_run}]}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp initialize_agent(module, opts) do
    case module.init_agent(opts) do
      {:ok, backend_opts, agent_state} -> {:ok, backend_opts, agent_state}
      {:error, reason} -> {:error, {:init_agent_failed, reason}}
      other -> {:error, {:init_agent_failed, other}}
    end
  end

  defp initialize_backend(backend, opts) do
    case backend.start_session(opts) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, {:backend_start_failed, reason}}
      other -> {:error, {:backend_start_failed, other}}
    end
  end

  @impl :gen_statem
  def terminate(reason, _state, %Data{} = data) do
    if graceful_termination?(reason) do
      reply_to_pending_asks(data, reason)
    end

    if data.current_request do
      cleanup_task(data.current_request)
    end

    safely_call(data.name, data.agent_module, :terminate_agent, [reason, data.agent_state])
    safely_call(data.name, data.backend, :terminate_session, [data.backend_session])
    :ok
  end

  def terminate(_reason, _state, _data), do: :ok

  defp graceful_termination?(reason) when reason in [:normal, :shutdown], do: true
  defp graceful_termination?(_reason), do: false

  defp reply_to_pending_asks(%Data{} = data, reason) do
    outcome = {:error, {:agent_terminated, reason}}

    case data.current_request do
      %{kind: {:ask, from}} -> :gen_statem.reply(from, outcome)
      _ -> :ok
    end

    Enum.each(:queue.to_list(data.mailbox), fn
      {_ref, {:ask, from}, _prompt} -> :gen_statem.reply(from, outcome)
      _other -> :ok
    end)
  end

  @impl :gen_statem
  def format_status(status) when is_map(status) do
    Map.new(status, fn
      {:data, %Data{} = data} -> {:data, redact_data(data)}
      {:data, _} -> {:data, :redacted}
      {key, events} when key in [:queue, :postponed] -> {key, redact_events(events)}
      {:log, log} -> {:log, redact_log(log)}
      {:reason, reason} -> {:reason, redact_status_reason(reason)}
      entry -> entry
    end)
  end

  def format_status(_), do: %{}

  defp redact_data(%Data{} = data) do
    %Data{
      data
      | backend_session: :redacted,
        agent_state: :redacted,
        current_request: :redacted,
        mailbox: :redacted,
        pending_events: :redacted,
        tell_results: :redacted,
        tell_result_order: :redacted,
        stream_recipients: :redacted,
        ask_monitors: :redacted,
        self_chain: :redacted
    }
  end

  defp redact_events(events) when is_list(events) do
    Enum.map(events, fn
      {event_type, _content} -> {redact_log_entry(event_type), :redacted}
      _ -> :redacted
    end)
  end

  defp redact_events(_), do: :redacted

  defp redact_log(log) when is_list(log), do: Enum.map(log, &redact_log_entry/1)
  defp redact_log(_), do: :redacted

  defp redact_log_entry(value) when is_atom(value), do: value

  defp redact_log_entry(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&redact_log_entry/1) |> List.to_tuple()
  end

  defp redact_log_entry(value) when is_list(value), do: Enum.map(value, &redact_log_entry/1)
  defp redact_log_entry(_), do: :redacted

  # Shutdown atoms identify routine exits. Other terms can contain a callback's
  # state or prompt, so the status formatter does not render their details.
  defp redact_status_reason(reason) when is_atom(reason), do: reason
  defp redact_status_reason({:shutdown, reason}) when is_atom(reason), do: {:shutdown, reason}
  defp redact_status_reason({:shutdown, _}), do: {:shutdown, :redacted}
  defp redact_status_reason(_), do: :redacted

  # ---------------------------------------------------------------------------
  # State enter actions
  # ---------------------------------------------------------------------------

  @impl :gen_statem
  def handle_event(type, event, state, data) do
    dispatch_event(type, event, state, data)
  catch
    kind, reason ->
      # A function-clause or callback exception can render all four callback
      # arguments in the OTP crash report, outside format_status/1's reach.
      # Stop with a content-free reason instead of exposing the live state.
      reason_kind = callback_failure_kind(reason)

      Logger.error(
        "GenAgent #{inspect(data.name)} #{inspect(data.agent_module)} state callback failed " <>
          "(#{kind}: #{inspect(reason_kind)})\n" <> redacted_stacktrace(__STACKTRACE__)
      )

      {:stop, {:callback_failed, kind, reason_kind}, data}
  end

  defp callback_failure_kind(%{__struct__: module}) when is_atom(module), do: module
  defp callback_failure_kind(_), do: :other

  defp dispatch_event(:enter, old_state, :idle, %Data{} = data) do
    if old_state != :idle do
      emit_state_change(data.name, old_state, :idle)
    end

    :keep_state_and_data
  end

  defp dispatch_event(:enter, old_state, :processing, %Data{} = data) do
    emit_state_change(data.name, old_state, :processing)
    {:keep_state_and_data, [{:state_timeout, data.watchdog_ms, :watchdog}]}
  end

  # ---------------------------------------------------------------------------
  # Internal: :pre_run -- one-time setup hook, fires after init, before
  # any user-visible turn. See `c:GenAgent.pre_run/1`.
  # ---------------------------------------------------------------------------

  defp dispatch_event(:internal, :pre_run, :idle, %Data{pre_run_done: true}) do
    :keep_state_and_data
  end

  defp dispatch_event(:internal, :pre_run, :idle, %Data{} = data) do
    case safely_pre_run(data.name, data.agent_module, data.agent_state) do
      {:ok, new_agent_state} ->
        {:keep_state, %{data | agent_state: new_agent_state, pre_run_done: true}}

      {:error, reason} ->
        {:stop, {:pre_run_failed, reason}, data}

      {:crashed, exception} ->
        {:stop, {:pre_run_crashed, callback_failure_kind(exception)}, data}

      _other ->
        Logger.error(
          "GenAgent #{inspect(data.name)} #{inspect(data.agent_module)}.pre_run/1 returned unexpected shape"
        )

        {:stop, :pre_run_invalid, data}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: :process_next -- decide what to do on entry to :idle
  # ---------------------------------------------------------------------------

  defp dispatch_event(:internal, :process_next, :idle, %Data{draining: true} = data) do
    {:stop, :normal, data}
  end

  defp dispatch_event(:internal, :process_next, :idle, %Data{halted: true}) do
    :keep_state_and_data
  end

  defp dispatch_event(:internal, :process_next, :idle, %Data{self_chain: prompt} = data)
       when is_binary(prompt) do
    data = %{data | self_chain: nil}
    request_ref = make_ref()
    try_dispatch(data, request_ref, :self_chain, prompt)
  end

  defp dispatch_event(:internal, :process_next, :idle, %Data{} = data) do
    case :queue.out(data.mailbox) do
      {:empty, _} ->
        :keep_state_and_data

      {{:value, {request_ref, kind, prompt}}, mailbox} ->
        data = %{
          data
          | mailbox: mailbox,
            pending_prompt_bytes: data.pending_prompt_bytes - :erlang.external_size(prompt)
        }

        data = clear_ask_monitor(data, request_ref)
        try_dispatch(data, request_ref, kind, prompt)
    end
  end

  # A rejected generated prompt can request another self-chain. Resume it
  # through the mailbox instead of a :next_event so callers can still inspect
  # or stop an agent whose pre_turn/2 keeps rejecting retries.
  defp dispatch_event(:info, :retry_generated_prompt, :idle, %Data{} = data),
    do: dispatch_event(:internal, :process_next, :idle, data)

  defp dispatch_event(:info, :retry_generated_prompt, :processing, _data),
    do: :keep_state_and_data

  # Stop admitting work before waiting for the active turn to finish.
  defp dispatch_event({:call, from}, :drain, state, %Data{} = data) do
    {data, queued_replies} = if data.draining, do: {data, []}, else: begin_drain(data)
    actions = queued_replies ++ [{:reply, from, :ok}]

    if state == :idle do
      {:keep_state, data, actions ++ [{:next_event, :internal, :process_next}]}
    else
      {:keep_state, data, actions}
    end
  end

  defp dispatch_event({:call, from}, {:ask, _prompt}, _state, %Data{draining: true} = data),
    do: reject_during_drain(data, from)

  defp dispatch_event({:call, from}, {:tell, _prompt}, _state, %Data{draining: true} = data),
    do: reject_during_drain(data, from)

  defp dispatch_event(
         {:call, from},
         {:tell_with_completion, _prompt, _recipient},
         _state,
         %Data{draining: true} = data
       ),
       do: reject_during_drain(data, from)

  defp dispatch_event(
         {:call, from},
         {:tell_with_completion, _prompt, _recipient, _on_halt},
         _state,
         %Data{draining: true} = data
       ),
       do: reject_during_drain(data, from)

  defp dispatch_event(
         {:call, from},
         {:tell_with_completion, _prompt, _recipient, _on_halt, _stream_to},
         _state,
         %Data{draining: true} = data
       ),
       do: reject_during_drain(data, from)

  defp dispatch_event(
         {:call, from},
         {:notify_ack, _event},
         _state,
         %Data{draining: true} = data
       ),
       do: reject_during_drain(data, from)

  defp dispatch_event(:cast, {:notify, _event}, _state, %Data{draining: true} = data) do
    emit_input_rejected(data.name, :draining)
    :keep_state_and_data
  end

  # ---------------------------------------------------------------------------
  # ask -- synchronous prompt
  # ---------------------------------------------------------------------------

  defp dispatch_event({:call, from}, {:ask, prompt}, :idle, %Data{halted: false} = data) do
    request_ref = make_ref()
    try_dispatch(data, request_ref, {:ask, from}, prompt)
  end

  defp dispatch_event({:call, from}, {:ask, prompt}, :idle, %Data{halted: true} = data) do
    queue_ask(data, from, prompt)
  end

  defp dispatch_event({:call, from}, {:ask, prompt}, :processing, %Data{} = data) do
    queue_ask(data, from, prompt)
  end

  # ---------------------------------------------------------------------------
  # tell -- async prompt, reply with ref immediately
  # ---------------------------------------------------------------------------

  defp dispatch_event({:call, from}, {:tell, prompt}, :idle, %Data{halted: false} = data) do
    request_ref = make_ref()

    case try_dispatch(data, request_ref, :tell, prompt) do
      {:next_state, :processing, data} ->
        {:next_state, :processing, data, [{:reply, from, {:ok, request_ref}}]}

      {:keep_state, data, actions} ->
        # pre_turn returned :skip or :halt -- the tell result is already
        # stored under request_ref via record_error, so the caller can
        # still poll. Reply with the ref as normal.
        {:keep_state, data, [{:reply, from, {:ok, request_ref}} | actions]}
    end
  end

  defp dispatch_event({:call, from}, {:tell, prompt}, :idle, %Data{halted: true} = data) do
    queue_tell(data, from, prompt)
  end

  defp dispatch_event({:call, from}, {:tell, prompt}, :processing, %Data{} = data) do
    queue_tell(data, from, prompt)
  end

  defp dispatch_event(
         {:call, from},
         {:tell_with_completion, prompt, recipient},
         :idle,
         %Data{halted: false} = data
       ) do
    request_ref = make_ref()

    case try_dispatch(data, request_ref, {:tell, recipient}, prompt) do
      {:next_state, :processing, data} ->
        {:next_state, :processing, data, [{:reply, from, {:ok, request_ref}}]}

      {:keep_state, data, actions} ->
        {:keep_state, data, [{:reply, from, {:ok, request_ref}} | actions]}
    end
  end

  defp dispatch_event(
         {:call, from},
         {:tell_with_completion, prompt, recipient},
         state,
         %Data{} = data
       )
       when state in [:idle, :processing] do
    queue_tell(data, from, prompt, recipient)
  end

  defp dispatch_event(
         {:call, from},
         {:tell_with_completion, _prompt, _recipient, :fail},
         :idle,
         %Data{halted: true}
       ) do
    {:keep_state_and_data, [{:reply, from, {:error, :halted}}]}
  end

  defp dispatch_event(
         {:call, from},
         {:tell_with_completion, prompt, recipient, on_halt},
         :idle,
         %Data{halted: false} = data
       ) do
    request_ref = make_ref()

    case try_dispatch(data, request_ref, {:tell, recipient, on_halt}, prompt) do
      {:next_state, :processing, data} ->
        {:next_state, :processing, data, [{:reply, from, {:ok, request_ref}}]}

      {:keep_state, data, actions} ->
        {:keep_state, data, [{:reply, from, {:ok, request_ref}} | actions]}
    end
  end

  defp dispatch_event(
         {:call, from},
         {:tell_with_completion, prompt, recipient, on_halt},
         state,
         %Data{} = data
       )
       when state in [:idle, :processing] do
    queue_tell(data, from, prompt, recipient, on_halt)
  end

  defp dispatch_event(
         {:call, from},
         {:tell_with_completion, _prompt, _recipient, :fail, _stream_to},
         :idle,
         %Data{halted: true}
       ) do
    {:keep_state_and_data, [{:reply, from, {:error, :halted}}]}
  end

  defp dispatch_event(
         {:call, from},
         {:tell_with_completion, prompt, recipient, on_halt, stream_to},
         :idle,
         %Data{halted: false} = data
       ) do
    request_ref = make_ref()
    data = put_stream_recipient(data, request_ref, stream_to)
    kind = tell_kind(recipient, on_halt)

    case try_dispatch(data, request_ref, kind, prompt) do
      {:next_state, :processing, data} ->
        {:next_state, :processing, data, [{:reply, from, {:ok, request_ref}}]}

      {:keep_state, data, actions} ->
        {:keep_state, data, [{:reply, from, {:ok, request_ref}} | actions]}
    end
  end

  defp dispatch_event(
         {:call, from},
         {:tell_with_completion, prompt, recipient, on_halt, stream_to},
         state,
         %Data{} = data
       )
       when state in [:idle, :processing] do
    queue_tell(data, from, prompt, recipient, on_halt, stream_to)
  end

  # poll -- check status of a previously-tell'd request
  # ---------------------------------------------------------------------------

  defp dispatch_event({:call, from}, {:poll, ref}, _state, %Data{} = data) do
    reply =
      cond do
        Map.has_key?(data.tell_results, ref) ->
          case Map.fetch!(data.tell_results, ref) do
            {:ok, response} -> {:ok, :completed, response}
            {:error, reason} -> {:error, reason}
          end

        match?(%{request_ref: ^ref}, data.current_request) ->
          {:ok, :pending}

        in_mailbox?(data.mailbox, ref) ->
          {:ok, :pending}

        true ->
          {:error, :not_found}
      end

    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  # ---------------------------------------------------------------------------
  # status -- read agent status
  # ---------------------------------------------------------------------------

  defp dispatch_event({:call, from}, :get_backend_session, _state, %Data{} = data) do
    {:keep_state_and_data, [{:reply, from, data.backend_session}]}
  end

  defp dispatch_event(
         {:call, {task_pid, _} = from},
         {:checkpoint_session, request_ref, session_id},
         :processing,
         %Data{current_request: %{request_ref: request_ref, task_pid: task_pid} = current} = data
       ) do
    cond do
      not function_exported?(data.backend, :checkpoint_session, 2) ->
        current = %{
          current
          | checkpoint_error: current.checkpoint_error || :unsupported_checkpoint
        }

        {:keep_state, %{data | current_request: current},
         [{:reply, from, {:error, :unsupported_checkpoint}}]}

      not valid_session_id?(session_id) ->
        current = %{current | checkpoint_error: current.checkpoint_error || :invalid_session_id}

        {:keep_state, %{data | current_request: current},
         [{:reply, from, {:error, :invalid_session_id}}]}

      current.checkpoint_id == session_id ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      current.checkpoint_id != nil ->
        current = %{
          current
          | checkpoint_error: current.checkpoint_error || :conflicting_session_id
        }

        {:keep_state, %{data | current_request: current},
         [{:reply, from, {:error, :conflicting_session_id}}]}

      true ->
        session = checkpoint_session(data.backend, data.backend_session, session_id)
        current = %{current | checkpoint_id: session_id}

        {:keep_state, %{data | backend_session: session, current_request: current},
         [{:reply, from, :ok}]}
    end
  end

  defp dispatch_event({:call, from}, {:checkpoint_session, _ref, _id}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_current}}]}
  end

  defp dispatch_event({:call, from}, :status, state, %Data{} = data) do
    status = %{
      state: state,
      name: data.name,
      queued: :queue.len(data.mailbox),
      current_request:
        case data.current_request do
          nil -> nil
          %{request_ref: ref} -> ref
        end,
      halted: data.halted,
      draining: data.draining,
      agent_state: data.agent_state
    }

    {:keep_state_and_data, [{:reply, from, status}]}
  end

  defp dispatch_event({:call, from}, :runtime_snapshot, state, %Data{} = data) do
    current_request =
      case data.current_request do
        nil ->
          nil

        current ->
          %{
            ref: current.request_ref,
            origin: request_origin(current.kind),
            elapsed_ms: max(System.monotonic_time(:millisecond) - current.started_at, 0),
            watchdog_ms: data.watchdog_ms
          }
      end

    snapshot = %{
      phase: state,
      halted: data.halted,
      draining: data.draining,
      pending_prompts: :queue.len(data.mailbox),
      pending_notifications: :queue.len(data.pending_events),
      self_chain_pending: not is_nil(data.self_chain),
      current_request: current_request
    }

    {:keep_state_and_data, [{:reply, from, snapshot}]}
  end

  # ---------------------------------------------------------------------------
  # notify -- external event dispatched to handle_event/2
  #
  # When the agent is in :idle, the event is processed immediately.
  # When the agent is in :processing, the event is buffered into
  # pending_events and processed synchronously at turn completion,
  # BEFORE transitioning to :idle. This prevents state mutations
  # from handle_event callbacks from being silently overwritten by
  # the in-flight task's handle_response result.
  # ---------------------------------------------------------------------------

  defp dispatch_event(:cast, {:notify, event}, :processing, %Data{} = data),
    do: notify_processing(data, event, nil)

  defp dispatch_event({:call, from}, {:notify_ack, event}, :processing, %Data{} = data),
    do: notify_processing(data, event, from)

  defp dispatch_event(:cast, {:notify, event}, :idle, %Data{} = data),
    do: notify_idle(data, event, nil)

  defp dispatch_event({:call, from}, {:notify_ack, event}, :idle, %Data{} = data),
    do: notify_idle(data, event, from)

  # interrupt -- kill current task, deliver :interrupted
  # ---------------------------------------------------------------------------

  defp dispatch_event(:cast, :interrupt, :processing, %Data{current_request: current} = data)
       when not is_nil(current) do
    cleanup_task(current)
    finish_error(data, current, :interrupted)
  end

  defp dispatch_event(:cast, :interrupt, _state, _data), do: :keep_state_and_data

  defp dispatch_event(
         {:call, from},
         {:interrupt_request, expected_ref},
         :processing,
         %Data{current_request: %{request_ref: current_ref} = current} = data
       )
       when expected_ref == current_ref do
    cleanup_task(current)
    {:next_state, state, data, actions} = finish_error(data, current, :interrupted)
    {:next_state, state, data, [{:reply, from, {:ok, :accepted}} | actions]}
  end

  defp dispatch_event({:call, from}, {:interrupt_request, _ref}, :processing, %Data{} = data) do
    {:keep_state, data, [{:reply, from, {:error, :not_current}}]}
  end

  defp dispatch_event({:call, from}, {:interrupt_request, _ref}, _state, %Data{} = data) do
    {:keep_state, data, [{:reply, from, {:error, :idle}}]}
  end

  # ---------------------------------------------------------------------------
  # cancel_request -- remove only a queued tell with the exact ref
  # ---------------------------------------------------------------------------

  defp dispatch_event({:call, from}, {:cancel_request, ref}, _state, %Data{} = data) do
    cond do
      current_tell_ref?(data.current_request, ref) ->
        {:keep_state_and_data, [{:reply, from, {:error, :current}}]}

      Map.get(data.tell_results, ref) == {:error, :cancelled} ->
        {:keep_state_and_data, [{:reply, from, {:ok, :cancelled}}]}

      Map.has_key?(data.tell_results, ref) ->
        {:keep_state_and_data, [{:reply, from, {:error, :already_finished}}]}

      true ->
        cancel_queued_tell(data, from, ref)
    end
  end

  # ---------------------------------------------------------------------------
  # resume -- unhalt and re-trigger drain
  # ---------------------------------------------------------------------------

  defp dispatch_event(:cast, :resume, :idle, %Data{halted: true} = data) do
    data = %{data | halted: false}
    {:keep_state, data, [{:next_event, :internal, :process_next}]}
  end

  defp dispatch_event(:cast, :resume, _state, _data), do: :keep_state_and_data

  # ---------------------------------------------------------------------------
  # Watchdog timeout
  # ---------------------------------------------------------------------------

  defp dispatch_event(
         :state_timeout,
         :watchdog,
         :processing,
         %Data{current_request: current} = data
       ) do
    cleanup_task(current)
    finish_error(data, current, :timeout)
  end

  # ---------------------------------------------------------------------------
  # Task completion messages
  # ---------------------------------------------------------------------------

  defp dispatch_event(
         :info,
         {ref, task_result},
         :processing,
         %Data{current_request: current} = data
       )
       when is_reference(ref) and is_map(current) do
    case current do
      %{task_ref: ^ref} ->
        Process.demonitor(ref, [:flush])
        handle_task_result(task_result, current, data)

      _ ->
        :keep_state_and_data
    end
  end

  defp dispatch_event(:info, {:DOWN, mon, :process, _pid, _reason}, _state, %Data{} = data)
       when is_map_key(data.ask_monitors, mon) do
    {request_ref, ask_monitors} = Map.pop(data.ask_monitors, mon)
    data = %{data | ask_monitors: ask_monitors}

    case find_queued_entry(data.mailbox, request_ref) do
      {^request_ref, {:ask, _from} = kind, prompt} ->
        data = remove_queued_entry(data, request_ref, prompt)
        emit_turn_cancelled(data.name, request_ref, kind, :caller_down)
        {:keep_state, data}

      nil ->
        {:keep_state, data}
    end
  end

  defp dispatch_event(
         :info,
         {:DOWN, ref, :process, _pid, reason},
         :processing,
         %Data{current_request: current} = data
       )
       when is_reference(ref) and is_map(current) do
    case current do
      %{task_ref: ^ref} ->
        finish_error(data, current, current.checkpoint_error || {:task_crashed, reason})

      _ ->
        :keep_state_and_data
    end
  end

  # Stream events relayed from the prompt task. Only the active request's
  # events are forwarded; anything from a finished request is dropped.
  defp dispatch_event(
         :info,
         {:gen_agent_stream, ref, tag, event},
         :processing,
         %Data{current_request: %{request_ref: ref, stream_to: stream_to, stream_tag: tag}} = data
       )
       when is_pid(stream_to) do
    send(stream_to, {:gen_agent, :event, data.name, ref, event})
    :keep_state_and_data
  end

  # Registry registration links the agent to its Registry partition. Because
  # agents trap exits to clean up prompt tasks, losing that partition would
  # otherwise leave a live agent that can no longer be addressed by name.
  # Prompt tasks are linked too, so verify ownership instead of treating every
  # linked-process exit as a Registry failure.
  defp dispatch_event(:info, {:EXIT, _pid, _reason}, _state, %Data{registered: true} = data) do
    if registered_here?(data.name) do
      :keep_state_and_data
    else
      {:stop, {:shutdown, :registry_lost}, data}
    end
  end

  defp dispatch_event(:info, _msg, _state, _data), do: :keep_state_and_data

  defp reject_during_drain(data, from) do
    emit_input_rejected(data.name, :draining)
    {:keep_state_and_data, [{:reply, from, {:error, :draining}}]}
  end

  defp begin_drain(%Data{} = data) do
    {data, replies} =
      Enum.reduce(:queue.to_list(data.mailbox), {data, []}, fn {ref, kind, _prompt},
                                                               {data, replies} ->
        emit_turn_rejected(data.name, ref, kind, :draining)
        {data, reply} = record_error(data, %{request_ref: ref, kind: kind}, :draining)
        {data, Enum.reverse(reply, replies)}
      end)

    Enum.each(Map.keys(data.ask_monitors), &Process.demonitor(&1, [:flush]))

    {%{
       data
       | draining: true,
         mailbox: :queue.new(),
         ask_monitors: %{},
         pending_prompt_bytes: 0,
         pending_events: :queue.new(),
         pending_notification_bytes: 0,
         self_chain: nil,
         stream_recipients: %{}
     }, Enum.reverse(replies)}
  end

  defp registered_here?(name) do
    Registry.whereis_name({GenAgent.Registry, name}) == self()
  catch
    # The Registry may still be down when its linked partition's EXIT arrives.
    _, _ -> false
  end

  defp request_origin({:ask, _from}), do: :ask
  defp request_origin({:tell, _recipient}), do: :tell
  defp request_origin({:tell, _recipient, _on_halt}), do: :tell
  defp request_origin(kind) when kind in [:tell, :event, :self_chain], do: kind

  defp handle_task_result({:ok, response, new_session, new_agent_state}, current, data) do
    if current.checkpoint_error do
      finish_error(%{data | agent_state: new_agent_state}, current, current.checkpoint_error)
    else
      new_session = restore_checkpoint(data.backend, new_session, current)
      emit_prompt_stop(data.name, current.request_ref, response.duration_ms, new_agent_state)
      emit_turn_stop(data.name, current)
      finish_turn(data, current, response, new_session, new_agent_state)
    end
  end

  defp handle_task_result({:error, reason, new_session, new_agent_state}, current, data) do
    new_session = restore_checkpoint(data.backend, new_session, current)
    data = %{data | backend_session: new_session, agent_state: new_agent_state}
    finish_error(data, current, current.checkpoint_error || reason)
  end

  # ---------------------------------------------------------------------------
  defp queue_ask(data, from, prompt) do
    request_ref = make_ref()

    case enqueue_prompt(data, request_ref, {:ask, from}, prompt) do
      {:ok, queued} ->
        monitor = Process.monitor(elem(from, 0))

        {:keep_state,
         %{queued | ask_monitors: Map.put(queued.ask_monitors, monitor, request_ref)}}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp cancel_queued_tell(data, from, ref) do
    case find_queued_entry(data.mailbox, ref) do
      {^ref, :tell, prompt} ->
        finish_queued_tell_cancel(data, from, ref, :tell, prompt)

      {^ref, {:tell, _recipient} = kind, prompt} ->
        finish_queued_tell_cancel(data, from, ref, kind, prompt)

      {^ref, {:tell, _recipient, _on_halt} = kind, prompt} ->
        finish_queued_tell_cancel(data, from, ref, kind, prompt)

      _ ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_found}}]}
    end
  end

  defp current_tell_ref?(%{request_ref: ref, kind: :tell}, ref), do: true
  defp current_tell_ref?(%{request_ref: ref, kind: {:tell, _recipient}}, ref), do: true
  defp current_tell_ref?(%{request_ref: ref, kind: {:tell, _recipient, _on_halt}}, ref), do: true
  defp current_tell_ref?(_current, _ref), do: false

  defp finish_queued_tell_cancel(data, from, ref, kind, prompt) do
    data = remove_queued_entry(data, ref, prompt)
    data = %{data | stream_recipients: Map.delete(data.stream_recipients, ref)}
    data = store_tell_result(data, ref, {:error, :cancelled})

    if recipient = completion_recipient(kind) do
      send(recipient, {:gen_agent, :completion, data.name, ref, {:error, :cancelled}})
    end

    emit_turn_cancelled(data.name, ref, kind, :caller_cancelled)
    {:keep_state, data, [{:reply, from, {:ok, :cancelled}}]}
  end

  defp find_queued_entry(mailbox, ref) do
    Enum.find(:queue.to_list(mailbox), fn {request_ref, _kind, _prompt} -> request_ref == ref end)
  end

  defp remove_queued_entry(data, ref, prompt) do
    mailbox =
      :queue.filter(fn {request_ref, _kind, _prompt} -> request_ref != ref end, data.mailbox)

    %{
      data
      | mailbox: mailbox,
        pending_prompt_bytes: data.pending_prompt_bytes - :erlang.external_size(prompt)
    }
  end

  defp clear_ask_monitor(data, request_ref) do
    case Enum.find(data.ask_monitors, fn {_monitor, ref} -> ref == request_ref end) do
      {monitor, ^request_ref} ->
        Process.demonitor(monitor, [:flush])
        %{data | ask_monitors: Map.delete(data.ask_monitors, monitor)}

      nil ->
        data
    end
  end

  defp completion_recipient({:tell, recipient}), do: recipient
  defp completion_recipient({:tell, recipient, _on_halt}), do: recipient
  defp completion_recipient(_kind), do: nil

  defp tell_kind(nil, _on_halt), do: :tell
  defp tell_kind(recipient, :queue), do: {:tell, recipient}
  defp tell_kind(recipient, on_halt), do: {:tell, recipient, on_halt}

  defp put_stream_recipient(data, _ref, nil), do: data

  defp put_stream_recipient(data, ref, pid),
    do: %{data | stream_recipients: Map.put(data.stream_recipients, ref, pid)}

  defp queue_tell(data, from, prompt, recipient \\ nil, on_halt \\ :queue, stream_to \\ nil) do
    request_ref = make_ref()
    kind = tell_kind(recipient, on_halt)

    case enqueue_prompt(data, request_ref, kind, prompt) do
      {:ok, queued} ->
        queued = put_stream_recipient(queued, request_ref, stream_to)
        {:keep_state, queued, [{:reply, from, {:ok, request_ref}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp enqueue_prompt(data, request_ref, kind, prompt) do
    incoming_bytes = :erlang.external_size(prompt)

    case overload_reason(
           :prompts,
           :queue.len(data.mailbox),
           data.pending_prompt_bytes,
           incoming_bytes,
           data.max_pending_prompts,
           data.max_pending_prompt_bytes
         ) do
      nil ->
        mailbox = :queue.in({request_ref, kind, prompt}, data.mailbox)
        emit_mailbox_queued(data.name, :queue.len(mailbox))

        {:ok,
         %{
           data
           | mailbox: mailbox,
             pending_prompt_bytes: data.pending_prompt_bytes + incoming_bytes
         }}

      reason ->
        emit_input_rejected(data.name, reason)
        emit_turn_rejected(data.name, request_ref, kind, :overloaded)
        {:error, reason}
    end
  end

  defp enqueue_notification(data, event) do
    incoming_bytes = :erlang.external_size(event)

    case overload_reason(
           :notifications,
           :queue.len(data.pending_events),
           data.pending_notification_bytes,
           incoming_bytes,
           data.max_pending_notifications,
           data.max_pending_notification_bytes
         ) do
      nil ->
        pending_events = :queue.in(event, data.pending_events)

        {:ok,
         %{
           data
           | pending_events: pending_events,
             pending_notification_bytes: data.pending_notification_bytes + incoming_bytes
         }}

      reason ->
        emit_input_rejected(data.name, reason)
        {:error, reason}
    end
  end

  # Self-chaining has one reserved slot so a callback can make progress even
  # when callers have filled the FIFO. It still obeys the prompt byte cap.
  defp enqueue_self_chain(data, prompt) do
    incoming_bytes = :erlang.external_size(prompt)
    pending_count = if(is_nil(data.self_chain), do: 0, else: 1)

    pending_bytes =
      if(is_nil(data.self_chain), do: 0, else: :erlang.external_size(data.self_chain))

    case overload_reason(
           :self_chain,
           pending_count,
           pending_bytes,
           incoming_bytes,
           1,
           data.max_pending_prompt_bytes
         ) do
      nil ->
        {:ok, %{data | self_chain: prompt}}

      reason ->
        emit_input_rejected(data.name, reason)
        {:error, reason}
    end
  end

  defp accept_self_chain(data, prompt) do
    case enqueue_self_chain(data, prompt) do
      {:ok, queued} -> queued
      {:error, reason} -> reject_generated_prompt(data, make_ref(), reason)
    end
  end

  defp overload_reason(queue, count, bytes, incoming_bytes, max_count, max_bytes) do
    limit =
      cond do
        count >= max_count -> :count
        incoming_bytes > max_bytes - bytes -> :bytes
        true -> nil
      end

    if limit do
      {:overloaded,
       %{
         queue: queue,
         limit: limit,
         pending_count: count,
         pending_bytes: bytes,
         incoming_bytes: incoming_bytes,
         max_count: max_count,
         max_bytes: max_bytes
       }}
    end
  end

  # ---------------------------------------------------------------------------
  defp notify_processing(data, event, from) do
    emit_event_received(data.name, event)

    case enqueue_notification(data, event) do
      {:ok, queued} -> reply_notification(from, {:keep_state, queued}, :ok)
      {:error, reason} -> reply_notification(from, {:keep_state, data}, {:error, reason})
    end
  end

  defp notify_idle(data, event, from) do
    emit_event_received(data.name, event)

    {result, acknowledgement} =
      case safely_handle_event(data.name, data.agent_module, event, data.agent_state) do
        {:noreply, new_agent_state} ->
          {{:keep_state, %{data | agent_state: new_agent_state}}, :ok}

        {:prompt, prompt, new_agent_state} ->
          notify_idle_prompt(%{data | agent_state: new_agent_state}, prompt)

        {:halt, new_agent_state} ->
          data = %{data | agent_state: new_agent_state}
          data = transition_to_halted(data)
          {{:keep_state, data}, :ok}
      end

    reply_notification(from, result, acknowledgement)
  end

  defp notify_idle_prompt(data, prompt) do
    request_ref = make_ref()

    if data.halted do
      case enqueue_prompt(data, request_ref, :event, prompt) do
        {:ok, queued} ->
          {{:keep_state, queued}, :ok}

        {:error, reason} ->
          rejected = reject_generated_prompt(data, request_ref, reason)
          {{:keep_state, rejected}, {:error, reason}}
      end
    else
      {try_dispatch(data, request_ref, :event, prompt), :ok}
    end
  end

  defp reply_notification(nil, result, _acknowledgement), do: result

  defp reply_notification(from, {:keep_state, data}, acknowledgement),
    do: {:keep_state, data, [{:reply, from, acknowledgement}]}

  defp reply_notification(from, {:keep_state, data, actions}, acknowledgement),
    do: {:keep_state, data, [{:reply, from, acknowledgement} | actions]}

  defp reply_notification(from, {:next_state, state, data}, acknowledgement),
    do: {:next_state, state, data, [{:reply, from, acknowledgement}]}

  # ---------------------------------------------------------------------------
  # Dispatch + task plumbing
  # ---------------------------------------------------------------------------

  # Called from every place that would previously have called `dispatch`
  # directly. Runs `pre_turn/2` first and branches on its return:
  #
  #   {:ok, prompt, state} -- normal dispatch to the backend task.
  #   {:skip, state}       -- reject the prompt with :pre_turn_skipped.
  #                           Generated prompts also notify handle_error/3.
  #   {:halt, state}       -- same as skip, plus transition_to_halted.
  #
  # Returns a gen_statem handle_event result tuple.
  defp try_dispatch(%Data{} = data, request_ref, kind, prompt) do
    # Take the stream recipient out of the map here so every outcome below
    # (dispatch, skip, halt, rejection) leaves nothing behind.
    {stream_to, recipients} = Map.pop(data.stream_recipients, request_ref)
    data = %{data | stream_recipients: recipients}

    case safely_pre_turn(data.name, data.agent_module, prompt, data.agent_state) do
      {:returned, {:ok, new_prompt, new_state}} when is_binary(new_prompt) ->
        data = %{data | agent_state: new_state}

        case dispatch(data, request_ref, kind, new_prompt, prompt, stream_to) do
          {:ok, data} ->
            {:next_state, :processing, data}

          {:error, reason} ->
            reject_dispatch(data, request_ref, kind, reason)
        end

      {:returned, {:skip, new_state}} ->
        pseudo_current = %{request_ref: request_ref, kind: kind}
        data = %{data | agent_state: new_state}
        emit_turn_rejected(data.name, request_ref, kind, :pre_turn_skipped)
        {data, reply_actions} = reject_pre_turn(data, pseudo_current, :pre_turn_skipped)
        {:keep_state, data, after_pre_turn_rejection(data, kind, reply_actions)}

      {:returned, {:halt, new_state}} ->
        pseudo_current = %{request_ref: request_ref, kind: kind}
        data = %{data | agent_state: new_state}
        emit_turn_rejected(data.name, request_ref, kind, :pre_turn_halted)
        {data, reply_actions} = record_error(data, pseudo_current, :pre_turn_halted)
        data = transition_to_halted(data)
        {:keep_state, data, with_process_next(reply_actions)}

      {:crashed, failure_kind} ->
        pseudo_current = %{request_ref: request_ref, kind: kind}
        reason = pre_turn_crash_reason(kind, failure_kind)
        emit_turn_rejected(data.name, request_ref, kind, reason)
        {data, reply_actions} = reject_pre_turn(data, pseudo_current, reason)
        {:keep_state, data, after_pre_turn_rejection(data, kind, reply_actions)}

      {:returned, _other} ->
        # Malformed pre_turn return -- treat as skip with a warning.
        Logger.warning(
          "GenAgent #{inspect(data.name)} #{inspect(data.agent_module)}.pre_turn/2 returned unexpected shape"
        )

        pseudo_current = %{request_ref: request_ref, kind: kind}
        emit_turn_rejected(data.name, request_ref, kind, :pre_turn_invalid)
        {data, reply_actions} = reject_pre_turn(data, pseudo_current, :pre_turn_invalid)
        {:keep_state, data, after_pre_turn_rejection(data, kind, reply_actions)}
    end
  end

  defp after_pre_turn_rejection(data, kind, reply_actions)
       when kind in [:self_chain, :event] and not is_nil(data.self_chain) and not data.halted do
    # A small delay bounds a permanently failing retry loop, and the info
    # message gives existing callers a chance to enter the agent mailbox.
    Process.send_after(self(), :retry_generated_prompt, 10)
    reply_actions
  end

  defp after_pre_turn_rejection(_data, _kind, reply_actions),
    do: with_process_next(reply_actions)

  defp pre_turn_crash_reason(kind, failure_kind) when kind in [:self_chain, :event],
    do: {:pre_turn_crashed, failure_kind}

  # Preserve the existing external caller response while distinguishing an
  # autonomous prompt failure for handle_error/3 and telemetry consumers.
  defp pre_turn_crash_reason(_kind, _failure_kind), do: :pre_turn_skipped

  defp reject_pre_turn(data, %{kind: kind, request_ref: ref}, reason)
       when kind in [:self_chain, :event],
       do: {reject_generated_prompt(data, ref, reason), []}

  defp reject_pre_turn(data, pseudo_current, reason),
    do: record_error(data, pseudo_current, reason)

  defp dispatch(%Data{} = data, request_ref, kind, prompt, original_prompt, stream_to) do
    backend = data.backend
    backend_session = data.backend_session
    module = data.agent_module
    agent_state = data.agent_state
    task_supervisor = data.task_supervisor
    max_events_per_turn = data.max_events_per_turn
    max_event_bytes_per_turn = data.max_event_bytes_per_turn
    event_retention = data.event_retention
    owner = self()
    stream_tag = if stream_to, do: make_ref()

    # Link the task to its owning agent as well as the shared supervisor.
    # Even an untrappable agent exit must take its in-flight turn down.
    # The agent traps exits, so task failures still flow through :DOWN
    # and handle_error/3 without crashing the agent or other agents.
    task =
      try do
        {:ok,
         Task.Supervisor.async(task_supervisor, fn ->
           run_prompt(
             backend,
             backend_session,
             module,
             agent_state,
             prompt,
             {max_events_per_turn, max_event_bytes_per_turn, event_retention},
             {owner, request_ref, stream_tag}
           )
         end)}
      catch
        :exit, {:noproc, _} -> {:error, :task_supervisor_unavailable}
        :exit, :noproc -> {:error, :task_supervisor_unavailable}
      end

    case task do
      {:ok, task} ->
        started_at = System.monotonic_time(:millisecond)
        emit_prompt_start(data.name, request_ref, prompt, original_prompt, agent_state)
        emit_turn_start(data.name, request_ref, kind)

        current = %{
          request_ref: request_ref,
          task_ref: task.ref,
          task_pid: task.pid,
          kind: kind,
          stream_to: stream_to,
          stream_tag: stream_tag,
          prompt: prompt,
          started_at: started_at,
          checkpoint_id: nil,
          checkpoint_error: nil
        }

        {:ok, %{data | current_request: current}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_dispatch(%Data{} = data, request_ref, kind, reason) do
    emit_turn_rejected(data.name, request_ref, kind, reason)
    emit_prompt_error(data.name, request_ref, reason, data.agent_state)

    # A retry cannot start until the caller restores the task supervisor.
    # Discard an immediate retry from handle_error/3 to avoid an internal loop.
    decision =
      safely_handle_error(data.name, data.agent_module, request_ref, reason, data.agent_state)

    {transition, decision_state} = decision_to_transition(decision)

    {:ok, hooked_state} =
      safely_post_turn(
        data.name,
        data.agent_module,
        {:error, reason},
        request_ref,
        decision_state
      )

    pseudo_current = %{request_ref: request_ref, kind: kind}
    {data, reply_actions} = record_error(data, pseudo_current, reason)
    data = %{data | agent_state: hooked_state}

    data =
      if transition == :halt, do: transition_to_halted(data), else: data

    {:keep_state, data, with_process_next(reply_actions)}
  end

  defp run_prompt(
         backend,
         backend_session,
         module,
         agent_state,
         prompt,
         {max_events_per_turn, max_event_bytes_per_turn, event_retention},
         {owner, request_ref, stream_tag}
       ) do
    started = System.monotonic_time(:millisecond)
    handler = {module, if(stream_tag, do: {owner, request_ref, stream_tag})}

    checkpoint = fn id ->
      :gen_statem.call(owner, {:checkpoint_session, request_ref, id})
    end

    prompt_result =
      if function_exported?(backend, :prompt, 3) do
        backend.prompt(backend_session, prompt, %{checkpoint: checkpoint})
      else
        backend.prompt(backend_session, prompt)
      end

    case prompt_result do
      {:ok, stream, backend_session} ->
        consume_stream(
          stream,
          backend,
          backend_session,
          handler,
          agent_state,
          started,
          {max_events_per_turn, max_event_bytes_per_turn},
          event_retention
        )

      {:error, reason} ->
        {:error, reason, backend_session, agent_state}
    end
  end

  defp consume_stream(
         stream,
         backend,
         backend_session,
         module,
         agent_state,
         started,
         {max_events, max_bytes},
         :lossless
       ) do
    initial = {:ok, [], agent_state, 0, 0, nil}

    result =
      Enum.reduce_while(stream, initial, fn event, accumulator ->
        capture_event(event, accumulator, module, max_events, max_bytes)
      end)

    case result do
      {:overflow, limit, state, count, bytes, kind, event_bytes} ->
        reason =
          {:event_capture_overflow,
           %{
             limit: limit,
             max_events: max_events,
             max_bytes: max_bytes,
             retained_events: count,
             retained_bytes: bytes,
             rejected_event_kind: kind,
             rejected_event_bytes: event_bytes
           }}

        {:error, reason, backend_session, state}

      {:ok, reversed_events, state, _count, _bytes, terminal} ->
        finish_stream(reversed_events, terminal, backend, backend_session, state, started)
    end
  end

  defp consume_stream(
         stream,
         backend,
         backend_session,
         module,
         agent_state,
         started,
         {max_events, max_bytes},
         :compact
       ) do
    initial = %{
      events: [],
      state: agent_state,
      retained_events: 0,
      retained_bytes: 0,
      observed_events: 0,
      omitted_events: 0,
      first_omission: nil,
      text_acc: Response.new_text_acc(),
      usage: nil,
      terminal: nil
    }

    capture =
      Enum.reduce_while(stream, initial, fn event, capture ->
        capture = capture_compact_event(event, capture, module, max_events, max_bytes)
        if capture.terminal, do: {:halt, capture}, else: {:cont, capture}
      end)

    case capture.terminal do
      nil ->
        {:error, :no_terminal_event, backend_session, capture.state}

      %Event{kind: :error, data: data} ->
        {:error, Map.get(data, :reason, :unknown), backend_session, capture.state}

      %Event{kind: :result, data: data} = terminal ->
        backend_session = maybe_update_session(backend, backend_session, data)

        coverage = %{
          mode: if(capture.omitted_events == 0, do: :exact, else: :compact),
          observed_events: capture.observed_events,
          retained_events: capture.retained_events,
          omitted_events: capture.omitted_events,
          retained_bytes: capture.retained_bytes,
          first_omission: capture.first_omission
        }

        response =
          Response.from_capture(
            Enum.reverse(capture.events),
            terminal,
            capture.usage,
            capture.text_acc,
            duration_ms: System.monotonic_time(:millisecond) - started,
            session_id: Map.get(data, :session_id),
            event_coverage: coverage
          )

        {:ok, response, backend_session, capture.state}
    end
  end

  defp capture_compact_event(%Event{} = event, capture, module, max_events, max_bytes) do
    state = maybe_handle_stream_event(module, event, capture.state)

    capture = %{
      capture
      | state: state,
        observed_events: capture.observed_events + 1,
        text_acc: Response.append_text(event, capture.text_acc),
        usage: if(event.kind == :usage, do: event.data, else: capture.usage),
        terminal: if(Event.terminal?(event), do: event, else: nil)
    }

    if capture.first_omission do
      %{capture | omitted_events: capture.omitted_events + 1}
    else
      event_bytes = :erlang.external_size(event)

      cond do
        capture.retained_events >= max_events ->
          omit_compact_event(capture, :events, event.kind)

        event_bytes > max_bytes - capture.retained_bytes ->
          omit_compact_event(capture, :bytes, event.kind)

        true ->
          %{
            capture
            | events: [event | capture.events],
              retained_events: capture.retained_events + 1,
              retained_bytes: capture.retained_bytes + event_bytes
          }
      end
    end
  end

  defp omit_compact_event(capture, limit, kind) do
    %{
      capture
      | omitted_events: capture.omitted_events + 1,
        first_omission: %{limit: limit, event_kind: kind}
    }
  end

  defp capture_event(
         %Event{} = event,
         {:ok, events, state, count, bytes, _terminal},
         module,
         max_events,
         max_bytes
       ) do
    event_bytes = :erlang.external_size(event)

    cond do
      count >= max_events ->
        {:halt, {:overflow, :events, state, count, bytes, event.kind, event_bytes}}

      event_bytes > max_bytes - bytes ->
        {:halt, {:overflow, :bytes, state, count, bytes, event.kind, event_bytes}}

      true ->
        state = maybe_handle_stream_event(module, event, state)
        terminal = if Event.terminal?(event), do: event, else: nil
        accepted = {:ok, [event | events], state, count + 1, bytes + event_bytes, terminal}

        if terminal, do: {:halt, accepted}, else: {:cont, accepted}
    end
  end

  defp finish_stream(_events, nil, _backend, backend_session, agent_state, _started) do
    {:error, :no_terminal_event, backend_session, agent_state}
  end

  defp finish_stream(_events, %Event{kind: :error, data: data}, _backend, session, state, _) do
    {:error, Map.get(data, :reason, :unknown), session, state}
  end

  defp finish_stream(events, %Event{kind: :result, data: data}, backend, session, state, started) do
    session = maybe_update_session(backend, session, data)

    response =
      Response.from_events(Enum.reverse(events),
        duration_ms: System.monotonic_time(:millisecond) - started,
        session_id: Map.get(data, :session_id)
      )

    {:ok, response, session, state}
  end

  defp validate_capture_limit!(value, _name) when is_integer(value) and value > 0, do: :ok

  defp validate_capture_limit!(value, name) do
    raise ArgumentError, "#{name} must be a positive integer, got: #{inspect(value)}"
  end

  defp validate_watchdog!(:infinity), do: :ok
  defp validate_watchdog!(value) when is_integer(value) and value > 0, do: :ok

  defp validate_watchdog!(value) do
    raise ArgumentError,
          "watchdog_ms must be a positive integer or :infinity, got: #{inspect(value)}"
  end

  defp validate_event_retention!(mode) when mode in [:compact, :lossless], do: :ok

  defp validate_event_retention!(_mode) do
    raise ArgumentError, "event_retention must be :compact or :lossless"
  end

  defp validate_pending_limit!(value, _name) when is_integer(value) and value >= 0, do: :ok

  defp validate_pending_limit!(value, name) do
    raise ArgumentError, "#{name} must be a non-negative integer, got: #{inspect(value)}"
  end

  # Runs the callback, then relays the event to the owner for opted-in
  # requests. The owner forwards it, so it precedes the completion message.
  defp maybe_handle_stream_event({module, relay}, event, state) do
    state =
      if function_exported?(module, :handle_stream_event, 2) do
        module.handle_stream_event(event, state)
      else
        state
      end

    with {owner, request_ref, tag} <- relay do
      send(owner, {:gen_agent_stream, request_ref, tag, event})
    end

    state
  end

  defp maybe_update_session(backend, session, data) do
    if function_exported?(backend, :update_session, 2) do
      backend.update_session(session, data)
    else
      session
    end
  end

  defp valid_session_id?(id) when is_binary(id) and byte_size(id) in 1..1024 do
    String.valid?(id) and not String.match?(id, ~r/[\x00-\x1F\x7F]/)
  end

  defp valid_session_id?(_), do: false

  defp checkpoint_session(backend, session, id) do
    if function_exported?(backend, :checkpoint_session, 2) do
      backend.checkpoint_session(session, id)
    else
      session
    end
  end

  defp restore_checkpoint(_backend, session, %{checkpoint_id: nil}), do: session

  defp restore_checkpoint(backend, session, %{checkpoint_id: id}),
    do: checkpoint_session(backend, session, id)

  defp cleanup_task(%{task_pid: pid, task_ref: ref}) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp safely_handle_event(name, module, event, state) do
    decision =
      if function_exported?(module, :handle_event, 2) do
        module.handle_event(event, state)
      else
        {:noreply, state}
      end

    normalize_decision(decision, name, module, :handle_event, state)
  rescue
    e ->
      Logger.error(
        "GenAgent #{inspect(name)} #{inspect(module)}.handle_event/2 raised " <>
          "#{inspect(callback_failure_kind(e))}\n" <> redacted_stacktrace(__STACKTRACE__)
      )

      {:noreply, state}
  catch
    kind, reason ->
      Logger.error(
        "GenAgent #{inspect(name)} #{inspect(module)}.handle_event/2 threw " <>
          "#{kind}: #{inspect(callback_failure_kind(reason))}\n" <>
          redacted_stacktrace(__STACKTRACE__)
      )

      {:noreply, state}
  end

  defp normalize_decision({:noreply, _state} = decision, _name, _module, _callback, _old_state),
    do: decision

  defp normalize_decision({:halt, _state} = decision, _name, _module, _callback, _old_state),
    do: decision

  defp normalize_decision(
         {:prompt, prompt, _state} = decision,
         _name,
         _module,
         _callback,
         _old_state
       )
       when is_binary(prompt),
       do: decision

  defp normalize_decision(_decision, name, module, callback, old_state) do
    arity = if callback == :handle_event, do: 2, else: 3

    Logger.error(
      "GenAgent #{inspect(name)} #{inspect(module)}.#{callback}/#{arity} returned unexpected shape"
    )

    {:noreply, old_state}
  end

  # ---------------------------------------------------------------------------
  # Lifecycle hook wrappers. Each wraps a user callback in try/rescue/catch
  # per the semantics in design/005-lifecycle-hooks.md:
  #
  #   pre_run raise   -> {:crashed, ex}           (server stops)
  #   pre_turn raise  -> :skip                    (skip turn, back to idle)
  #   post_turn raise -> {:ok, state}             (log + continue transition)
  #   post_run raise  -> :ok                      (log + terminate normally)
  # ---------------------------------------------------------------------------

  defp safely_pre_run(name, module, state) do
    if function_exported?(module, :pre_run, 1) do
      try do
        module.pre_run(state)
      rescue
        e ->
          log_hook_failure(:error, name, module, "pre_run/1", :error, e, __STACKTRACE__)
          {:crashed, e}
      catch
        kind, reason ->
          log_hook_failure(:error, name, module, "pre_run/1", kind, reason, __STACKTRACE__)

          {:crashed, {kind, reason}}
      end
    else
      {:ok, state}
    end
  end

  defp safely_pre_turn(name, module, prompt, state) do
    if function_exported?(module, :pre_turn, 2) do
      try do
        {:returned, module.pre_turn(prompt, state)}
      rescue
        e ->
          log_hook_failure(:warning, name, module, "pre_turn/2", :error, e, __STACKTRACE__)

          {:crashed, callback_failure_kind(e)}
      catch
        kind, reason ->
          log_hook_failure(:warning, name, module, "pre_turn/2", kind, reason, __STACKTRACE__)

          {:crashed, callback_failure_kind(reason)}
      end
    else
      {:returned, {:ok, prompt, state}}
    end
  end

  defp safely_post_turn(name, module, outcome, ref, state) do
    if function_exported?(module, :post_turn, 3) do
      try do
        case module.post_turn(outcome, ref, state) do
          {:ok, new_state} ->
            {:ok, new_state}

          _other ->
            Logger.warning(
              "GenAgent #{inspect(name)} #{inspect(module)}.post_turn/3 returned unexpected shape"
            )

            {:ok, state}
        end
      rescue
        e ->
          log_hook_failure(:warning, name, module, "post_turn/3", :error, e, __STACKTRACE__)
          {:ok, state}
      catch
        kind, reason ->
          log_hook_failure(:warning, name, module, "post_turn/3", kind, reason, __STACKTRACE__)

          {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  defp safely_post_run(name, module, state) do
    if function_exported?(module, :post_run, 1) do
      try do
        module.post_run(state)
        :ok
      rescue
        e ->
          log_hook_failure(:warning, name, module, "post_run/1", :error, e, __STACKTRACE__)
          :ok
      catch
        kind, reason ->
          log_hook_failure(:warning, name, module, "post_run/1", kind, reason, __STACKTRACE__)

          :ok
      end
    else
      :ok
    end
  end

  defp log_hook_failure(level, name, module, callback, kind, reason, stacktrace) do
    failure =
      if kind == :error,
        do: "raised #{inspect(callback_failure_kind(reason))}",
        else: "threw #{kind}: #{inspect(callback_failure_kind(reason))}"

    Logger.log(
      level,
      "GenAgent #{inspect(name)} #{inspect(module)}.#{callback} #{failure}\n" <>
        redacted_stacktrace(stacktrace)
    )
  end

  # Centralized halt transition. Stop dispatch before draining, so nested
  # halt decisions cannot fire completion hooks partway through the batch.
  # All buffered notifications run before post_run and :halted observe the
  # final state. All clean-halt sites funnel through this one hook call site.
  defp transition_to_halted(%Data{halted: true} = data), do: data

  defp transition_to_halted(%Data{} = data) do
    # Release doomed tells before notification-generated prompts use capacity.
    data = fail_halt_aware_queued(%{data | halted: true})
    data = drain_pending_events(data)
    :ok = safely_post_run(data.name, data.agent_module, data.agent_state)
    emit_halted(data.name, data.agent_state)
    data
  end

  defp fail_halt_aware_queued(%Data{} = data) do
    {remaining, data} =
      Enum.reduce(:queue.to_list(data.mailbox), {[], data}, fn
        {ref, {:tell, recipient, :fail} = kind, prompt}, {remaining, data} ->
          emit_turn_rejected(data.name, ref, kind, :halted)
          send(recipient, {:gen_agent, :completion, data.name, ref, {:error, :halted}})

          data =
            data
            |> store_tell_result(ref, {:error, :halted})
            |> Map.update!(:stream_recipients, &Map.delete(&1, ref))
            |> Map.update!(:pending_prompt_bytes, &(&1 - :erlang.external_size(prompt)))

          {remaining, data}

        entry, {remaining, data} ->
          {[entry | remaining], data}
      end)

    %{data | mailbox: remaining |> Enum.reverse() |> :queue.from_list()}
  end

  # Drain pending_events synchronously (called from finish_turn /
  # finish_error before transitioning to :idle). Each buffered event
  # is processed against the current data.agent_state. Events that
  # return {:prompt, ..., state} enqueue the prompt to the mailbox so
  # it will be dispatched after the upcoming :idle transition. Events
  # that return {:halt, state} set halted: true but drain continues
  # (subsequent events still get their handle_event called so their
  # state mutations are not lost).
  defp drain_pending_events(%Data{} = data) do
    case :queue.out(data.pending_events) do
      {:empty, _} ->
        data

      {{:value, event}, rest} ->
        data = %{
          data
          | pending_events: rest,
            pending_notification_bytes:
              data.pending_notification_bytes - :erlang.external_size(event)
        }

        drain_pending_events(apply_pending_event(data, event))
    end
  end

  defp apply_pending_event(data, event) do
    case safely_handle_event(data.name, data.agent_module, event, data.agent_state) do
      {:noreply, new_state} ->
        %{data | agent_state: new_state}

      {:prompt, prompt, new_state} ->
        request_ref = make_ref()
        data = %{data | agent_state: new_state}

        case enqueue_prompt(data, request_ref, :event, prompt) do
          {:ok, queued} -> queued
          {:error, reason} -> reject_generated_prompt(data, request_ref, reason)
        end

      {:halt, new_state} ->
        transition_to_halted(%{data | agent_state: new_state})
    end
  end

  defp reject_generated_prompt(data, request_ref, reason) do
    emit_prompt_error(data.name, request_ref, reason, data.agent_state)

    case safely_handle_error(data.name, data.agent_module, request_ref, reason, data.agent_state) do
      {:noreply, new_state} ->
        %{data | agent_state: new_state}

      {:halt, new_state} ->
        transition_to_halted(%{data | agent_state: new_state})

      {:prompt, next_prompt, new_state} when is_binary(next_prompt) ->
        enqueue_error_recovery_prompt(%{data | agent_state: new_state}, next_prompt)
    end
  end

  defp enqueue_error_recovery_prompt(%Data{self_chain: nil} = data, prompt) do
    case enqueue_self_chain(data, prompt) do
      {:ok, queued} -> queued
      {:error, _reason} -> data
    end
  end

  defp enqueue_error_recovery_prompt(data, _prompt), do: data

  # ---------------------------------------------------------------------------
  # Turn outcome -> caller delivery
  # ---------------------------------------------------------------------------

  defp finish_turn(data, current, response, new_session, new_agent_state) do
    decision =
      data.agent_module.handle_response(current.request_ref, response, new_agent_state)

    # Apply decision state, then run post_turn against the post-decision
    # state. post_turn can mutate state but cannot override the transition
    # the decision callback chose.
    {transition, decision_state} = decision_to_transition(decision)

    {:ok, hooked_state} =
      safely_post_turn(
        data.name,
        data.agent_module,
        {:ok, response},
        current.request_ref,
        decision_state
      )

    {data, reply_actions} = record_success(data, current, response)

    data = %{
      data
      | backend_session: new_session,
        agent_state: hooked_state,
        current_request: nil
    }

    case transition do
      :noreply ->
        data = drain_pending_events(data)
        {:next_state, :idle, data, with_process_next(reply_actions)}

      {:prompt, next_prompt} ->
        data = drain_pending_events(accept_self_chain(data, next_prompt))
        {:next_state, :idle, data, with_process_next(reply_actions)}

      :halt ->
        data = transition_to_halted(data)
        {:next_state, :idle, data, with_process_next(reply_actions)}
    end
  end

  defp decision_to_transition({:noreply, state}), do: {:noreply, state}

  defp decision_to_transition({:prompt, prompt, state}) when is_binary(prompt),
    do: {{:prompt, prompt}, state}

  defp decision_to_transition({:halt, state}), do: {:halt, state}

  defp finish_error(data, current, reason) do
    duration_ms = max(System.monotonic_time(:millisecond) - current.started_at, 0)
    emit_prompt_error(data.name, current.request_ref, reason, data.agent_state, duration_ms)
    emit_turn_error(data.name, current, reason, duration_ms)

    decision =
      safely_handle_error(
        data.name,
        data.agent_module,
        current.request_ref,
        reason,
        data.agent_state
      )

    {transition, decision_state} = decision_to_transition(decision)

    {:ok, hooked_state} =
      safely_post_turn(
        data.name,
        data.agent_module,
        {:error, reason},
        current.request_ref,
        decision_state
      )

    {data, reply_actions} = record_error(data, current, reason)

    data = %{data | agent_state: hooked_state, current_request: nil}

    case transition do
      :noreply ->
        data = drain_pending_events(data)
        {:next_state, :idle, data, with_process_next(reply_actions)}

      {:prompt, next_prompt} ->
        data = drain_pending_events(accept_self_chain(data, next_prompt))
        {:next_state, :idle, data, with_process_next(reply_actions)}

      :halt ->
        data = transition_to_halted(data)
        {:next_state, :idle, data, with_process_next(reply_actions)}
    end
  end

  defp safely_handle_error(name, module, ref, reason, state) do
    if function_exported?(module, :handle_error, 3) do
      try do
        module.handle_error(ref, reason, state)
        |> normalize_decision(name, module, :handle_error, state)
      catch
        kind, failure ->
          Logger.error(
            "GenAgent #{inspect(name)} #{inspect(module)}.handle_error/3 failed " <>
              "(#{kind}: #{inspect(callback_failure_kind(failure))})\n" <>
              redacted_stacktrace(__STACKTRACE__)
          )

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  defp with_process_next(actions) do
    actions ++ [{:next_event, :internal, :process_next}]
  end

  defp record_success(%Data{} = data, %{kind: {:ask, from}}, response) do
    {data, [{:reply, from, {:ok, response}}]}
  end

  defp record_success(%Data{} = data, %{kind: :tell, request_ref: ref}, response) do
    {store_tell_result(data, ref, {:ok, response}), []}
  end

  defp record_success(%Data{} = data, %{kind: {:tell, recipient}, request_ref: ref}, response) do
    outcome = {:ok, response}
    send(recipient, {:gen_agent, :completion, data.name, ref, outcome})
    {store_tell_result(data, ref, outcome), []}
  end

  defp record_success(
         %Data{} = data,
         %{kind: {:tell, recipient, _on_halt}, request_ref: ref},
         response
       ) do
    outcome = {:ok, response}
    send(recipient, {:gen_agent, :completion, data.name, ref, outcome})
    {store_tell_result(data, ref, outcome), []}
  end

  defp record_success(%Data{} = data, %{kind: kind}, _response)
       when kind in [:self_chain, :event] do
    {data, []}
  end

  defp record_error(%Data{} = data, %{kind: {:ask, from}}, reason) do
    {data, [{:reply, from, {:error, reason}}]}
  end

  defp record_error(%Data{} = data, %{kind: :tell, request_ref: ref}, reason) do
    {store_tell_result(data, ref, {:error, reason}), []}
  end

  defp record_error(%Data{} = data, %{kind: {:tell, recipient}, request_ref: ref}, reason) do
    outcome = {:error, reason}
    send(recipient, {:gen_agent, :completion, data.name, ref, outcome})
    {store_tell_result(data, ref, outcome), []}
  end

  defp record_error(
         %Data{} = data,
         %{kind: {:tell, recipient, _on_halt}, request_ref: ref},
         reason
       ) do
    outcome = {:error, reason}
    send(recipient, {:gen_agent, :completion, data.name, ref, outcome})
    {store_tell_result(data, ref, outcome), []}
  end

  defp record_error(%Data{} = data, %{kind: kind}, _reason)
       when kind in [:self_chain, :event] do
    {data, []}
  end

  defp store_tell_result(%Data{} = data, ref, result) do
    previous = Map.get(data.tell_results, ref)
    previous_bytes = if previous, do: :erlang.external_size({ref, previous}), else: 0

    %{
      data
      | tell_results: Map.put(data.tell_results, ref, result),
        tell_result_order:
          if(previous, do: data.tell_result_order, else: :queue.in(ref, data.tell_result_order)),
        tell_result_bytes:
          data.tell_result_bytes + :erlang.external_size({ref, result}) - previous_bytes
    }
    |> prune_tell_results()
  end

  defp prune_tell_results(%Data{} = data) do
    if map_size(data.tell_results) > data.max_tell_results or
         data.tell_result_bytes > data.max_tell_result_bytes do
      {{:value, oldest}, order} = :queue.out(data.tell_result_order)
      result = Map.fetch!(data.tell_results, oldest)

      %{
        data
        | tell_results: Map.delete(data.tell_results, oldest),
          tell_result_order: order,
          tell_result_bytes: data.tell_result_bytes - :erlang.external_size({oldest, result})
      }
      |> prune_tell_results()
    else
      data
    end
  end

  defp in_mailbox?(mailbox, ref) do
    mailbox
    |> :queue.to_list()
    |> Enum.any?(fn {r, _kind, _prompt} -> r == ref end)
  end

  defp safely_call(name, module, fun, args) do
    if function_exported?(module, fun, length(args)) do
      try do
        apply(module, fun, args)
      catch
        kind, failure ->
          Logger.error(
            "GenAgent #{inspect(name)} #{inspect(module)}.#{fun}/#{length(args)} failed " <>
              "(#{kind}: #{inspect(callback_failure_kind(failure))})\n" <>
              redacted_stacktrace(__STACKTRACE__)
          )

          :ok
      end
    else
      :ok
    end
  end

  defp redacted_stacktrace(stacktrace) do
    stacktrace
    |> Enum.map(fn
      {module, function, args, info} when is_list(args) ->
        {module, function, length(args), info}

      frame ->
        frame
    end)
    |> Exception.format_stacktrace()
  end

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  defp emit_prompt_start(name, ref, prompt, original_prompt, agent_state) do
    rewritten = not is_nil(original_prompt) and original_prompt != prompt

    :telemetry.execute([:gen_agent, :prompt, :start], %{system_time: System.system_time()}, %{
      agent: name,
      ref: ref,
      prompt: prompt,
      original_prompt: original_prompt || prompt,
      rewritten: rewritten,
      agent_state: agent_state
    })
  end

  defp emit_prompt_stop(name, ref, duration_ms, agent_state) do
    :telemetry.execute([:gen_agent, :prompt, :stop], %{duration: duration_ms}, %{
      agent: name,
      ref: ref,
      agent_state: agent_state
    })
  end

  defp emit_prompt_error(name, ref, reason, agent_state, duration_ms \\ nil) do
    measurements = %{system_time: System.system_time()}

    measurements =
      if duration_ms, do: Map.put(measurements, :duration, duration_ms), else: measurements

    :telemetry.execute([:gen_agent, :prompt, :error], measurements, %{
      agent: name,
      ref: ref,
      reason: reason,
      agent_state: agent_state
    })
  end

  defp emit_turn_start(name, ref, kind) do
    :telemetry.execute([:gen_agent, :turn, :start], %{system_time: System.system_time()}, %{
      agent: name,
      ref: ref,
      origin: request_origin(kind)
    })
  end

  defp emit_turn_stop(name, current) do
    duration_ms = max(System.monotonic_time(:millisecond) - current.started_at, 0)

    :telemetry.execute([:gen_agent, :turn, :stop], %{duration_ms: duration_ms}, %{
      agent: name,
      ref: current.request_ref,
      origin: request_origin(current.kind)
    })
  end

  defp emit_turn_error(name, current, reason, duration_ms) do
    :telemetry.execute([:gen_agent, :turn, :error], %{duration_ms: duration_ms}, %{
      agent: name,
      ref: current.request_ref,
      origin: request_origin(current.kind),
      reason_kind: turn_error_kind(reason)
    })
  end

  defp emit_turn_rejected(name, ref, kind, reason_kind) do
    :telemetry.execute([:gen_agent, :turn, :rejected], %{system_time: System.system_time()}, %{
      agent: name,
      ref: ref,
      origin: request_origin(kind),
      reason_kind: reason_kind
    })
  end

  defp emit_turn_cancelled(name, ref, kind, reason_kind) do
    :telemetry.execute([:gen_agent, :turn, :cancelled], %{system_time: System.system_time()}, %{
      agent: name,
      ref: ref,
      origin: request_origin(kind),
      reason_kind: reason_kind
    })
  end

  defp turn_error_kind(:timeout), do: :timeout
  defp turn_error_kind(:interrupted), do: :interrupted
  defp turn_error_kind({:task_crashed, _}), do: :task_crashed
  defp turn_error_kind(_), do: :backend_or_callback_error

  defp emit_event_received(name, event) do
    :telemetry.execute([:gen_agent, :event, :received], %{system_time: System.system_time()}, %{
      agent: name,
      event: event
    })
  end

  defp emit_state_change(name, from, to) do
    :telemetry.execute([:gen_agent, :state, :changed], %{system_time: System.system_time()}, %{
      agent: name,
      from: from,
      to: to
    })
  end

  defp emit_mailbox_queued(name, depth) do
    :telemetry.execute([:gen_agent, :mailbox, :queued], %{depth: depth}, %{agent: name})
  end

  defp emit_input_rejected(name, reason) do
    :telemetry.execute(
      [:gen_agent, :input, :rejected],
      %{system_time: System.system_time()},
      %{agent: name, reason: reason}
    )
  end

  defp emit_halted(name, agent_state) do
    :telemetry.execute([:gen_agent, :halted], %{system_time: System.system_time()}, %{
      agent: name,
      agent_state: agent_state
    })
  end
end
