defmodule GenAgent.Structured.Session do
  @moduledoc false
  use GenServer
  alias GenAgent.Structured.{Contract, Error, Files, Result, Worker}

  # Monitor ownership from init, before provider preparation. Starting unlinked
  # makes init failures ordinary return values and avoids a post-start link race.
  def start(contract, settings), do: GenServer.start(__MODULE__, {contract, settings, self()})

  @impl true
  def init({contract, settings, owner}) do
    Process.flag(:trap_exit, true)
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, agent_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %{
      owner_monitor: Process.monitor(owner),
      contract: contract,
      profile: settings.profile,
      provider: settings.provider,
      task_supervisor: task_supervisor,
      agent_supervisor: agent_supervisor,
      name: {__MODULE__, self(), make_ref()},
      agent: nil,
      agent_monitor: nil,
      files_monitor: nil,
      workspace: nil,
      pending: nil
    }

    case prepare(state, settings) do
      {:ok, next} ->
        {:ok, next}

      {:error, reason, failed_state} ->
        cleanup(failed_state)
        {:stop, %Error{stage: :provider, reason: reason, profile: state.profile}}
    end
  end

  @impl true
  def handle_call({:request, _input}, _from, %{pending: pending} = state)
      when not is_nil(pending),
      do:
        {:reply, {:error, %Error{stage: :lifecycle, reason: :busy, profile: state.profile}},
         state}

  def handle_call({:request, input}, from, state) do
    with {:ok, prompt} <- Contract.render(state.contract, input),
         {:ok, ref} <-
           safely(fn ->
             GenAgent.tell_with_completion(state.name, prompt, self(), 5000, on_halt: :fail)
           end) do
      pending = %{
        from: from,
        ref: ref,
        id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
        caller_monitor: Process.monitor(elem(from, 0))
      }

      {:noreply, %{state | pending: pending}}
    else
      {:error, %Error{} = error} ->
        {:reply, {:error, %{error | profile: state.profile}}, state}

      {:error, reason} ->
        {:reply, {:error, %Error{stage: :provider, reason: reason, profile: state.profile}},
         state}
    end
  end

  @impl true
  def handle_info(
        {:gen_agent, :completion, name, ref, outcome},
        %{name: name, pending: %{ref: ref} = pending} = state
      ) do
    reply = result(state, pending.id, outcome)
    GenServer.reply(pending.from, reply)
    Process.demonitor(pending.caller_monitor, [:flush])
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state),
    do: {:stop, :normal, reply_pending(state, :owner_down)}

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{agent_monitor: monitor} = state),
    do: {:stop, :normal, reply_pending(state, {:agent_down, reason})}

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{files_monitor: monitor} = state),
    do: {:stop, :normal, reply_pending(state, {:schema_file_owner_down, reason})}

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{pending: %{caller_monitor: monitor}} = state
      ),
      do: {:stop, :normal, %{state | pending: nil}}

  def handle_info({:EXIT, pid, reason}, state)
      when pid == state.task_supervisor or pid == state.agent_supervisor,
      do: {:stop, :normal, reply_pending(state, {:supervisor_down, reason})}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    reply_pending(state, :closed)
    cleanup(state)
  end

  defp prepare(state, settings) do
    case safely(fn -> allocate_directory(state.contract) end) do
      {:ok, directory, files_owner} ->
        state = %{
          state
          | workspace: directory,
            files_monitor: if(files_owner, do: Process.monitor(files_owner), else: nil)
        }

        prepare_agent(state, settings, directory)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp prepare_agent(state, settings, directory) do
    with {:ok, backend_opts} <-
           safely(fn ->
             state.provider.prepare(
               state.contract.output_schema,
               settings.backend_opts,
               directory
             )
           end),
         {:ok, pid} <- start_agent(state, backend_opts, settings.timeout_ms) do
      {:ok, %{state | agent: pid, agent_monitor: Process.monitor(pid)}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp allocate_directory(%Contract{output_schema: nil}), do: {:ok, nil, nil}
  defp allocate_directory(_contract), do: Files.allocate(self())

  defp start_agent(state, backend_opts, timeout_ms) do
    opts = [
      name: state.name,
      backend: state.provider.backend(),
      backend_opts: backend_opts,
      task_supervisor: state.task_supervisor,
      watchdog_ms: timeout_ms,
      max_tell_results: 1
    ]

    safely(fn ->
      DynamicSupervisor.start_child(
        state.agent_supervisor,
        Supervisor.child_spec({Worker, opts}, restart: :temporary)
      )
    end)
  end

  defp result(state, id, {:ok, response}) do
    with {:ok, output} <-
           safely(fn -> state.provider.extract(response, state.contract.output_schema) end),
         :ok <- Contract.validate_output(state.contract, output) do
      {:ok, %Result{request_id: id, output: output, response: response, profile: state.profile}}
    else
      {:error, %Error{} = error} ->
        {:error, %{error | request_id: id, response: response, profile: state.profile}}

      {:error, reason} ->
        {:error,
         %Error{
           stage: :output,
           reason: reason,
           request_id: id,
           response: response,
           profile: state.profile
         }}
    end
  end

  defp result(state, id, {:error, reason}),
    do: {:error, %Error{stage: :provider, reason: reason, request_id: id, profile: state.profile}}

  defp reply_pending(%{pending: nil} = state, _reason), do: state

  defp reply_pending(%{pending: pending} = state, reason) do
    GenServer.reply(
      pending.from,
      {:error,
       %Error{stage: :lifecycle, reason: reason, request_id: pending.id, profile: state.profile}}
    )

    Process.demonitor(pending.caller_monitor, [:flush])
    %{state | pending: nil}
  end

  defp cleanup(state) do
    for supervisor <- [state.agent_supervisor, state.task_supervisor] do
      safely(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)
    end

    safely(fn -> Files.release(self()) end)
    if state.workspace, do: File.rm_rf(state.workspace)
    :ok
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, error}}
  catch
    :exit, reason -> {:error, {:call_exit, reason}}
  end
end
