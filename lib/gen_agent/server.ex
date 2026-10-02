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

  @default_watchdog_ms :timer.minutes(10)
  @default_max_tell_results 100
  @default_max_events_per_turn 1_000
  @default_max_event_bytes_per_turn 1_048_576
  @default_max_pending_prompts 1_000
  @default_max_pending_prompt_bytes 1_048_576
  @default_max_pending_notifications 1_000
  @default_max_pending_notification_bytes 1_048_576

  defmodule Data do
    @moduledoc false

    defstruct [
      :name,
      :backend,
      :backend_session,
      :task_supervisor,
      :agent_module,
      :agent_state,
      :current_request,
      :watchdog_ms,
      :max_tell_results,
      :max_events_per_turn,
      :max_event_bytes_per_turn,
      :max_pending_prompts,
      :max_pending_prompt_bytes,
      :max_pending_notifications,
      :max_pending_notification_bytes,
      halted: false,
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
      tell_result_order: :queue.new()
    ]
  end

  # ---------------------------------------------------------------------------
  # Startup
  # ---------------------------------------------------------------------------

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      # :temporary means the DynamicSupervisor does not auto-restart a dead
      # agent. This is the safer default for a framework where agents carry
      # conversation state (backend session id, message history, summary)
      # that cannot be rebuilt without persistence -- an auto-restart would
      # silently lose everything. Users who kill or crash an agent should
      # explicitly call `start_agent/2` again to get a fresh one.
      restart: :temporary,
      shutdown: 5_000,
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
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    init_opts = Keyword.get(opts, :init_opts, [])
    watchdog_ms = Keyword.get(opts, :watchdog_ms, @default_watchdog_ms)
    max_tell_results = Keyword.get(opts, :max_tell_results, @default_max_tell_results)
    max_events_per_turn = Keyword.get(opts, :max_events_per_turn, @default_max_events_per_turn)

    max_event_bytes_per_turn =
      Keyword.get(opts, :max_event_bytes_per_turn, @default_max_event_bytes_per_turn)

    max_pending_prompts = Keyword.get(opts, :max_pending_prompts, @default_max_pending_prompts)

    max_pending_prompt_bytes =
      Keyword.get(opts, :max_pending_prompt_bytes, @default_max_pending_prompt_bytes)

    max_pending_notifications =
      Keyword.get(opts, :max_pending_notifications, @default_max_pending_notifications)

    max_pending_notification_bytes =
      Keyword.get(opts, :max_pending_notification_bytes, @default_max_pending_notification_bytes)

    validate_capture_limit!(max_events_per_turn, :max_events_per_turn)
    validate_capture_limit!(max_event_bytes_per_turn, :max_event_bytes_per_turn)
    validate_pending_limit!(max_pending_prompts, :max_pending_prompts)
    validate_pending_limit!(max_pending_prompt_bytes, :max_pending_prompt_bytes)
    validate_pending_limit!(max_pending_notifications, :max_pending_notifications)
    validate_pending_limit!(max_pending_notification_bytes, :max_pending_notification_bytes)

    with {:ok, backend_opts, agent_state} <- module.init_agent(init_opts),
         {:ok, backend_session} <- backend.start_session(backend_opts) do
      data = %Data{
        name: name,
        backend: backend,
        backend_session: backend_session,
        task_supervisor: task_supervisor,
        agent_module: module,
        agent_state: agent_state,
        watchdog_ms: watchdog_ms,
        max_tell_results: max_tell_results,
        max_events_per_turn: max_events_per_turn,
        max_event_bytes_per_turn: max_event_bytes_per_turn,
        max_pending_prompts: max_pending_prompts,
        max_pending_prompt_bytes: max_pending_prompt_bytes,
        max_pending_notifications: max_pending_notifications,
        max_pending_notification_bytes: max_pending_notification_bytes
      }

      emit_state_change(name, nil, :idle)
      {:ok, :idle, data, [{:next_event, :internal, :pre_run}]}
    else
      {:error, reason} -> {:stop, {:backend_start_failed, reason}}
      other -> {:stop, {:init_agent_failed, other}}
    end
  end

  @impl :gen_statem
  def terminate(reason, _state, %Data{} = data) do
    if data.current_request do
      cleanup_task(data.current_request)
    end

    safely_call(data.agent_module, :terminate_agent, [reason, data.agent_state])
    safely_call(data.backend, :terminate_session, [data.backend_session])
    :ok
  end

  def terminate(_reason, _state, _data), do: :ok

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
  def handle_event(:enter, old_state, :idle, %Data{} = data) do
    if old_state != :idle do
      emit_state_change(data.name, old_state, :idle)
    end

    :keep_state_and_data
  end

  def handle_event(:enter, old_state, :processing, %Data{} = data) do
    emit_state_change(data.name, old_state, :processing)
    {:keep_state_and_data, [{:state_timeout, data.watchdog_ms, :watchdog}]}
  end

  # ---------------------------------------------------------------------------
  # Internal: :pre_run -- one-time setup hook, fires after init, before
  # any user-visible turn. See `c:GenAgent.pre_run/1`.
  # ---------------------------------------------------------------------------

  def handle_event(:internal, :pre_run, :idle, %Data{pre_run_done: true}) do
    :keep_state_and_data
  end

  def handle_event(:internal, :pre_run, :idle, %Data{} = data) do
    case safely_pre_run(data.agent_module, data.agent_state) do
      {:ok, new_agent_state} ->
        {:keep_state, %{data | agent_state: new_agent_state, pre_run_done: true}}

      {:error, reason} ->
        {:stop, {:pre_run_failed, reason}, data}

      {:crashed, exception} ->
        {:stop, {:pre_run_crashed, exception}, data}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: :process_next -- decide what to do on entry to :idle
  # ---------------------------------------------------------------------------

  def handle_event(:internal, :process_next, :idle, %Data{halted: true}) do
    :keep_state_and_data
  end

  def handle_event(:internal, :process_next, :idle, %Data{self_chain: prompt} = data)
      when is_binary(prompt) do
    data = %{data | self_chain: nil}
    request_ref = make_ref()
    try_dispatch(data, request_ref, :self_chain, prompt)
  end

  def handle_event(:internal, :process_next, :idle, %Data{} = data) do
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

  # ---------------------------------------------------------------------------
  # ask -- synchronous prompt
  # ---------------------------------------------------------------------------

  def handle_event({:call, from}, {:ask, prompt}, :idle, %Data{halted: false} = data) do
    request_ref = make_ref()
    try_dispatch(data, request_ref, {:ask, from}, prompt)
  end

  def handle_event({:call, from}, {:ask, prompt}, :idle, %Data{halted: true} = data) do
    queue_ask(data, from, prompt)
  end

  def handle_event({:call, from}, {:ask, prompt}, :processing, %Data{} = data) do
    queue_ask(data, from, prompt)
  end

  # ---------------------------------------------------------------------------
  # tell -- async prompt, reply with ref immediately
  # ---------------------------------------------------------------------------

  def handle_event({:call, from}, {:tell, prompt}, :idle, %Data{halted: false} = data) do
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

  def handle_event({:call, from}, {:tell, prompt}, :idle, %Data{halted: true} = data) do
    queue_tell(data, from, prompt)
  end

  def handle_event({:call, from}, {:tell, prompt}, :processing, %Data{} = data) do
    queue_tell(data, from, prompt)
  end

  def handle_event(
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

  def handle_event(
        {:call, from},
        {:tell_with_completion, prompt, recipient},
        state,
        %Data{} = data
      )
      when state in [:idle, :processing] do
    queue_tell(data, from, prompt, recipient)
  end

  # poll -- check status of a previously-tell'd request
  # ---------------------------------------------------------------------------

  def handle_event({:call, from}, {:poll, ref}, _state, %Data{} = data) do
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

  def handle_event({:call, from}, :get_backend_session, _state, %Data{} = data) do
    {:keep_state_and_data, [{:reply, from, data.backend_session}]}
  end

  def handle_event({:call, from}, :status, state, %Data{} = data) do
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
      agent_state: data.agent_state
    }

    {:keep_state_and_data, [{:reply, from, status}]}
  end

  def handle_event({:call, from}, :runtime_snapshot, state, %Data{} = data) do
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

  def handle_event(:cast, {:notify, event}, :processing, %Data{} = data),
    do: notify_processing(data, event, nil)

  def handle_event({:call, from}, {:notify_ack, event}, :processing, %Data{} = data),
    do: notify_processing(data, event, from)

  def handle_event(:cast, {:notify, event}, :idle, %Data{} = data),
    do: notify_idle(data, event, nil)

  def handle_event({:call, from}, {:notify_ack, event}, :idle, %Data{} = data),
    do: notify_idle(data, event, from)

  # interrupt -- kill current task, deliver :interrupted
  # ---------------------------------------------------------------------------

  def handle_event(:cast, :interrupt, :processing, %Data{current_request: current} = data)
      when not is_nil(current) do
    cleanup_task(current)
    finish_error(data, current, :interrupted)
  end

  def handle_event(:cast, :interrupt, _state, _data), do: :keep_state_and_data

  def handle_event(
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

  def handle_event({:call, from}, {:interrupt_request, _ref}, :processing, %Data{} = data) do
    {:keep_state, data, [{:reply, from, {:error, :not_current}}]}
  end

  def handle_event({:call, from}, {:interrupt_request, _ref}, _state, %Data{} = data) do
    {:keep_state, data, [{:reply, from, {:error, :idle}}]}
  end

  # ---------------------------------------------------------------------------
  # cancel_request -- remove only a queued tell with the exact ref
  # ---------------------------------------------------------------------------

  def handle_event({:call, from}, {:cancel_request, ref}, _state, %Data{} = data) do
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

  def handle_event(:cast, :resume, :idle, %Data{halted: true} = data) do
    data = %{data | halted: false}
    {:keep_state, data, [{:next_event, :internal, :process_next}]}
  end

  def handle_event(:cast, :resume, _state, _data), do: :keep_state_and_data

  # ---------------------------------------------------------------------------
  # Watchdog timeout
  # ---------------------------------------------------------------------------

  def handle_event(:state_timeout, :watchdog, :processing, %Data{current_request: current} = data) do
    cleanup_task(current)
    finish_error(data, current, :timeout)
  end

  # ---------------------------------------------------------------------------
  # Task completion messages
  # ---------------------------------------------------------------------------

  def handle_event(:info, {ref, task_result}, :processing, %Data{current_request: current} = data)
      when is_reference(ref) and is_map(current) do
    case current do
      %{task_ref: ^ref} ->
        Process.demonitor(ref, [:flush])
        handle_task_result(task_result, current, data)

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:DOWN, mon, :process, _pid, _reason}, _state, %Data{} = data)
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

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        :processing,
        %Data{current_request: current} = data
      )
      when is_reference(ref) and is_map(current) do
    case current do
      %{task_ref: ^ref} ->
        finish_error(data, current, {:task_crashed, reason})

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data

  defp request_origin({:ask, _from}), do: :ask
  defp request_origin({:tell, _recipient}), do: :tell
  defp request_origin(kind) when kind in [:tell, :event, :self_chain], do: kind

  defp handle_task_result({:ok, response, new_session, new_agent_state}, current, data) do
    emit_prompt_stop(data.name, current.request_ref, response.duration_ms, new_agent_state)
    emit_turn_stop(data.name, current)
    finish_turn(data, current, response, new_session, new_agent_state)
  end

  defp handle_task_result({:error, reason, new_session, new_agent_state}, current, data) do
    data = %{data | backend_session: new_session, agent_state: new_agent_state}
    finish_error(data, current, reason)
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

      _ ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_found}}]}
    end
  end

  defp current_tell_ref?(%{request_ref: ref, kind: :tell}, ref), do: true
  defp current_tell_ref?(%{request_ref: ref, kind: {:tell, _recipient}}, ref), do: true
  defp current_tell_ref?(_current, _ref), do: false

  defp finish_queued_tell_cancel(data, from, ref, kind, prompt) do
    data = remove_queued_entry(data, ref, prompt)
    data = store_tell_result(data, ref, {:error, :cancelled})

    if match?({:tell, _}, kind) do
      {:tell, recipient} = kind
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

  defp queue_tell(data, from, prompt, recipient \\ nil) do
    request_ref = make_ref()
    kind = if is_nil(recipient), do: :tell, else: {:tell, recipient}

    case enqueue_prompt(data, request_ref, kind, prompt) do
      {:ok, queued} ->
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
      case safely_handle_event(data.agent_module, event, data.agent_state) do
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
  #   {:skip, state}       -- drop the prompt, deliver :pre_turn_skipped
  #                           via record_error (so ask/tell callers see
  #                           an error, self_chain/event paths no-op),
  #                           stay in :idle.
  #   {:halt, state}       -- same as skip, plus transition_to_halted.
  #
  # Returns a gen_statem handle_event result tuple.
  defp try_dispatch(%Data{} = data, request_ref, kind, prompt) do
    case safely_pre_turn(data.agent_module, prompt, data.agent_state) do
      {:ok, new_prompt, new_state} when is_binary(new_prompt) ->
        data = %{data | agent_state: new_state}
        data = dispatch(data, request_ref, kind, new_prompt, prompt)
        {:next_state, :processing, data}

      {:skip, new_state} ->
        pseudo_current = %{request_ref: request_ref, kind: kind}
        data = %{data | agent_state: new_state}
        emit_turn_rejected(data.name, request_ref, kind, :pre_turn_skipped)
        {data, reply_actions} = record_error(data, pseudo_current, :pre_turn_skipped)
        {:keep_state, data, with_process_next(reply_actions)}

      {:halt, new_state} ->
        pseudo_current = %{request_ref: request_ref, kind: kind}
        data = %{data | agent_state: new_state}
        emit_turn_rejected(data.name, request_ref, kind, :pre_turn_halted)
        {data, reply_actions} = record_error(data, pseudo_current, :pre_turn_halted)
        data = transition_to_halted(data)
        {:keep_state, data, with_process_next(reply_actions)}

      other ->
        # Malformed pre_turn return -- treat as skip with a warning.
        require Logger
        Logger.error("GenAgent pre_turn/2 returned unexpected shape: #{inspect(other)}")
        pseudo_current = %{request_ref: request_ref, kind: kind}
        emit_turn_rejected(data.name, request_ref, kind, :pre_turn_invalid)
        {data, reply_actions} = record_error(data, pseudo_current, :pre_turn_invalid)
        {:keep_state, data, with_process_next(reply_actions)}
    end
  end

  defp dispatch(%Data{} = data, request_ref, kind, prompt, original_prompt) do
    backend = data.backend
    backend_session = data.backend_session
    module = data.agent_module
    agent_state = data.agent_state
    task_supervisor = data.task_supervisor
    max_events_per_turn = data.max_events_per_turn
    max_event_bytes_per_turn = data.max_event_bytes_per_turn

    # Link the task to its owning agent as well as the shared supervisor.
    # Even an untrappable agent exit must take its in-flight turn down.
    # The agent traps exits, so task failures still flow through :DOWN
    # and handle_error/3 without crashing the agent or other agents.
    task =
      Task.Supervisor.async(task_supervisor, fn ->
        run_prompt(
          backend,
          backend_session,
          module,
          agent_state,
          prompt,
          max_events_per_turn,
          max_event_bytes_per_turn
        )
      end)

    started_at = System.monotonic_time(:millisecond)
    emit_prompt_start(data.name, request_ref, prompt, original_prompt, agent_state)
    emit_turn_start(data.name, request_ref, kind)

    current = %{
      request_ref: request_ref,
      task_ref: task.ref,
      task_pid: task.pid,
      kind: kind,
      prompt: prompt,
      started_at: started_at
    }

    %{data | current_request: current}
  end

  defp run_prompt(
         backend,
         backend_session,
         module,
         agent_state,
         prompt,
         max_events_per_turn,
         max_event_bytes_per_turn
       ) do
    started = System.monotonic_time(:millisecond)

    case backend.prompt(backend_session, prompt) do
      {:ok, stream, backend_session} ->
        consume_stream(
          stream,
          backend,
          backend_session,
          module,
          agent_state,
          started,
          max_events_per_turn,
          max_event_bytes_per_turn
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
         max_events,
         max_bytes
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

  defp validate_pending_limit!(value, _name) when is_integer(value) and value >= 0, do: :ok

  defp validate_pending_limit!(value, name) do
    raise ArgumentError, "#{name} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp maybe_handle_stream_event(module, event, state) do
    if function_exported?(module, :handle_stream_event, 2) do
      module.handle_stream_event(event, state)
    else
      state
    end
  end

  defp maybe_update_session(backend, session, data) do
    if function_exported?(backend, :update_session, 2) do
      backend.update_session(session, data)
    else
      session
    end
  end

  defp cleanup_task(%{task_pid: pid, task_ref: ref}) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp safely_handle_event(module, event, state) do
    if function_exported?(module, :handle_event, 2) do
      module.handle_event(event, state)
    else
      {:noreply, state}
    end
  rescue
    e ->
      require Logger
      Logger.error("GenAgent handle_event/2 raised: #{Exception.message(e)}")
      {:noreply, state}
  catch
    kind, reason ->
      require Logger
      Logger.error("GenAgent handle_event/2 threw #{kind}: #{inspect(reason)}")
      {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Lifecycle hook wrappers. Each wraps a user callback in try/rescue/catch
  # per the semantics in design/001-lifecycle-hooks.md:
  #
  #   pre_run raise   -> {:crashed, ex}           (server stops)
  #   pre_turn raise  -> :skip                    (skip turn, back to idle)
  #   post_turn raise -> {:ok, state}             (log + continue transition)
  #   post_run raise  -> :ok                      (log + terminate normally)
  # ---------------------------------------------------------------------------

  defp safely_pre_run(module, state) do
    if function_exported?(module, :pre_run, 1) do
      try do
        module.pre_run(state)
      rescue
        e ->
          require Logger
          Logger.error("GenAgent pre_run/1 raised: #{Exception.message(e)}")
          {:crashed, e}
      catch
        kind, reason ->
          require Logger
          Logger.error("GenAgent pre_run/1 threw #{kind}: #{inspect(reason)}")
          {:crashed, {kind, reason}}
      end
    else
      {:ok, state}
    end
  end

  defp safely_pre_turn(module, prompt, state) do
    if function_exported?(module, :pre_turn, 2) do
      try do
        module.pre_turn(prompt, state)
      rescue
        e ->
          require Logger
          Logger.error("GenAgent pre_turn/2 raised: #{Exception.message(e)} -- skipping turn")
          {:skip, state}
      catch
        kind, reason ->
          require Logger

          Logger.error("GenAgent pre_turn/2 threw #{kind}: #{inspect(reason)} -- skipping turn")

          {:skip, state}
      end
    else
      {:ok, prompt, state}
    end
  end

  defp safely_post_turn(module, outcome, ref, state) do
    if function_exported?(module, :post_turn, 3) do
      try do
        case module.post_turn(outcome, ref, state) do
          {:ok, new_state} -> {:ok, new_state}
          _other -> {:ok, state}
        end
      rescue
        e ->
          require Logger
          Logger.error("GenAgent post_turn/3 raised: #{Exception.message(e)}")
          {:ok, state}
      catch
        kind, reason ->
          require Logger
          Logger.error("GenAgent post_turn/3 threw #{kind}: #{inspect(reason)}")
          {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  defp safely_post_run(module, state) do
    if function_exported?(module, :post_run, 1) do
      try do
        module.post_run(state)
        :ok
      rescue
        e ->
          require Logger
          Logger.error("GenAgent post_run/1 raised: #{Exception.message(e)}")
          :ok
      catch
        kind, reason ->
          require Logger
          Logger.error("GenAgent post_run/1 threw #{kind}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  # Centralized halt transition. Fires post_run hook with the final
  # state, then emits the :halted telemetry event, then returns data
  # with halted: true. All clean-halt sites funnel through here so
  # post_run has exactly one call site.
  defp transition_to_halted(%Data{halted: true} = data), do: data

  defp transition_to_halted(%Data{} = data) do
    :ok = safely_post_run(data.agent_module, data.agent_state)
    emit_halted(data.name, data.agent_state)
    %{data | halted: true}
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
    case safely_handle_event(data.agent_module, event, data.agent_state) do
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

    case safely_handle_error(data.agent_module, request_ref, reason, data.agent_state) do
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
        data = drain_pending_events(data)
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
        data.agent_module,
        current.request_ref,
        reason,
        data.agent_state
      )

    {transition, decision_state} = decision_to_transition(decision)

    {:ok, hooked_state} =
      safely_post_turn(
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
        data = drain_pending_events(data)
        {:next_state, :idle, data, with_process_next(reply_actions)}
    end
  end

  defp safely_handle_error(module, ref, reason, state) do
    if function_exported?(module, :handle_error, 3) do
      try do
        module.handle_error(ref, reason, state)
      catch
        _, _ -> {:noreply, state}
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

  defp record_error(%Data{} = data, %{kind: kind}, _reason)
       when kind in [:self_chain, :event] do
    {data, []}
  end

  defp store_tell_result(%Data{} = data, ref, result) do
    tell_results = Map.put(data.tell_results, ref, result)
    order = :queue.in(ref, data.tell_result_order)

    if map_size(tell_results) > data.max_tell_results do
      {{:value, oldest}, order} = :queue.out(order)
      tell_results = Map.delete(tell_results, oldest)
      %{data | tell_results: tell_results, tell_result_order: order}
    else
      %{data | tell_results: tell_results, tell_result_order: order}
    end
  end

  defp in_mailbox?(mailbox, ref) do
    mailbox
    |> :queue.to_list()
    |> Enum.any?(fn {r, _kind, _prompt} -> r == ref end)
  end

  defp safely_call(module, fun, args) do
    if function_exported?(module, fun, length(args)) do
      try do
        apply(module, fun, args)
      catch
        _, _ -> :ok
      end
    else
      :ok
    end
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
