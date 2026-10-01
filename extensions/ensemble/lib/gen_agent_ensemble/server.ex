defmodule GenAgentEnsemble.Server do
  @moduledoc false

  use GenServer
  require Logger

  defstruct [
    :strategy_mod,
    :strategy_state,
    :session_name,
    :session_started_at,
    :halted,
    :agent_tree,
    :task_supervisor,
    :agent_supervisor,
    # agents we own, MapSet of agent names
    :agents,
    # monitor refs, %{mref => agent_name}
    :monitors,
    # tokens awaiting reply, %{token => {:tell, nil} | {:ask, from}}
    :pending,
    # %{token => %{started_at: integer, kind: :ask | :tell, dispatches: integer}}
    :token_contexts,
    # completed tell results, %{token => {:ok, response} | {:error, reason}}
    :completed,
    # %{gen_agent_ref => {agent_name, run_token}}
    :in_flight,
    # %{gen_agent_ref => {started_at, ordinal}}
    :dispatch_contexts
  ]

  # --- public API (called via GenAgentEnsemble shim) ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    case GenServer.start(__MODULE__, opts, name: via(name)) do
      {:ok, pid} = result ->
        Process.link(pid)
        result

      error ->
        error
    end
  end

  def tell(name, prompt, opts \\ []), do: GenServer.call(via(name), {:tell, prompt, opts})

  def ask(name, prompt, opts \\ []) do
    {timeout, strategy_opts} = Keyword.pop(opts, :timeout, 30_000)
    GenServer.call(via(name), {:ask, prompt, strategy_opts}, timeout)
  end

  def poll(name, token), do: GenServer.call(via(name), {:poll, token})
  def inbox(name), do: GenServer.call(via(name), :inbox)
  def notify(name, event), do: GenServer.cast(via(name), {:notify, event})
  def status(name), do: GenServer.call(via(name), :status)
  def stop(name), do: GenServer.stop(via(name), :normal, 10_000)

  defp via(name), do: {:via, Registry, {GenAgentEnsemble.Registry, name}}

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    strategy_mod = Keyword.fetch!(opts, :strategy)
    strategy_opts = Keyword.get(opts, :opts, [])
    session_name = Keyword.fetch!(opts, :name)

    with {:ok, strategy_state, start_specs} <- strategy_mod.init(strategy_opts),
         {:ok, agent_tree} <- GenAgentEnsemble.AgentTree.start_link(session_name) do
      # Older releases left this handler behind after abrupt server death.
      # Request-scoped completions now replace the telemetry bridge entirely.
      _ = :telemetry.detach("gen_agent_ensemble:#{session_name}")

      {task_supervisor, agent_supervisor} =
        GenAgentEnsemble.AgentTree.supervisors(agent_tree)

      state = %__MODULE__{
        strategy_mod: strategy_mod,
        strategy_state: strategy_state,
        session_name: session_name,
        session_started_at: nil,
        halted: false,
        agent_tree: agent_tree,
        task_supervisor: task_supervisor,
        agent_supervisor: agent_supervisor,
        agents: MapSet.new(),
        monitors: %{},
        pending: %{},
        token_contexts: %{},
        completed: %{},
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

  defp apply_start_specs(state, specs) do
    Enum.reduce_while(specs, {:ok, state}, fn spec, {:ok, acc} ->
      case apply_op({:start, spec}, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def handle_call({:tell, prompt, opts}, _from, state) do
    token = mint_token()
    state = start_token(state, token, :tell, {:tell, nil})

    {ops, strategy_state} =
      call_strategy(state.strategy_mod, :handle_tell, [prompt, opts, token, state.strategy_state])

    state = %{state | strategy_state: strategy_state} |> apply_ops(ops)
    {:reply, {:ok, token}, state}
  end

  def handle_call({:ask, prompt, opts}, from, state) do
    token = mint_token()
    state = start_token(state, token, :ask, {:ask, from})

    {ops, strategy_state} =
      call_strategy(state.strategy_mod, :handle_ask, [prompt, opts, token, state.strategy_state])

    state = %{state | strategy_state: strategy_state} |> apply_ops(ops)
    {:noreply, state}
  end

  def handle_call({:poll, token}, _from, state) do
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

  def handle_call(:inbox, _from, state) do
    entries =
      Enum.map(state.completed, fn {token, result} -> {token, result} end)

    {:reply, {:ok, entries}, %{state | completed: %{}}}
  end

  def handle_call(:status, _from, state) do
    base = %{
      session: state.session_name,
      strategy: state.strategy_mod,
      agents: MapSet.to_list(state.agents),
      pending_tokens: Map.keys(state.pending),
      in_flight: map_size(state.in_flight)
    }

    extra =
      if function_exported?(state.strategy_mod, :handle_status, 1) do
        state.strategy_mod.handle_status(state.strategy_state)
      else
        %{}
      end

    {:reply, {:ok, Map.merge(base, extra)}, state}
  end

  @impl true
  def handle_cast({:notify, event}, state) do
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

  @impl true
  def handle_info({:gen_agent, :completion, _ns_agent, ref, {:ok, response}}, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _} ->
        {:noreply, state}

      {{bare_agent, token}, rest} ->
        {{started_at, ordinal}, contexts} = Map.pop(state.dispatch_contexts, ref)
        state = %{state | in_flight: rest, dispatch_contexts: contexts}
        emit_dispatch(state, :stop, bare_agent, token, ref, started_at, ordinal)
        {:noreply, handle_prompt_response(state, bare_agent, token, response)}
    end
  end

  def handle_info({:gen_agent, :completion, _ns_agent, ref, {:error, reason}}, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _} ->
        {:noreply, state}

      {{bare_agent, token}, rest} ->
        {{started_at, ordinal}, contexts} = Map.pop(state.dispatch_contexts, ref)
        state = %{state | in_flight: rest, dispatch_contexts: contexts}

        emit_dispatch(state, :error, bare_agent, token, ref, started_at, ordinal,
          reason_kind: reason_kind(reason)
        )

        {:noreply, handle_prompt_error(state, bare_agent, token, reason)}
    end
  end

  def handle_info({:DOWN, mref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, mref) do
      {nil, _} ->
        {:noreply, state}

      {agent, monitors} ->
        emit_dropped_dispatches(state, agent, :agent_down)

        state = %{
          state
          | monitors: monitors,
            agents: MapSet.delete(state.agents, agent),
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
            state
          end

        {:noreply, state}
    end
  end

  def handle_info({:halt_session, reason}, state) do
    state = %{state | halted: true}

    emit(
      :session,
      :halt,
      %{duration_ms: elapsed_ms(state.session_started_at)},
      session_meta(state)
      |> Map.put(:outcome, :halted)
      |> Map.put(:reason_kind, :strategy_halt)
    )

    # Close any still-pending tokens with the halt reason so callers unblock.
    pending_tokens = Map.keys(state.pending)

    state =
      Enum.reduce(pending_tokens, state, fn token, acc ->
        case apply_op({:reply_error, token, {:halted, reason}}, acc) do
          {:ok, acc2} -> acc2
          _ -> acc
        end
      end)

    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
          "[gen_agent_ensemble] agent #{bare_agent} turn errored (unhandled): #{inspect(reason)}"
        )

        state
    end
  end

  @impl true
  def terminate(reason, state) do
    emit_unfinished_work(state)
    outcome = if state.halted, do: :halted, else: if(reason == :normal, do: :ok, else: :error)

    emit(
      :session,
      :stop,
      %{duration_ms: elapsed_ms(state.session_started_at)},
      session_meta(state)
      |> Map.put(:outcome, outcome)
      |> Map.put(:reason_kind, reason_kind(reason))
    )

    _ = catch_exit(fn -> Supervisor.stop(state.agent_tree) end)
    :ok
  end

  # --- op execution ---

  defp apply_ops(state, ops) do
    Enum.reduce_while(ops, state, &apply_op_safe/2)
  end

  defp apply_op_safe(op, state) do
    case apply_op(op, state) do
      {:ok, next} ->
        {:cont, next}

      # A previous op may have already closed this run (for example, a
      # rejected member of a Consensus fanout).
      {:error, {:unknown_token, _}} when tuple_size(op) == 4 and elem(op, 0) == :dispatch ->
        {:cont, state}

      {:error, reason} ->
        Logger.warning("[gen_agent_ensemble] op #{inspect(op)} failed: #{inspect(reason)}")
        handle_op_failure(op, reason, state)
    end
  end

  # Stop the rest of this op batch after a rejected scoped dispatch. In
  # particular, a Supervisor fanout may contain starts after it.
  defp handle_op_failure({:dispatch, agent, _prompt, token}, reason, state) do
    {:halt, reject_dispatch(state, agent, token, reason)}
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

  defp apply_op({:start, {name, module, opts}}, state) do
    agent_opts =
      opts
      |> Keyword.put(:name, namespaced(state, name))
      |> Keyword.put(:task_supervisor, state.task_supervisor)

    case DynamicSupervisor.start_child(
           state.agent_supervisor,
           GenAgent.child_spec(module, agent_opts)
         ) do
      {:ok, pid} ->
        mref = Process.monitor(pid)

        {:ok,
         %{
           state
           | agents: MapSet.put(state.agents, name),
             monitors: Map.put(state.monitors, mref, name)
         }}

      {:error, {:already_started, _pid}} ->
        # Namespacing by session name means the only way to hit this is a
        # duplicate sub-agent spec inside a single ensemble. Fail loud.
        {:error, {:duplicate_sub_agent, name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_op({:stop, name}, state) do
    emit_dropped_dispatches(state, name, :agent_stopped)
    _ = catch_exit(fn -> GenAgent.stop(namespaced(state, name), state.agent_supervisor) end)
    monitors = drop_monitors_for(state.monitors, name)

    {:ok,
     %{
       state
       | agents: MapSet.delete(state.agents, name),
         monitors: monitors,
         in_flight: drop_in_flight_for(state.in_flight, name),
         dispatch_contexts: drop_dispatch_contexts_for(state, name)
     }}
  end

  defp apply_op({:dispatch, name, prompt, token}, state) do
    if Map.has_key?(state.pending, token) do
      dispatch(state, name, prompt, token)
    else
      {:error, {:unknown_token, token}}
    end
  end

  # Existing external strategies may still use the unscoped operation.
  defp apply_op({:dispatch, name, prompt}, state), do: dispatch(state, name, prompt, nil)

  defp apply_op({:reply, token, response}, state) do
    reply_to_token(state, token, {:ok, response})
  end

  defp apply_op({:reply_error, token, reason}, state) do
    reply_to_token(state, token, {:error, reason})
  end

  defp apply_op({:forward, name, event}, state) do
    _ = catch_exit(fn -> GenAgent.notify(namespaced(state, name), event) end)
    {:ok, state}
  end

  defp apply_op({:halt, reason}, state) do
    send(self(), {:halt_session, reason})
    {:ok, state}
  end

  defp dispatch(state, name, prompt, token) do
    case GenAgent.tell_with_completion(namespaced(state, name), prompt, self()) do
      {:ok, ref} ->
        {ordinal, state} = next_dispatch(state, token)
        started_at = System.monotonic_time()
        emit_dispatch(state, :start, name, token, ref, started_at, ordinal)

        {:ok,
         %{
           state
           | in_flight: Map.put(state.in_flight, ref, {name, token}),
             dispatch_contexts: Map.put(state.dispatch_contexts, ref, {started_at, ordinal})
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

  defp reply_to_token(state, token, result) do
    case Map.pop(state.pending, token) do
      {nil, _} ->
        {:error, {:unknown_token, token}}

      {{:ask, from}, pending} ->
        state = finish_token(state, token, result)
        GenServer.reply(from, result)
        {:ok, %{state | pending: pending}}

      {{:tell, _}, pending} ->
        state = finish_token(state, token, result)
        completed = Map.put(state.completed, token, result)
        {:ok, %{state | pending: pending, completed: completed}}
    end
  end

  defp drop_monitors_for(monitors, agent_name) do
    for {mref, name} <- monitors, name != agent_name, into: %{} do
      {mref, name}
    end
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
        {started_at, ordinal} = Map.fetch!(state.dispatch_contexts, ref)

        emit_dispatch(state, :error, name, token, ref, started_at, ordinal,
          reason_kind: reason_kind
        )
      end
    end)
  end

  defp emit_unfinished_work(state) do
    Enum.each(state.in_flight, fn {ref, {agent, token}} ->
      {started_at, ordinal} = Map.fetch!(state.dispatch_contexts, ref)

      emit_dispatch(state, :error, agent, token, ref, started_at, ordinal,
        reason_kind: :session_stopped
      )
    end)

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

  defp start_token(state, token, kind, pending) do
    started_at = System.monotonic_time()
    context = %{started_at: started_at, kind: kind, dispatches: 0}

    state = %{
      state
      | pending: Map.put(state.pending, token, pending),
        token_contexts: Map.put(state.token_contexts, token, context)
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
    %{state | token_contexts: Map.delete(state.token_contexts, token)}
  end

  defp next_dispatch(state, nil), do: {nil, state}

  defp next_dispatch(state, token) do
    context = Map.fetch!(state.token_contexts, token)
    ordinal = context.dispatches
    context = %{context | dispatches: ordinal + 1}
    {ordinal, %{state | token_contexts: Map.put(state.token_contexts, token, context)}}
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
    Map.merge(session_meta(state), %{token: token, agent: agent, ref: ref, ordinal: ordinal})
  end

  defp emit(scope, event, measurements, metadata),
    do: :telemetry.execute([:gen_agent_ensemble, scope, event], measurements, metadata)

  defp elapsed_ms(started_at),
    do: System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

  defp reason_kind(:normal), do: :normal
  defp reason_kind(:timeout), do: :timeout
  defp reason_kind(:interrupted), do: :interrupted
  defp reason_kind({:overloaded, _}), do: :overloaded
  defp reason_kind({:halted, _}), do: :halted
  defp reason_kind({:dispatch_rejected, _, _}), do: :dispatch_rejected
  defp reason_kind({:worker_down, _, _}), do: :worker_down
  defp reason_kind({:unknown_agent, _}), do: :unknown_agent
  defp reason_kind(:no_agent_specified), do: :no_agent_specified
  defp reason_kind(_reason), do: :backend_or_strategy_error

  # --- helpers ---

  defp call_strategy(mod, fun, args) do
    {:ok, ops, strategy_state} = apply(mod, fun, args)
    {ops, strategy_state}
  end

  # Internal name used when registering a sub-agent with GenAgent.Registry.
  # Strategy code always sees the bare name; the Server translates when
  # calling GenAgent.{tell_with_completion,stop,notify} and ignores the
  # namespaced name in completion messages (it looks up by ref instead).
  defp namespaced(%__MODULE__{session_name: session}, bare_name) do
    "#{session}/#{bare_name}"
  end

  defp pop_completed(state, token) do
    {result, rest} = Map.pop(state.completed, token)
    {result, %{state | completed: rest}}
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
