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
      halted: false,
      self_chain: nil,
      mailbox: :queue.new(),
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
        max_tell_results: max_tell_results
      }

      emit_state_change(name, nil, :idle)
      {:ok, :idle, data}
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

  @impl :gen_statem
  def terminate(_reason, _state, _data), do: :ok

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
  # Internal: :process_next -- decide what to do on entry to :idle
  # ---------------------------------------------------------------------------

  def handle_event(:internal, :process_next, :idle, %Data{halted: true}) do
    :keep_state_and_data
  end

  def handle_event(:internal, :process_next, :idle, %Data{self_chain: prompt} = data)
      when is_binary(prompt) do
    data = %{data | self_chain: nil}
    request_ref = make_ref()
    data = dispatch(data, request_ref, :self_chain, prompt)
    {:next_state, :processing, data}
  end

  def handle_event(:internal, :process_next, :idle, %Data{} = data) do
    case :queue.out(data.mailbox) do
      {:empty, _} ->
        :keep_state_and_data

      {{:value, {request_ref, kind, prompt}}, mailbox} ->
        data = %{data | mailbox: mailbox}
        data = dispatch(data, request_ref, kind, prompt)
        {:next_state, :processing, data}
    end
  end

  # ---------------------------------------------------------------------------
  # ask -- synchronous prompt
  # ---------------------------------------------------------------------------

  def handle_event({:call, from}, {:ask, prompt}, :idle, %Data{halted: false} = data) do
    request_ref = make_ref()
    data = dispatch(data, request_ref, {:ask, from}, prompt)
    {:next_state, :processing, data}
  end

  def handle_event({:call, from}, {:ask, prompt}, :idle, %Data{halted: true} = data) do
    request_ref = make_ref()
    mailbox = :queue.in({request_ref, {:ask, from}, prompt}, data.mailbox)
    emit_mailbox_queued(data.name, :queue.len(mailbox))
    {:keep_state, %{data | mailbox: mailbox}}
  end

  def handle_event({:call, from}, {:ask, prompt}, :processing, %Data{} = data) do
    request_ref = make_ref()
    mailbox = :queue.in({request_ref, {:ask, from}, prompt}, data.mailbox)
    emit_mailbox_queued(data.name, :queue.len(mailbox))
    {:keep_state, %{data | mailbox: mailbox}}
  end

  # ---------------------------------------------------------------------------
  # tell -- async prompt, reply with ref immediately
  # ---------------------------------------------------------------------------

  def handle_event({:call, from}, {:tell, prompt}, :idle, %Data{halted: false} = data) do
    request_ref = make_ref()
    data = dispatch(data, request_ref, :tell, prompt)
    {:next_state, :processing, data, [{:reply, from, {:ok, request_ref}}]}
  end

  def handle_event({:call, from}, {:tell, prompt}, :idle, %Data{halted: true} = data) do
    request_ref = make_ref()
    mailbox = :queue.in({request_ref, :tell, prompt}, data.mailbox)
    emit_mailbox_queued(data.name, :queue.len(mailbox))
    {:keep_state, %{data | mailbox: mailbox}, [{:reply, from, {:ok, request_ref}}]}
  end

  def handle_event({:call, from}, {:tell, prompt}, :processing, %Data{} = data) do
    request_ref = make_ref()
    mailbox = :queue.in({request_ref, :tell, prompt}, data.mailbox)
    emit_mailbox_queued(data.name, :queue.len(mailbox))
    {:keep_state, %{data | mailbox: mailbox}, [{:reply, from, {:ok, request_ref}}]}
  end

  # ---------------------------------------------------------------------------
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

  # ---------------------------------------------------------------------------
  # notify -- external event dispatched to handle_event/2
  # ---------------------------------------------------------------------------

  def handle_event(:cast, {:notify, event}, state, %Data{} = data) do
    emit_event_received(data.name, event)

    case data.agent_module.handle_event(event, data.agent_state) do
      {:noreply, new_agent_state} ->
        {:keep_state, %{data | agent_state: new_agent_state}}

      {:prompt, prompt, new_agent_state} ->
        data = %{data | agent_state: new_agent_state}
        request_ref = make_ref()

        if state == :idle and not data.halted do
          data = dispatch(data, request_ref, :event, prompt)
          {:next_state, :processing, data}
        else
          mailbox = :queue.in({request_ref, :event, prompt}, data.mailbox)
          emit_mailbox_queued(data.name, :queue.len(mailbox))
          {:keep_state, %{data | mailbox: mailbox}}
        end

      {:halt, new_agent_state} ->
        data = %{data | agent_state: new_agent_state, halted: true}
        emit_halted(data.name)
        {:keep_state, data}
    end
  end

  # ---------------------------------------------------------------------------
  # interrupt -- kill current task, deliver :interrupted
  # ---------------------------------------------------------------------------

  def handle_event(:cast, :interrupt, :processing, %Data{current_request: current} = data)
      when not is_nil(current) do
    cleanup_task(current)
    finish_error(data, current, :interrupted)
  end

  def handle_event(:cast, :interrupt, _state, _data), do: :keep_state_and_data

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
    emit_prompt_error(data.name, current.request_ref, :timeout)
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

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        :processing,
        %Data{current_request: current} = data
      )
      when is_reference(ref) and reason != :normal and is_map(current) do
    case current do
      %{task_ref: ^ref} ->
        emit_prompt_error(data.name, current.request_ref, {:task_crashed, reason})
        finish_error(data, current, {:task_crashed, reason})

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data

  defp handle_task_result({:ok, response, new_session, new_agent_state}, current, data) do
    emit_prompt_stop(data.name, current.request_ref, response.duration_ms)
    finish_turn(data, current, response, new_session, new_agent_state)
  end

  defp handle_task_result({:error, reason, new_session}, current, data) do
    emit_prompt_error(data.name, current.request_ref, reason)
    data = %{data | backend_session: new_session}
    finish_error(data, current, reason)
  end

  # ---------------------------------------------------------------------------
  # Dispatch + task plumbing
  # ---------------------------------------------------------------------------

  defp dispatch(%Data{} = data, request_ref, kind, prompt) do
    backend = data.backend
    backend_session = data.backend_session
    module = data.agent_module
    agent_state = data.agent_state
    task_supervisor = data.task_supervisor

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        run_prompt(backend, backend_session, module, agent_state, prompt)
      end)

    emit_prompt_start(data.name, request_ref)

    current = %{
      request_ref: request_ref,
      task_ref: task.ref,
      task_pid: task.pid,
      kind: kind,
      prompt: prompt,
      started_at: System.monotonic_time(:millisecond)
    }

    %{data | current_request: current}
  end

  defp run_prompt(backend, backend_session, module, agent_state, prompt) do
    started = System.monotonic_time(:millisecond)

    case backend.prompt(backend_session, prompt) do
      {:ok, stream, backend_session} ->
        consume_stream(stream, backend, backend_session, module, agent_state, started)

      {:error, reason} ->
        {:error, reason, backend_session}
    end
  end

  defp consume_stream(stream, backend, backend_session, module, agent_state, started) do
    initial = {[], agent_state, nil}

    {reversed_events, agent_state, terminal} =
      Enum.reduce_while(stream, initial, fn %Event{} = event, {events, state, _terminal} ->
        state = module.handle_stream_event(event, state)
        events = [event | events]

        if Event.terminal?(event) do
          {:halt, {events, state, event}}
        else
          {:cont, {events, state, nil}}
        end
      end)

    events = Enum.reverse(reversed_events)
    duration_ms = System.monotonic_time(:millisecond) - started

    case terminal do
      nil ->
        {:error, :no_terminal_event, backend_session}

      %Event{kind: :error, data: data} ->
        {:error, Map.get(data, :reason, :unknown), backend_session}

      %Event{kind: :result, data: data} ->
        backend_session = maybe_update_session(backend, backend_session, data)

        response =
          Response.from_events(events,
            duration_ms: duration_ms,
            session_id: Map.get(data, :session_id)
          )

        {:ok, response, backend_session, agent_state}
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

  # ---------------------------------------------------------------------------
  # Turn outcome -> caller delivery
  # ---------------------------------------------------------------------------

  defp finish_turn(data, current, response, new_session, new_agent_state) do
    {data, reply_actions} = record_success(data, current, response)

    case data.agent_module.handle_response(current.request_ref, response, new_agent_state) do
      {:noreply, final_state} ->
        data = %{
          data
          | backend_session: new_session,
            agent_state: final_state,
            current_request: nil
        }

        {:next_state, :idle, data, with_process_next(reply_actions)}

      {:prompt, next_prompt, final_state} when is_binary(next_prompt) ->
        data = %{
          data
          | backend_session: new_session,
            agent_state: final_state,
            current_request: nil,
            self_chain: next_prompt
        }

        {:next_state, :idle, data, with_process_next(reply_actions)}

      {:halt, final_state} ->
        data = %{
          data
          | backend_session: new_session,
            agent_state: final_state,
            current_request: nil,
            halted: true
        }

        emit_halted(data.name)
        {:next_state, :idle, data, with_process_next(reply_actions)}
    end
  end

  defp finish_error(data, current, reason) do
    {data, reply_actions} = record_error(data, current, reason)

    case safely_handle_error(
           data.agent_module,
           current.request_ref,
           reason,
           data.agent_state
         ) do
      {:noreply, final_state} ->
        data = %{data | agent_state: final_state, current_request: nil}
        {:next_state, :idle, data, with_process_next(reply_actions)}

      {:prompt, next_prompt, final_state} when is_binary(next_prompt) ->
        data = %{
          data
          | agent_state: final_state,
            current_request: nil,
            self_chain: next_prompt
        }

        {:next_state, :idle, data, with_process_next(reply_actions)}

      {:halt, final_state} ->
        data = %{
          data
          | agent_state: final_state,
            current_request: nil,
            halted: true
        }

        emit_halted(data.name)
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

  defp emit_prompt_start(name, ref) do
    :telemetry.execute([:gen_agent, :prompt, :start], %{system_time: System.system_time()}, %{
      agent: name,
      ref: ref
    })
  end

  defp emit_prompt_stop(name, ref, duration_ms) do
    :telemetry.execute([:gen_agent, :prompt, :stop], %{duration: duration_ms}, %{
      agent: name,
      ref: ref
    })
  end

  defp emit_prompt_error(name, ref, reason) do
    :telemetry.execute([:gen_agent, :prompt, :error], %{system_time: System.system_time()}, %{
      agent: name,
      ref: ref,
      reason: reason
    })
  end

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

  defp emit_halted(name) do
    :telemetry.execute([:gen_agent, :halted], %{system_time: System.system_time()}, %{
      agent: name
    })
  end
end
