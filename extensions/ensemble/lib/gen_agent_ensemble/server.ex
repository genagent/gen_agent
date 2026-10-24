defmodule GenAgentEnsemble.Server do
  @moduledoc false

  # This process owns a supervisor tree. Let each child's configured shutdown
  # budget apply rather than cutting off the whole tree after five seconds.
  use GenServer, shutdown: :infinity
  require Logger

  # Distinguish our cleanup from a supervisor failure that races a strategy halt.
  @halt_shutdown_reason {:shutdown, :ensemble_halted}
  @cancel_control_budget 5_000
  @default_max_completed_results 100
  @default_max_pending_prompts 1_000
  @default_max_pending_prompt_bytes 1_048_576

  defstruct [
    :owner,
    :strategy_mod,
    :strategy_state,
    :session_name,
    :session_started_at,
    # :running | :halted. A halted session stays alive as a read-only façade.
    :lifecycle,
    # Set once, by the first applied {:halt, reason}; nil and false are valid.
    :halt_reason,
    # Cleared once the shutdown the halt requested has been observed.
    :agent_tree,
    :task_supervisor,
    :agent_supervisor,
    # agents we own, %{bare_name => pid}
    :agents,
    # monitor refs, %{mref => agent_name}
    :monitors,
    # tokens awaiting reply, %{token => {:tell, recipient | nil} | {:ask, from}}
    :pending,
    # %{token => %{started_at: integer, kind: :ask | :tell, dispatches: integer,
    #              charge: non_neg_integer}}; charge is the admitted prompt size
    :token_contexts,
    # sum of the charges of all outstanding (active or waiting) tokens
    :pending_prompt_bytes,
    :max_pending_prompts,
    :max_pending_prompt_bytes,
    # %{token => pid}, only for opted-in completion requests
    :stream_recipients,
    # completed tell results, %{token => {:ok, response} | {:error, reason}}
    :completed,
    # FIFO of retained tokens only; consumed tokens are removed immediately
    :completed_order,
    :max_completed_results,
    # %{token => %{monitor_ref => {from, timer_ref | nil}}}
    :waiters,
    # %{monitor_ref => token}
    :waiter_monitors,
    # %{gen_agent_ref => {agent_name, run_token}}
    :in_flight,
    # %{gen_agent_ref => {started_at, ordinal, captured_pid, admission}}
    :dispatch_contexts,
    # Minimal ownership retained after an uncertain logical cancellation.
    # %{ref => {token, captured_pid, monitor_ref}}
    cancelled_refs: %{},
    # %{token => %{charge: non_neg_integer, refs: MapSet.t()}}
    cancellation_leases: %{},
    # %{monitor_ref => ref}; independent of member name/incarnation monitors
    cancellation_monitors: %{},
    # %{token => %{id, from, deadline, timer, refs}}. Pending owns the charge.
    cancellations: %{},
    # Active fences; these refs never enter ordinary strategy callbacks.
    cancelling_refs: %{},
    # %{monitor => {:worker | :child, captured_pid, token, operation_id, ref}}
    # Independent of member name/incarnation monitors.
    control_monitors: %{}
  ]

  # --- public API (called via GenAgentEnsemble shim) ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    # GenServer.start/3 keeps init failures as {:error, reason} returns rather
    # than exit signals to the caller; init/1 links the caller itself so a
    # caller that dies during a slow init still takes the session with it.
    GenServer.start(__MODULE__, {:linked, self(), opts}, name: via(name))
  end

  def tell(name, prompt, opts \\ []), do: GenServer.call(via(name), {:tell, prompt, opts})

  def tell_with_completion(name, prompt, recipient, opts \\ []) when is_pid(recipient) do
    {stream_to, opts} = Keyword.pop(opts, :stream_to)

    unless is_nil(stream_to) or is_pid(stream_to) do
      raise ArgumentError, "expected :stream_to to be nil or a pid"
    end

    GenServer.call(via(name), {:tell, prompt, opts, recipient, stream_to})
  end

  def await(name, token, timeout \\ 30_000)
      when timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
    GenServer.call(via(name), {:await, token, timeout}, :infinity)
  end

  def ask(name, prompt, opts \\ []) do
    {timeout, strategy_opts} = Keyword.pop_lazy(opts, :timeout, &default_ask_timeout/0)
    validate_ask_timeout!(timeout)
    GenServer.call(via(name), {:ask, prompt, strategy_opts}, timeout)
  end

  @default_ask_timeout 30_000

  defp default_ask_timeout do
    Application.get_env(:gen_agent_ensemble, :ask_timeout, @default_ask_timeout)
  end

  defp validate_ask_timeout!(:infinity), do: :ok
  defp validate_ask_timeout!(timeout) when is_integer(timeout) and timeout >= 0, do: :ok

  defp validate_ask_timeout!(timeout) do
    raise ArgumentError,
          "ask timeout must be a non-negative integer or :infinity, got: #{inspect(timeout)}"
  end

  def cancel(name, token), do: GenServer.call(via(name), {:cancel, token}, :infinity)

  def poll(name, token), do: GenServer.call(via(name), {:poll, token})
  def inbox(name), do: GenServer.call(via(name), :inbox)
  def notify(name, event), do: GenServer.cast(via(name), {:notify, event})
  def status(name), do: GenServer.call(via(name), :status)
  def stop(name), do: GenServer.stop(via(name), :normal, 10_000)

  defp via(name), do: {:via, Registry, {GenAgentEnsemble.Registry, name}}

  # --- GenServer callbacks ---

  @impl true
  def format_status(status) when is_map(status) do
    Map.new(status, fn
      {:state, %__MODULE__{} = state} -> {:state, redact_state(state)}
      {:state, _} -> {:state, :redacted}
      {:message, message} -> {:message, redact_status_term(message)}
      {:log, log} -> {:log, redact_status_log(log)}
      {:reason, reason} -> {:reason, redact_status_reason(reason)}
      entry -> entry
    end)
  end

  def format_status(_), do: %{}

  defp redact_state(%__MODULE__{} = state) do
    %__MODULE__{
      state
      | strategy_state: :redacted,
        halt_reason: :redacted,
        completed: :redacted,
        completed_order: :redacted,
        waiters: :redacted,
        waiter_monitors: :redacted,
        in_flight: :redacted,
        dispatch_contexts: :redacted,
        pending: :redacted,
        agents: :redacted,
        monitors: :redacted,
        stream_recipients: :redacted,
        cancelled_refs: :redacted,
        cancellation_leases: :redacted,
        cancellation_monitors: :redacted,
        cancellations: :redacted,
        cancelling_refs: :redacted,
        control_monitors: :redacted,
        token_contexts: :redacted
    }
  end

  defp redact_status_log(log) when is_list(log), do: Enum.map(log, &redact_status_term/1)
  defp redact_status_log(_), do: :redacted

  defp redact_status_term(value) when is_atom(value), do: value

  defp redact_status_term(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&redact_status_term/1) |> List.to_tuple()
  end

  defp redact_status_term(value) when is_list(value), do: Enum.map(value, &redact_status_term/1)
  defp redact_status_term(_), do: :redacted

  # Preserve routine shutdown atoms; other reasons can embed callback state.
  defp redact_status_reason(reason) when is_atom(reason), do: reason
  defp redact_status_reason({:shutdown, reason}) when is_atom(reason), do: {:shutdown, reason}
  defp redact_status_reason({:shutdown, _}), do: {:shutdown, :redacted}
  defp redact_status_reason(_), do: :redacted

  @impl true
  def init({:linked, owner, opts}) do
    # Link before starting the AgentTree. If the owner is already dead, the
    # link kills this process before any children exist.
    Process.link(owner)

    case init(opts) do
      {:ok, state} ->
        # Keep init interruptible by owner death, then trap exits so runtime
        # shutdown runs terminate/2 and waits for the owned tree's callbacks.
        Process.flag(:trap_exit, true)
        {:ok, %{state | owner: owner}}

      {:stop, _reason} = stop ->
        # Unlinking first means the {:stop, reason} exit cannot kill the
        # owner, which receives {:error, reason} from start_link/1 instead.
        Process.unlink(owner)
        stop
    end
  end

  def init(opts) do
    init_impl(opts)
  catch
    kind, reason ->
      reason_kind = callback_failure_kind(reason)

      Logger.error(
        "[gen_agent_ensemble] initialization failed (#{kind}: #{inspect(reason_kind)})"
      )

      {:stop, {:init_failed, kind, reason_kind}}
  end

  defp init_impl(opts) do
    strategy_mod = Keyword.fetch!(opts, :strategy)
    strategy_opts = Keyword.get(opts, :opts, [])
    session_name = Keyword.fetch!(opts, :name)

    with {:ok, max_completed_results} <- validate_max_completed_results(opts),
         {:ok, max_pending_prompts} <-
           validate_limit(opts, :max_pending_prompts, @default_max_pending_prompts),
         {:ok, max_pending_prompt_bytes} <-
           validate_limit(opts, :max_pending_prompt_bytes, @default_max_pending_prompt_bytes),
         {:ok, strategy_state, start_specs} <- strategy_mod.init(strategy_opts),
         {:ok, agent_tree} <- GenAgentEnsemble.AgentTree.start_link(session_name) do
      # Older releases left this handler behind after abrupt server death.
      # Request-scoped completions now replace the telemetry bridge entirely.
      detach_legacy_handler(session_name)

      {task_supervisor, agent_supervisor} =
        GenAgentEnsemble.AgentTree.supervisors(agent_tree)

      state = %__MODULE__{
        strategy_mod: strategy_mod,
        strategy_state: strategy_state,
        session_name: session_name,
        session_started_at: nil,
        lifecycle: :running,
        halt_reason: nil,
        agent_tree: agent_tree,
        task_supervisor: task_supervisor,
        agent_supervisor: agent_supervisor,
        agents: %{},
        monitors: %{},
        pending: %{},
        token_contexts: %{},
        pending_prompt_bytes: 0,
        max_pending_prompts: max_pending_prompts,
        max_pending_prompt_bytes: max_pending_prompt_bytes,
        stream_recipients: %{},
        completed: %{},
        completed_order: :queue.new(),
        max_completed_results: max_completed_results,
        waiters: %{},
        waiter_monitors: %{},
        in_flight: %{},
        dispatch_contexts: %{}
      }

      case apply_start_specs(state, start_specs) do
        {:ok, state} ->
          state = %{state | session_started_at: System.monotonic_time()}
          emit(:session, :start, %{system_time: System.system_time()}, session_meta(state))
          {:ok, state}

        {:error, reason} ->
          Supervisor.stop(agent_tree)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp validate_max_completed_results(opts) do
    case Keyword.get(opts, :max_completed_results, @default_max_completed_results) do
      :infinity -> {:ok, :infinity}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, {:invalid_option, :max_completed_results, value}}
    end
  end

  defp validate_limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      :infinity -> {:ok, :infinity}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, {:invalid_option, key, value}}
    end
  end

  defp apply_start_specs(state, specs) do
    Enum.reduce_while(specs, {:ok, state}, fn spec, {:ok, acc} ->
      case apply_op({:start, spec}, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def handle_call(request, from, state) do
    safely_callback(fn -> handle_call_impl(request, from, state) end, state)
  end

  @impl true
  def handle_cast(message, state) do
    safely_callback(fn -> handle_cast_impl(message, state) end, state)
  end

  @impl true
  def handle_info(message, state) do
    safely_callback(fn -> handle_info_impl(message, state) end, state)
  end

  defp safely_callback(fun, state) do
    fun.()
  catch
    kind, reason ->
      # GenServer exception stacktraces can render callback arguments before
      # format_status/1 gets to redact the state and message.
      reason_kind = callback_failure_kind(reason)
      Logger.error("[gen_agent_ensemble] callback failed (#{kind}: #{inspect(reason_kind)})")
      {:stop, {:callback_failed, kind, reason_kind}, state}
  end

  defp callback_failure_kind(%{__struct__: module}) when is_atom(module), do: module
  defp callback_failure_kind(_), do: :other

  defp handle_call_impl({:tell, prompt, opts}, from, state),
    do: handle_call_impl({:tell, prompt, opts, nil}, from, state)

  defp handle_call_impl({:tell, prompt, opts, recipient}, from, state),
    do: handle_call_impl({:tell, prompt, opts, recipient, nil}, from, state)

  # Terminal requests are refused after normalization and before admission:
  # no token, callback, child work or event exists for them.
  defp handle_call_impl({:tell, _prompt, _opts, _recipient, _stream_to}, _from, state)
       when state.lifecycle == :halted,
       do: {:reply, halted_error(state), state}

  defp handle_call_impl({:tell, prompt, opts, recipient, stream_to}, _from, state) do
    case admit(state, :tell, prompt) do
      {:ok, charge} ->
        token = mint_token()
        state = start_token(state, token, :tell, {:tell, recipient}, charge)

        state =
          if stream_to,
            do: %{state | stream_recipients: Map.put(state.stream_recipients, token, stream_to)},
            else: state

        {ops, strategy_state} =
          call_strategy(state.strategy_mod, :handle_tell, [
            prompt,
            opts,
            token,
            state.strategy_state
          ])

        state = %{state | strategy_state: strategy_state} |> apply_ops(ops)
        {:reply, {:ok, token}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_call_impl({:ask, _prompt, _opts}, _from, state) when state.lifecycle == :halted,
    do: {:reply, halted_error(state), state}

  defp handle_call_impl({:ask, prompt, opts}, from, state) do
    case admit(state, :ask, prompt) do
      {:ok, charge} ->
        token = mint_token()
        state = start_token(state, token, :ask, {:ask, from}, charge)

        {ops, strategy_state} =
          call_strategy(state.strategy_mod, :handle_ask, [
            prompt,
            opts,
            token,
            state.strategy_state
          ])

        state = %{state | strategy_state: strategy_state} |> apply_ops(ops)
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_call_impl({:await, token, timeout}, from, state) do
    case {Map.fetch(state.completed, token), Map.get(state.pending, token)} do
      {{:ok, result}, _} ->
        {:reply, result, state}

      {:error, {:tell, _}} when timeout == 0 ->
        {:reply, {:error, :timeout}, state}

      {:error, {:tell, _}} ->
        mref = Process.monitor(elem(from, 0))

        timer =
          if timeout != :infinity,
            do: Process.send_after(self(), {:await_timeout, mref}, timeout)

        waiters = Map.get(state.waiters, token, %{}) |> Map.put(mref, {from, timer})

        {:noreply,
         %{
           state
           | waiters: Map.put(state.waiters, token, waiters),
             waiter_monitors: Map.put(state.waiter_monitors, mref, token)
         }}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp handle_call_impl({:cancel, token}, from, state) do
    cond do
      Map.has_key?(state.cancellations, token) ->
        {:reply, {:error, :cancelling}, state}

      Map.has_key?(state.completed, token) ->
        {:reply, {:error, :already_finished}, state}

      not Map.has_key?(state.pending, token) ->
        {:reply, {:error, :not_found}, state}

      not function_exported?(state.strategy_mod, :handle_cancel, 2) ->
        {:reply, {:error, :unsupported}, state}

      true ->
        deadline = System.monotonic_time(:millisecond) + @cancel_control_budget
        state = drain_child_messages(state)

        if Map.has_key?(state.pending, token) do
          {:noreply, begin_cancellation(state, token, from, deadline)}
        else
          {:reply, {:error, :already_finished}, state}
        end
    end
  end

  defp handle_call_impl({:poll, token}, _from, state) do
    cond do
      Map.has_key?(state.completed, token) ->
        {result, state} = pop_completed(state, token)

        reply =
          case result do
            {:ok, response} -> {:ok, :completed, response}
            {:error, reason} -> {:error, reason}
          end

        {:reply, reply, state}

      Map.has_key?(state.pending, token) ->
        {:reply, {:ok, :pending}, state}

      true ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp handle_call_impl(:inbox, _from, state) do
    entries =
      Enum.map(state.completed, fn {token, result} -> {token, result} end)

    {:reply, {:ok, entries}, %{state | completed: %{}, completed_order: :queue.new()}}
  end

  defp handle_call_impl(:status, _from, state) do
    base = %{
      session: state.session_name,
      strategy: state.strategy_mod,
      agents: Map.keys(state.agents),
      pending_tokens: Map.keys(state.pending),
      in_flight: map_size(state.in_flight)
    }

    # A halted session never calls its strategy again, and the strategy's
    # extras would describe state that no longer exists.
    extra =
      if state.lifecycle == :running and
           function_exported?(state.strategy_mod, :handle_status, 1) do
        strategy_status(state.strategy_mod, state.strategy_state)
      else
        {:ok, %{}}
      end

    case extra do
      {:ok, fields} ->
        # Merged last so a strategy cannot replace the authoritative fields.
        admission = %{
          scope: :outstanding,
          pending_count: charged_count(state),
          unresolved_cancelled_tokens: map_size(state.cancellation_leases),
          unresolved_cancelled_refs: map_size(state.cancelled_refs),
          pending_bytes: state.pending_prompt_bytes,
          max_pending_prompts: state.max_pending_prompts,
          max_pending_prompt_bytes: state.max_pending_prompt_bytes
        }

        status =
          base
          |> Map.merge(fields)
          |> Map.put(:admission, admission)
          |> Map.put(:lifecycle, state.lifecycle)
          |> Map.put(
            :member_names,
            Map.new(state.agents, fn {bare, _pid} -> {bare, member_name(state, bare)} end)
          )

        {:reply, {:ok, status}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp strategy_status(strategy_mod, strategy_state) do
    result =
      try do
        {:ok, strategy_mod.handle_status(strategy_state)}
      catch
        kind, _reason -> {:error, {:strategy_callback_failed, :handle_status, kind}}
      end

    case result do
      {:ok, fields} when is_map(fields) -> {:ok, fields}
      {:ok, _other} -> {:error, {:invalid_strategy_result, :handle_status}}
      {:error, _reason} = error -> error
    end
  end

  defp handle_cast_impl({:notify, _event}, state) when state.lifecycle == :halted,
    do: {:noreply, state}

  defp handle_cast_impl({:notify, event}, state) do
    state =
      if function_exported?(state.strategy_mod, :handle_notify, 2) do
        {ops, strategy_state} =
          call_strategy(state.strategy_mod, :handle_notify, [event, state.strategy_state])

        %{state | strategy_state: strategy_state} |> apply_ops(ops)
      else
        state
      end

    {:noreply, state}
  end

  defp handle_info_impl({:cancel_control_result, token, id, ref, worker, outcome}, state) do
    valid? =
      Enum.any?(state.control_monitors, fn {_, entry} ->
        entry == {:worker, worker, token, id, ref}
      end)

    case Map.fetch(state.cancellations, token) do
      {:ok, %{id: ^id}} when valid? ->
        {:noreply, update_cancellation(state, token, ref, outcome == true, true)}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_info_impl({:cancel_deadline, token, id}, state) do
    case Map.fetch(state.cancellations, token) do
      {:ok, %{id: ^id} = op} -> {:noreply, finish_cancellation(state, token, op)}
      _ -> {:noreply, state}
    end
  end

  defp handle_info_impl({:DOWN, monitor, :process, pid, _}, state)
       when is_map_key(state.control_monitors, monitor) do
    {{kind, ^pid, token, id, ref}, monitors} = Map.pop(state.control_monitors, monitor)
    state = %{state | control_monitors: monitors}

    case Map.fetch(state.cancellations, token) do
      {:ok, %{id: ^id}} ->
        {:noreply, update_cancellation(state, token, ref, kind == :child, true)}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_info_impl({:gen_agent, kind, _, ref, result}, state)
       when kind in [:admission, :completion, :event] and is_map_key(state.cancelling_refs, ref) do
    terminal? = kind == :completion or (kind == :admission and match?({:error, _}, result))

    if terminal? do
      token = Map.fetch!(state.cancelling_refs, ref)
      {:noreply, update_cancellation(state, token, ref, true, true)}
    else
      {:noreply, state}
    end
  end

  # Logical cancellation has already emitted its terminal result/telemetry.
  # Only terminal evidence retires this ownership; admission alone does not.
  defp handle_info_impl({:gen_agent, :completion, _name, ref, _result}, state)
       when is_map_key(state.cancelled_refs, ref) do
    {:noreply, settle_cancelled_ref(state, ref)}
  end

  defp handle_info_impl({:gen_agent, :admission, _name, ref, {:error, _reason}}, state)
       when is_map_key(state.cancelled_refs, ref) do
    {:noreply, settle_cancelled_ref(state, ref)}
  end

  defp handle_info_impl({:DOWN, mref, :process, pid, _reason}, state)
       when is_map_key(state.cancellation_monitors, mref) do
    ref = Map.fetch!(state.cancellation_monitors, mref)
    {_token, ^pid, ^mref} = Map.fetch!(state.cancelled_refs, ref)
    {:noreply, settle_cancelled_ref(state, ref)}
  end

  # A terminal ref cannot be reopened by a later admission decision.
  defp handle_info_impl({:gen_agent, :admission, _name, ref, :ok}, state) do
    {:noreply, accept_dispatch(state, ref)}
  end

  defp handle_info_impl({:gen_agent, :admission, _name, ref, {:error, reason}}, state) do
    case Map.fetch(state.dispatch_contexts, ref) do
      {:ok, {_started_at, ordinal, _pid, :submitted}} ->
        {agent, token} = Map.fetch!(state.in_flight, ref)

        Logger.warning(
          "[gen_agent_ensemble] op #{inspect(op_summary(if token == nil, do: {:dispatch, agent, nil}, else: {:dispatch, agent, nil, token}))} failed: #{reason_kind(reason)}"
        )

        emit(
          :dispatch,
          :rejected,
          %{},
          dispatch_meta(state, agent, token, ref, ordinal)
          |> Map.put(:outcome, :rejected)
          |> Map.put(:reason_kind, reason_kind(reason))
        )

        state = %{
          state
          | in_flight: Map.delete(state.in_flight, ref),
            dispatch_contexts: Map.delete(state.dispatch_contexts, ref)
        }

        {:noreply,
         if(token != nil and Map.has_key?(state.pending, token),
           do: reject_dispatch(state, agent, token, reason),
           else: state
         )}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_info_impl({:gen_agent, :completion, _ns_agent, ref, {:ok, response}}, state) do
    state = accept_dispatch(state, ref)

    case Map.pop(state.in_flight, ref) do
      {nil, _} ->
        {:noreply, state}

      {{bare_agent, token}, rest} ->
        {{started_at, ordinal, _pid, _admission}, contexts} =
          Map.pop(state.dispatch_contexts, ref)

        state = %{state | in_flight: rest, dispatch_contexts: contexts}
        emit_dispatch(state, :stop, bare_agent, token, ref, started_at, ordinal)
        {:noreply, handle_prompt_response(state, bare_agent, token, response)}
    end
  end

  defp handle_info_impl({:gen_agent, :completion, _ns_agent, ref, {:error, reason}}, state) do
    state = accept_dispatch(state, ref)

    case Map.pop(state.in_flight, ref) do
      {nil, _} ->
        {:noreply, state}

      {{bare_agent, token}, rest} ->
        {{started_at, ordinal, _pid, _admission}, contexts} =
          Map.pop(state.dispatch_contexts, ref)

        state = %{state | in_flight: rest, dispatch_contexts: contexts}

        emit_dispatch(state, :error, bare_agent, token, ref, started_at, ordinal,
          reason_kind: reason_kind(reason)
        )

        {:noreply, handle_prompt_error(state, bare_agent, token, reason)}
    end
  end

  defp handle_info_impl({:await_timeout, mref}, state) do
    {:noreply, remove_waiter(state, mref, {:error, :timeout})}
  end

  # GenServer.start/3 does not make the manually linked owner the OTP parent.
  # Handle its exits explicitly, including :normal, in every lifecycle.
  defp handle_info_impl({:EXIT, pid, reason}, state) when pid == state.owner do
    {:stop, reason, state}
  end

  # The one tree exit a halted session expects: the tagged shutdown halting
  # requested. Dropping the PIDs tells terminate/2 there is nothing left to wait for.
  defp handle_info_impl(
         {:EXIT, tree, @halt_shutdown_reason},
         %{lifecycle: :halted, agent_tree: tree} = state
       ) do
    {:noreply, %{state | agent_tree: nil, task_supervisor: nil, agent_supervisor: nil}}
  end

  # Any other tree exit, running or halted, still fails the session rather than
  # continuing to route work to dead supervisors.
  defp handle_info_impl({:EXIT, pid, reason}, state) when pid == state.agent_tree do
    {:stop, reason, state}
  end

  defp handle_info_impl({:EXIT, _pid, reason}, state) when reason != :normal do
    {:stop, reason, state}
  end

  # A halted session runs no strategy code and routes no work. Completions,
  # stream events, agent DOWNs and waiter timeouts that were already in the
  # mailbox are stale by definition.
  defp handle_info_impl(_message, %{lifecycle: :halted} = state), do: {:noreply, state}

  defp handle_info_impl({:DOWN, mref, :process, _pid, _reason}, state)
       when is_map_key(state.waiter_monitors, mref) do
    {:noreply, remove_waiter(state, mref, nil)}
  end

  defp handle_info_impl({:DOWN, mref, :process, pid, reason}, state) do
    case Map.fetch(state.monitors, mref) do
      {:ok, agent}
      when is_map_key(state.agents, agent) and :erlang.map_get(agent, state.agents) === pid ->
        affected_tokens =
          for {_ref, {name, token}} <- state.in_flight, name == agent, do: token

        emit_dropped_dispatches(state, agent, :agent_down)

        state = %{
          state
          | monitors: Map.delete(state.monitors, mref),
            agents: Map.delete(state.agents, agent),
            in_flight: drop_in_flight_for(state.in_flight, agent),
            dispatch_contexts: drop_dispatch_contexts_for(state, agent)
        }

        state =
          if function_exported?(state.strategy_mod, :handle_agent_down, 3) do
            {ops, strategy_state} =
              call_strategy(state.strategy_mod, :handle_agent_down, [
                agent,
                reason,
                state.strategy_state
              ])

            %{state | strategy_state: strategy_state} |> apply_ops(ops)
          else
            fail_unhandled_tokens(state, affected_tokens, {:agent_down, agent, reason})
          end

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_info_impl({:gen_agent, :event, _ns_agent, ref, event}, state) do
    with {:ok, {agent, token}} <- Map.fetch(state.in_flight, ref),
         {:ok, recipient} <- Map.fetch(state.stream_recipients, token) do
      {_started_at, ordinal, _pid, _admission} = Map.fetch!(state.dispatch_contexts, ref)

      send(
        recipient,
        {:gen_agent_ensemble, :event, state.session_name, token,
         %{agent: agent, dispatch: ordinal, event: event}}
      )
    end

    {:noreply, state}
  end

  defp handle_info_impl(_msg, state), do: {:noreply, state}

  defp handle_prompt_response(state, bare_agent, token, response) do
    if active_dispatch?(state, token) do
      {ops, strategy_state} =
        call_strategy(state.strategy_mod, :handle_response, [
          bare_agent,
          response,
          state.strategy_state
        ])

      %{state | strategy_state: strategy_state} |> apply_ops(ops)
    else
      state
    end
  end

  defp handle_prompt_error(state, bare_agent, token, reason) do
    cond do
      not active_dispatch?(state, token) ->
        state

      function_exported?(state.strategy_mod, :handle_error, 3) ->
        {ops, strategy_state} =
          call_strategy(state.strategy_mod, :handle_error, [
            bare_agent,
            reason,
            state.strategy_state
          ])

        %{state | strategy_state: strategy_state} |> apply_ops(ops)

      true ->
        Logger.warning(
          "[gen_agent_ensemble] agent #{bare_agent} turn errored (unhandled): #{reason_kind(reason)}"
        )

        fail_unhandled_token(state, token, reason)
    end
  end

  defp fail_unhandled_tokens(state, tokens, reason) do
    Enum.reduce(Enum.uniq(tokens), state, fn token, acc ->
      fail_unhandled_token(acc, token, reason)
    end)
  end

  # Unscoped dispatches have no token to close. For scoped work, retire every
  # remaining ref for the failed token, including sibling fanout requests.
  defp fail_unhandled_token(state, nil, _reason), do: state

  defp fail_unhandled_token(state, token, reason) do
    if Map.has_key?(state.pending, token) do
      state =
        Enum.reduce(state.in_flight, state, fn
          {ref, {agent, ^token}}, acc ->
            {{started_at, ordinal, _pid, _admission}, contexts} =
              Map.pop(acc.dispatch_contexts, ref)

            emit_dispatch(acc, :error, agent, token, ref, started_at, ordinal,
              reason_kind: reason_kind(reason)
            )

            %{acc | in_flight: Map.delete(acc.in_flight, ref), dispatch_contexts: contexts}

          _, acc ->
            acc
        end)

      {:ok, state} = reply_to_token(state, token, {:error, reason})
      state
    else
      state
    end
  end

  @impl true
  def terminate(reason, state) do
    # Stop admitting callers while cleanup runs. The AgentTree keeps its own
    # registration until it dies, so a same-name restart still waits for it.
    Registry.unregister(GenAgentEnsemble.Registry, state.session_name)
    Enum.each(state.waiter_monitors, fn {mref, _} -> remove_waiter(state, mref, nil) end)
    Enum.each(state.cancellations, fn {token, op} -> retire_cancellation(state, token, op) end)
    emit_unfinished_work(state)

    outcome =
      if state.lifecycle == :halted,
        do: :halted,
        else: if(reason == :normal, do: :ok, else: :error)

    emit(
      :session,
      :stop,
      %{duration_ms: elapsed_ms(state.session_started_at)},
      session_meta(state)
      |> Map.put(:outcome, outcome)
      |> Map.put(:reason_kind, reason_kind(reason))
    )

    # A tree still held, even one already shutting down after a halt, is
    # waited for. A halted session whose tree exit was consumed holds none.
    if state.agent_tree, do: catch_exit(fn -> Supervisor.stop(state.agent_tree) end)
    :ok
  end

  # --- op execution ---

  # A halt ends every batch, including those a nested rejection callback
  # returns, so nothing runs in a terminal session.
  defp apply_ops(%{lifecycle: :halted} = state, _ops), do: state

  defp apply_ops(state, ops) do
    Enum.reduce_while(ops, state, &apply_op_safe/2)
  end

  defp apply_op_safe(op, state) do
    case apply_op(op, state) do
      {:ok, %{lifecycle: :halted} = next} ->
        {:halt, next}

      {:ok, next} ->
        {:cont, next}

      # A previous op may have already closed this run (for example, a
      # rejected member of a Consensus fanout).
      {:error, {:unknown_token, _}} when tuple_size(op) == 4 and elem(op, 0) == :dispatch ->
        {:cont, state}

      {:error, reason} ->
        Logger.warning(
          "[gen_agent_ensemble] op #{inspect(op_summary(op))} failed: " <>
            "#{reason_kind(reason)}#{reason_detail(reason)}"
        )

        handle_op_failure(op, reason, state)
    end
  end

  # The operation tag, agent name, and token identify a failed action without
  # rendering its prompt, start options, response, or backend error body.
  # Names and tokens are only rendered when they are strings, so a malformed
  # operation cannot smuggle an arbitrary term into the log.
  defp op_summary({:start, {name, _module, _opts}}) when is_binary(name), do: {:start, name}
  defp op_summary({:start, _spec}), do: {:start, :invalid_spec}
  defp op_summary({:stop, name}) when is_binary(name), do: {:stop, name}

  defp op_summary({:dispatch, name, _prompt, token}) when is_binary(name) and is_binary(token),
    do: {:dispatch, name, token}

  defp op_summary({tag, name, _payload}) when tag in [:dispatch, :forward] and is_binary(name),
    do: {tag, name}

  defp op_summary({tag, token, _payload}) when tag in [:reply, :reply_error] and is_binary(token),
    do: {tag, token}

  defp op_summary(_op), do: :unknown_op

  # Synchronous ownership-guard rejection stops this scoped dispatch batch.
  # Child admission rejection arrives asynchronously after later ops may run. A malformed
  # operation was never a dispatch attempt, so it is skipped like any other
  # logged failure.
  defp handle_op_failure(_op, :invalid_operation, state), do: {:cont, state}

  defp handle_op_failure({:dispatch, agent, _prompt, token}, reason, state) do
    {:halt, reject_dispatch(state, agent, token, reason)}
  end

  # Even a tuple with the wrong arity can identify the rejected child by its
  # first field. Non-tuples, empty tuples and non-string names are skipped.
  defp handle_op_failure({:start, spec}, reason, state)
       when is_tuple(spec) and tuple_size(spec) > 0 and is_binary(elem(spec, 0)) do
    agent = elem(spec, 0)

    if function_exported?(state.strategy_mod, :handle_start_rejected, 3) do
      {ops, strategy_state} =
        call_strategy(state.strategy_mod, :handle_start_rejected, [
          agent,
          reason,
          state.strategy_state
        ])

      {:halt, %{state | strategy_state: strategy_state} |> apply_ops(ops)}
    else
      {:cont, state}
    end
  end

  defp handle_op_failure(_op, _reason, state), do: {:cont, state}

  defp reject_dispatch(state, agent, token, reason) do
    state =
      if function_exported?(state.strategy_mod, :handle_dispatch_rejected, 4) do
        {ops, strategy_state} =
          call_strategy(state.strategy_mod, :handle_dispatch_rejected, [
            agent,
            token,
            reason,
            state.strategy_state
          ])

        %{state | strategy_state: strategy_state} |> apply_ops(ops)
      else
        state
      end

    # External strategies without the callback still get a terminal result.
    # reply_to_token is conditional, so a strategy's own reply wins.
    if Map.has_key?(state.pending, token) do
      {:ok, state} = reply_to_token(state, token, {:error, {:dispatch_rejected, agent, reason}})
      state
    else
      state
    end
  end

  # Operations are strategy output, so their shape is checked here rather than
  # trusted. Anything that does not match a documented operation is skipped
  # through the ordinary op-failure path; see the final clause.
  defp apply_op({:start, spec}, state) do
    with {:ok, {name, module, opts}} <- validate_start_spec(spec),
         {:ok, child_spec} <- build_child_spec(state, name, module, opts) do
      start_agent(state, name, child_spec)
    end
  end

  defp apply_op({:stop, name}, state) when is_binary(name) do
    case Map.fetch(state.agents, name) do
      {:ok, pid} ->
        stop_owned_member(state, name, pid)

      :error ->
        {:error, {:agent_not_running, name}}
    end
  end

  # Cancellation closes application access immediately; pending retains only
  # the admission charge until physical ownership has been settled.
  defp apply_op({:dispatch, _, _, token}, state)
       when is_map_key(state.cancellations, token),
       do: {:error, {:unknown_token, token}}

  defp apply_op({tag, token, _}, state)
       when tag in [:reply, :reply_error] and is_map_key(state.cancellations, token),
       do: {:error, {:unknown_token, token}}

  defp apply_op({:dispatch, name, prompt, token}, state)
       when is_binary(name) and is_binary(prompt) and is_binary(token) do
    if Map.has_key?(state.pending, token) do
      dispatch(state, name, prompt, token)
    else
      {:error, {:unknown_token, token}}
    end
  end

  # Existing external strategies may still use the unscoped operation.
  defp apply_op({:dispatch, name, prompt}, state) when is_binary(name) and is_binary(prompt),
    do: dispatch(state, name, prompt, nil)

  defp apply_op({:reply, token, response}, state) do
    reply_to_token(state, token, {:ok, response})
  end

  defp apply_op({:reply_error, token, reason}, state) do
    reply_to_token(state, token, {:error, reason})
  end

  defp apply_op({:forward, name, event}, state) when is_binary(name) do
    with :ok <- owned_member(state, name),
         :ok <- catch_exit(fn -> GenAgent.notify(member_name(state, name), event) end) do
      {:ok, state}
    end
  end

  defp apply_op({:halt, reason}, state), do: {:ok, halt_session(state, reason)}

  defp apply_op(_malformed, _state), do: {:error, :invalid_operation}

  # The first applied halt is the logical end of the session. Everything that
  # can still be observed from outside is settled here, once: open dispatches
  # are retired, every pending token gets the halt error through the ordinary
  # reply path (recipients, waiters, retention and capacity included), and the
  # state that routed work to children is dropped. Results already stored stay
  # as they are. The process stays up so those results can be read; only the
  # owned tree is told to shut down.
  defp halt_session(%{lifecycle: :halted} = state, _reason), do: state

  defp halt_session(state, reason) do
    emit(
      :session,
      :halt,
      %{duration_ms: elapsed_ms(state.session_started_at)},
      session_meta(state)
      |> Map.put(:outcome, :halted)
      |> Map.put(:reason_kind, :strategy_halt)
    )

    emit_open_dispatches(state, :halted)

    state =
      Enum.reduce(state.cancellations, state, fn {token, op}, acc ->
        GenServer.reply(op.from, {:error, {:halted, reason}})
        retire_cancellation(acc, token, op)
      end)

    state = release_cancellation_leases(state)
    Enum.each(state.monitors, fn {mref, _agent} -> Process.demonitor(mref, [:flush]) end)

    state = %{
      state
      | lifecycle: :halted,
        halt_reason: reason,
        strategy_state: nil,
        agents: %{},
        monitors: %{},
        in_flight: %{},
        dispatch_contexts: %{}
    }

    state =
      Enum.reduce(Map.keys(state.pending), state, fn token, acc ->
        {:ok, acc} = reply_to_token(acc, token, {:error, {:halted, reason}})
        acc
      end)

    # Not Supervisor.stop/1: a child's shutdown budget may be long or infinite,
    # and this process must keep serving the results it just produced. As the
    # tree's OTP parent, an exit signal starts its normal termination. The link
    # and PID stay until the expected EXIT arrives, so terminate/2 can still
    # wait for a cleanup that is underway.
    Process.exit(state.agent_tree, @halt_shutdown_reason)
    state
  end

  defp halted_error(state), do: {:error, {:halted, state.halt_reason}}

  # Only the shape of the spec is checked: the reasons name the offending field
  # and never carry the value, which may hold credentials. A backend module is
  # not loaded here; the child start reports an unusable one.
  defp validate_start_spec({name, module, opts} = spec) do
    cond do
      not is_binary(name) -> {:error, {:invalid_start_spec, :name}}
      not module_name?(module) -> {:error, {:invalid_start_spec, :module}}
      not Keyword.keyword?(opts) -> {:error, {:invalid_start_spec, :options}}
      not valid_backend?(opts) -> {:error, {:invalid_start_spec, :backend}}
      true -> {:ok, spec}
    end
  end

  defp validate_start_spec(_), do: {:error, {:invalid_start_spec, :shape}}

  defp module_name?(module), do: is_atom(module) and module not in [nil, true, false]

  defp valid_backend?(opts) do
    case Keyword.fetch(opts, :backend) do
      {:ok, backend} -> module_name?(backend)
      :error -> false
    end
  end

  # GenAgent.child_spec/2 raises on options it rejects (for example a bad
  # :shutdown). Only that call is contained, and the exception is reduced to a
  # fixed reason because its message can quote the options.
  defp build_child_spec(state, name, module, opts) do
    agent_opts =
      opts
      |> Keyword.put(:name, member_name(state, name))
      |> Keyword.put(:task_supervisor, state.task_supervisor)

    try do
      {:ok, GenAgent.child_spec(module, agent_opts)}
    catch
      _kind, _reason -> {:error, {:invalid_start_spec, :child_spec}}
    end
  end

  # Starting runs the child's own init code. A raise, throw, or exit from the
  # start invocation is reduced to its kind; returned errors pass through
  # unchanged.
  defp start_child(supervisor, child_spec) do
    DynamicSupervisor.start_child(supervisor, child_spec)
  catch
    kind, _reason -> {:error, {:start_exception, kind}}
  end

  defp start_agent(state, name, _child_spec) when is_map_key(state.agents, name),
    do: {:error, {:duplicate_sub_agent, name}}

  defp start_agent(state, name, child_spec) do
    case start_child(state.agent_supervisor, child_spec) do
      {:ok, pid} ->
        mref = Process.monitor(pid)

        {:ok,
         %{
           state
           | agents: Map.put(state.agents, name, pid),
             monitors: Map.put(state.monitors, mref, name)
         }}

      {:error, {:already_started, _pid}} ->
        {:error, {:member_name_conflict, name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch(state, name, prompt, token) do
    opts =
      if Map.has_key?(state.stream_recipients, token),
        do: [on_halt: :fail, stream_to: self()],
        else: [on_halt: :fail]

    result =
      with :ok <- owned_member(state, name) do
        pid = Map.fetch!(state.agents, name)
        {:submitted, ref} = GenAgent.Client.submit_with_completion(pid, prompt, self(), opts)
        {:submitted, ref, pid}
      end

    case result do
      {:submitted, ref, pid} ->
        # Child events may already be queued, but this callback registers the
        # ref before the GenServer can process those mailbox messages.
        {ordinal, state} = next_dispatch(state, token)
        started_at = System.monotonic_time()

        {:ok,
         %{
           state
           | in_flight: Map.put(state.in_flight, ref, {name, token}),
             dispatch_contexts:
               Map.put(state.dispatch_contexts, ref, {started_at, ordinal, pid, :submitted})
         }}

      {:error, reason} ->
        emit(
          :dispatch,
          :rejected,
          %{},
          dispatch_meta(state, name, token, nil, nil)
          |> Map.put(:outcome, :rejected)
          |> Map.put(:reason_kind, reason_kind(reason))
        )

        {:error, reason}
    end
  end

  # Drain events and completions in arrival order across ALL refs:
  # Solo/Switchboard correlate responses with their per-agent FIFO. Selecting
  # just this token's completion could pop an unrelated predecessor instead.
  defp drain_child_messages(state) do
    receive do
      {:gen_agent, kind, _, _, _} = message when kind in [:admission, :event, :completion] ->
        {:noreply, state} = handle_info_impl(message, state)
        drain_child_messages(state)
    after
      0 -> state
    end
  end

  # Fence the whole snapshot before controls or strategy operations can run.
  # Pending owns the capacity until finish; only unresolved refs become leases.
  defp begin_cancellation(state, token, from, deadline) do
    refs =
      Map.new(
        for {ref, {agent, ^token}} <- state.in_flight do
          {_, _, pid, _} = Map.fetch!(state.dispatch_contexts, ref)
          {ref, %{pid: pid, agent: agent, settled: false, done: false}}
        end
      )

    id = make_ref()

    timer =
      Process.send_after(
        self(),
        {:cancel_deadline, token, id},
        max(0, deadline - System.monotonic_time(:millisecond))
      )

    op = %{id: id, from: from, deadline: deadline, timer: timer, refs: refs}
    state = %{state | cancellations: Map.put(state.cancellations, token, op)}

    state =
      Enum.reduce(refs, state, fn {ref, target}, acc ->
        monitor = Process.monitor(target.pid)

        acc = %{
          acc
          | cancelling_refs: Map.put(acc.cancelling_refs, ref, token),
            control_monitors:
              Map.put(acc.control_monitors, monitor, {:child, target.pid, token, id, ref})
        }

        fence_cancelled_ref(acc, ref, target.agent, token)
      end)

    {ops, strategy_state} =
      call_strategy(state.strategy_mod, :handle_cancel, [token, state.strategy_state])

    state = %{state | strategy_state: strategy_state}
    server = self()

    state =
      Enum.reduce(refs, state, fn {ref, target}, acc ->
        {worker, monitor} =
          spawn_monitor(fn ->
            outcome = cancel_child(target.pid, ref, deadline)
            send(server, {:cancel_control_result, token, id, ref, self(), outcome})
          end)

        %{
          acc
          | control_monitors:
              Map.put(acc.control_monitors, monitor, {:worker, worker, token, id, ref})
        }
      end)

    # Strategy-generated stops/starts remain synchronous in this slice.
    state |> apply_ops(ops) |> maybe_finish_cancellation(token)
  end

  defp cancel_child(pid, ref, deadline) do
    case cancel_control(pid, ref, :cancel_request, deadline) do
      {:ok, :cancelled} ->
        true

      {:error, :current} ->
        cancel_control(pid, ref, :interrupt_request, deadline) == {:ok, :accepted}

      _ ->
        false
    end
  end

  defp update_cancellation(state, token, ref, settled?, done?) do
    op = Map.fetch!(state.cancellations, token)
    target = Map.fetch!(op.refs, ref)
    target = %{target | settled: target.settled or settled?, done: target.done or done?}
    op = %{op | refs: Map.put(op.refs, ref, target)}

    %{state | cancellations: Map.put(state.cancellations, token, op)}
    |> maybe_finish_cancellation(token)
  end

  defp maybe_finish_cancellation(state, token) do
    case Map.fetch(state.cancellations, token) do
      {:ok, op} ->
        if Enum.all?(op.refs, fn {_, t} -> t.settled or t.done end),
          do: finish_cancellation(state, token, op),
          else: state

      :error ->
        state
    end
  end

  defp finish_cancellation(state, token, op) do
    state = retire_cancellation(state, token, op)

    state =
      Enum.reduce(op.refs, state, fn {ref, target}, acc ->
        if target.settled, do: acc, else: retain_cancelled_ref(acc, ref, token, target.pid)
      end)

    state =
      case reply_to_token(state, token, {:error, :cancelled}) do
        {:ok, next} -> next
        {:error, {:unknown_token, ^token}} -> state
      end

    confirmed? = Enum.all?(op.refs, fn {_, target} -> target.settled end)
    GenServer.reply(op.from, {:ok, if(confirmed?, do: :cancelled, else: :cancelled_unconfirmed)})
    state
  end

  defp retire_cancellation(state, token, op) do
    Process.cancel_timer(op.timer)

    monitors =
      Enum.reduce(state.control_monitors, state.control_monitors, fn
        {monitor, {kind, pid, current, id, _}}, acc when current == token and id == op.id ->
          if kind == :worker, do: Process.exit(pid, :kill)
          Process.demonitor(monitor, [:flush])
          Map.delete(acc, monitor)

        _, acc ->
          acc
      end)

    %{
      state
      | cancellations: Map.delete(state.cancellations, token),
        cancelling_refs: Map.drop(state.cancelling_refs, Map.keys(op.refs)),
        control_monitors: monitors
    }
  end

  defp cancel_control(pid, ref, operation, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      apply(GenAgent.Client, operation, [pid, ref, remaining])
    else
      {:error, :timeout}
    end
  catch
    :exit, _ -> {:error, :unconfirmed}
  end

  defp retain_cancelled_ref(state, ref, token, pid) do
    monitor = Process.monitor(pid)
    charge = Map.fetch!(state.token_contexts, token).charge
    lease = Map.get(state.cancellation_leases, token, %{charge: charge, refs: MapSet.new()})
    lease = %{lease | refs: MapSet.put(lease.refs, ref)}

    %{
      state
      | cancelled_refs: Map.put(state.cancelled_refs, ref, {token, pid, monitor}),
        cancellation_leases: Map.put(state.cancellation_leases, token, lease),
        cancellation_monitors: Map.put(state.cancellation_monitors, monitor, ref)
    }
  end

  defp settle_cancelled_ref(state, ref) do
    {{token, _pid, monitor}, refs} = Map.pop(state.cancelled_refs, ref)
    Process.demonitor(monitor, [:flush])
    lease = Map.fetch!(state.cancellation_leases, token)
    remaining = MapSet.delete(lease.refs, ref)
    settled? = MapSet.size(remaining) == 0

    leases =
      if settled?,
        do: Map.delete(state.cancellation_leases, token),
        else: Map.put(state.cancellation_leases, token, %{lease | refs: remaining})

    %{
      state
      | cancelled_refs: refs,
        cancellation_monitors: Map.delete(state.cancellation_monitors, monitor),
        cancellation_leases: leases,
        pending_prompt_bytes: state.pending_prompt_bytes - if(settled?, do: lease.charge, else: 0)
    }
  end

  # Halt closes admission and hands remaining physical ownership to the dying
  # owned tree. No lease can admit replacement work in a halted session.
  defp release_cancellation_leases(state) do
    Enum.each(state.cancellation_monitors, fn {monitor, _} ->
      Process.demonitor(monitor, [:flush])
    end)

    charge =
      Enum.reduce(state.cancellation_leases, 0, fn {_, lease}, sum -> sum + lease.charge end)

    %{
      state
      | cancelled_refs: %{},
        cancellation_leases: %{},
        cancellation_monitors: %{},
        pending_prompt_bytes: state.pending_prompt_bytes - charge
    }
  end

  defp fence_cancelled_ref(state, ref, agent, token) do
    {{started_at, ordinal, _pid, _admission}, contexts} = Map.pop(state.dispatch_contexts, ref)
    emit_dispatch(state, :error, agent, token, ref, started_at, ordinal, reason_kind: :cancelled)
    %{state | in_flight: Map.delete(state.in_flight, ref), dispatch_contexts: contexts}
  end

  defp reply_to_token(state, token, result) do
    case Map.pop(state.pending, token) do
      {nil, _} ->
        {:error, {:unknown_token, token}}

      {{:ask, from}, pending} ->
        state = finish_token(state, token, result)
        GenServer.reply(from, result)
        {:ok, %{state | pending: pending}}

      {{:tell, recipient}, pending} ->
        state = finish_token(state, token, result)

        if recipient do
          send(recipient, {:gen_agent_ensemble, :completion, state.session_name, token, result})
        end

        state =
          Enum.reduce(Map.get(state.waiters, token, %{}), state, fn {mref, _}, acc ->
            remove_waiter(acc, mref, result)
          end)

        {:ok, retain_completed(%{state | pending: pending}, token, result)}
    end
  end

  defp remove_waiter(state, mref, result) do
    case Map.pop(state.waiter_monitors, mref) do
      {nil, _} ->
        state

      {token, monitors} ->
        {{from, timer}, remaining} = Map.pop(Map.fetch!(state.waiters, token), mref)
        if timer, do: Process.cancel_timer(timer)
        Process.demonitor(mref, [:flush])
        if result, do: GenServer.reply(from, result)

        waiters =
          if map_size(remaining) == 0,
            do: Map.delete(state.waiters, token),
            else: Map.put(state.waiters, token, remaining)

        %{state | waiters: waiters, waiter_monitors: monitors}
    end
  end

  defp drop_monitors_for(monitors, agent_name) do
    Map.reject(monitors, fn {mref, name} ->
      if name == agent_name do
        Process.demonitor(mref, [:flush])
        true
      else
        false
      end
    end)
  end

  defp retire_agent(state, name) do
    emit_dropped_dispatches(state, name, :agent_stopped)

    %{
      state
      | agents: Map.delete(state.agents, name),
        monitors: drop_monitors_for(state.monitors, name),
        in_flight: drop_in_flight_for(state.in_flight, name),
        dispatch_contexts: drop_dispatch_contexts_for(state, name)
    }
  end

  # Stop the owned incarnation, never a replacement found by name.
  defp stop_owned_member(state, name, pid) do
    case stop_child(state.agent_supervisor, pid) do
      :ok ->
        {:ok, retire_agent(state, name)}

      {:error, :not_found} ->
        if Process.alive?(pid),
          do: {:error, {:agent_not_running, name}},
          else: {:ok, retire_agent(state, name)}

      {:error, _} = error ->
        error
    end
  end

  defp stop_child(supervisor, pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
  catch
    :exit, _ -> {:error, :agent_stop_failed}
  end

  defp drop_in_flight_for(in_flight, agent_name) do
    Map.reject(in_flight, fn {_ref, {name, _token}} -> name == agent_name end)
  end

  defp drop_dispatch_contexts_for(state, agent_name) do
    Enum.reduce(state.in_flight, state.dispatch_contexts, fn {ref, {name, _token}}, acc ->
      if name == agent_name, do: Map.delete(acc, ref), else: acc
    end)
  end

  defp emit_dropped_dispatches(state, agent, reason_kind) do
    Enum.each(state.in_flight, fn {ref, {name, token}} ->
      if name == agent do
        {started_at, ordinal, _pid, _admission} = Map.fetch!(state.dispatch_contexts, ref)

        emit_dispatch(state, :error, name, token, ref, started_at, ordinal,
          reason_kind: reason_kind
        )
      end
    end)
  end

  defp emit_open_dispatches(state, reason_kind) do
    Enum.each(state.in_flight, fn {ref, {agent, token}} ->
      {started_at, ordinal, _pid, _admission} = Map.fetch!(state.dispatch_contexts, ref)

      emit_dispatch(state, :error, agent, token, ref, started_at, ordinal,
        reason_kind: reason_kind
      )
    end)
  end

  defp emit_unfinished_work(state) do
    emit_open_dispatches(state, :session_stopped)

    Enum.each(state.token_contexts, fn {token, context} ->
      emit(
        :token,
        :error,
        %{duration_ms: elapsed_ms(context.started_at)},
        token_meta(state, token)
        |> Map.put(:outcome, :error)
        |> Map.put(:reason_kind, :session_stopped)
      )
    end)
  end

  # One gate for every outstanding public tell/ask, active or waiting. It runs
  # before a token exists, so a rejection leaves strategy state, children and
  # recipients untouched. The charge is the original prompt's serialized size,
  # taken once here and retained beyond uncertain cancellation until settlement.
  defp charged_count(state), do: map_size(state.pending) + map_size(state.cancellation_leases)

  defp admit(state, kind, prompt) do
    count = charged_count(state)
    bytes = state.pending_prompt_bytes
    incoming = :erlang.external_size(prompt)
    max_count = state.max_pending_prompts
    max_bytes = state.max_pending_prompt_bytes

    limit =
      cond do
        max_count != :infinity and count >= max_count -> :count
        max_bytes != :infinity and incoming > max_bytes - bytes -> :bytes
        true -> nil
      end

    case limit do
      nil ->
        {:ok, incoming}

      limit ->
        emit(
          :admission,
          :rejected,
          %{pending_count: count, pending_bytes: bytes, incoming_bytes: incoming},
          session_meta(state)
          |> Map.merge(%{
            kind: kind,
            outcome: :rejected,
            reason_kind: :overloaded,
            limit: limit,
            max_pending_prompts: max_count,
            max_pending_prompt_bytes: max_bytes
          })
        )

        {:error,
         {:overloaded,
          %{
            queue: :ensemble_prompts,
            limit: limit,
            pending_count: count,
            pending_bytes: bytes,
            incoming_bytes: incoming,
            max_count: max_count,
            max_bytes: max_bytes
          }}}
    end
  end

  defp start_token(state, token, kind, pending, charge) do
    started_at = System.monotonic_time()
    context = %{started_at: started_at, kind: kind, dispatches: 0, charge: charge}

    state = %{
      state
      | pending: Map.put(state.pending, token, pending),
        token_contexts: Map.put(state.token_contexts, token, context),
        pending_prompt_bytes: state.pending_prompt_bytes + charge
    }

    emit(:token, :start, %{system_time: System.system_time()}, token_meta(state, token))
    state
  end

  defp finish_token(state, token, result) do
    context = Map.fetch!(state.token_contexts, token)
    event = if match?({:ok, _}, result), do: :stop, else: :error

    metadata =
      Map.put(token_meta(state, token), :outcome, if(event == :stop, do: :ok, else: :error))

    metadata =
      case result do
        {:error, reason} -> Map.put(metadata, :reason_kind, reason_kind(reason))
        _ -> metadata
      end

    emit(:token, event, %{duration_ms: elapsed_ms(context.started_at)}, metadata)

    # An uncertain cancellation transfers its charge to a minimal lease.
    # Result consumption/eviction must not return that capacity.
    retained? = Map.has_key?(state.cancellation_leases, token)

    %{
      state
      | token_contexts: Map.delete(state.token_contexts, token),
        stream_recipients: Map.delete(state.stream_recipients, token),
        pending_prompt_bytes:
          state.pending_prompt_bytes - if(retained?, do: 0, else: context.charge)
    }
  end

  defp next_dispatch(state, nil), do: {nil, state}

  defp next_dispatch(state, token) do
    context = Map.fetch!(state.token_contexts, token)
    ordinal = context.dispatches
    context = %{context | dispatches: ordinal + 1}
    {ordinal, %{state | token_contexts: Map.put(state.token_contexts, token, context)}}
  end

  defp accept_dispatch(state, ref) do
    case Map.fetch(state.dispatch_contexts, ref) do
      {:ok, {started_at, ordinal, pid, :submitted}} ->
        {agent, token} = Map.fetch!(state.in_flight, ref)
        emit_dispatch(state, :start, agent, token, ref, started_at, ordinal)

        %{
          state
          | dispatch_contexts:
              Map.put(state.dispatch_contexts, ref, {started_at, ordinal, pid, :accepted})
        }

      _ ->
        state
    end
  end

  defp emit_dispatch(state, event, agent, token, ref, started_at, ordinal, extra \\ []) do
    measurements =
      if event == :start,
        do: %{system_time: System.system_time()},
        else: %{duration_ms: elapsed_ms(started_at)}

    emit(
      :dispatch,
      event,
      measurements,
      dispatch_meta(state, agent, token, ref, ordinal)
      |> Map.merge(Map.new(extra))
      |> Map.put(:outcome, dispatch_outcome(event))
    )
  end

  defp dispatch_outcome(:start), do: :pending
  defp dispatch_outcome(:stop), do: :ok
  defp dispatch_outcome(:error), do: :error

  defp session_meta(state),
    do: %{session: state.session_name, strategy: state.strategy_mod}

  defp token_meta(state, token) do
    context = Map.fetch!(state.token_contexts, token)
    Map.merge(session_meta(state), %{token: token, kind: context.kind})
  end

  defp dispatch_meta(state, agent, token, ref, ordinal) do
    Map.merge(session_meta(state), %{
      token: token,
      agent: agent,
      member_name: member_name(state, agent),
      ref: ref,
      ordinal: ordinal
    })
  end

  defp emit(scope, event, measurements, metadata),
    do: :telemetry.execute([:gen_agent_ensemble, scope, event], measurements, metadata)

  defp elapsed_ms(started_at),
    do: System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

  defp reason_kind(:cancelled), do: :cancelled
  defp reason_kind(:normal), do: :normal
  defp reason_kind(:timeout), do: :timeout
  defp reason_kind(:interrupted), do: :interrupted
  defp reason_kind(:halted), do: :halted
  defp reason_kind({:overloaded, _}), do: :overloaded
  defp reason_kind({:halted, _}), do: :halted
  defp reason_kind({:dispatch_rejected, _, _}), do: :dispatch_rejected
  defp reason_kind({:worker_down, _, _}), do: :worker_down
  defp reason_kind({:unknown_agent, _}), do: :unknown_agent
  defp reason_kind({:agent_not_running, _}), do: :agent_not_running
  defp reason_kind({:dispatch_exit, _}), do: :dispatch_exit
  defp reason_kind(:no_agent_specified), do: :no_agent_specified
  defp reason_kind(:invalid_operation), do: :invalid_operation
  defp reason_kind(:agent_stop_failed), do: :agent_stop_failed
  defp reason_kind({:invalid_start_spec, _}), do: :invalid_start_spec
  defp reason_kind({:start_exception, _}), do: :start_exception
  defp reason_kind({:duplicate_sub_agent, _}), do: :duplicate_sub_agent
  defp reason_kind({:member_name_conflict, _}), do: :member_name_conflict
  defp reason_kind(_reason), do: :backend_or_strategy_error

  # The offending field or exception kind of a contained start failure. Both
  # come from fixed sets, so rendering them never exposes caller data.
  @start_spec_fields [:shape, :name, :module, :options, :backend, :child_spec]

  defp reason_detail({:invalid_start_spec, field}) when field in @start_spec_fields do
    " (#{field})"
  end

  defp reason_detail({:start_exception, kind}) when kind in [:error, :throw, :exit] do
    " (#{kind})"
  end

  defp reason_detail(_reason), do: ""

  # --- helpers ---

  defp call_strategy(mod, fun, args) do
    {:ok, ops, strategy_state} = apply(mod, fun, args)
    {ops, strategy_state}
  end

  defp member_name(%__MODULE__{session_name: session}, bare_name),
    do: GenAgentEnsemble.member_name(session, bare_name)

  # Dispatch submits to the captured owned PID without a second lookup.
  # Named forwarding still has a lookup/send race (the separate #490 fence).
  defp owned_member(state, name) do
    case Map.fetch(state.agents, name) do
      {:ok, pid} ->
        if GenAgent.whereis(member_name(state, name)) === pid,
          do: :ok,
          else: {:error, {:agent_not_running, name}}

      :error ->
        {:error, {:agent_not_running, name}}
    end
  end

  # Best-effort cleanup of old scalar handler IDs only. Never invoke a user's
  # String.Chars implementation or coerce the actual Registry session identity.
  defp detach_legacy_handler(session) do
    suffix =
      cond do
        is_binary(session) -> session
        is_atom(session) -> Atom.to_string(session)
        is_integer(session) -> Integer.to_string(session)
        is_float(session) -> Float.to_string(session)
        true -> nil
      end

    if suffix, do: :telemetry.detach("gen_agent_ensemble:" <> suffix)
    :ok
  catch
    _, _ -> :ok
  end

  defp pop_completed(state, token) do
    {result, rest} = Map.pop(state.completed, token)
    order = :queue.filter(&(&1 != token), state.completed_order)
    {result, %{state | completed: rest, completed_order: order}}
  end

  defp retain_completed(%{max_completed_results: 0} = state, _token, _result), do: state

  defp retain_completed(state, token, result) do
    state = %{
      state
      | completed: Map.put(state.completed, token, result),
        completed_order: :queue.in(token, state.completed_order)
    }

    if state.max_completed_results != :infinity and
         map_size(state.completed) > state.max_completed_results do
      {{:value, oldest}, order} = :queue.out(state.completed_order)
      %{state | completed: Map.delete(state.completed, oldest), completed_order: order}
    else
      state
    end
  end

  defp active_dispatch?(_state, nil), do: true
  defp active_dispatch?(state, token), do: Map.has_key?(state.pending, token)

  defp mint_token do
    "tok-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp catch_exit(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end
end
