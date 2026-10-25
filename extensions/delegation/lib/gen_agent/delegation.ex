defmodule GenAgent.Delegation do
  @moduledoc """
  Local task bookkeeping over persistent GenAgent processes.

  Each conversation owns one agent. Each turn gets a new public task ID.
  Private task records support repeatable reads and successful conversation
  resumption after restart. At capacity new work is refused. No automatic replay
  or external subprocess cleanup guarantee is provided. Each state directory has
  one live owner; use separate directories for independent hosts.
  """
  use GenServer
  alias GenAgent.Delegation.{Options, Worker, Store, ProfileCatalog}
  alias GenAgent.Structured.{Contract, Files, Providers}
  @terminal ~w(completed failed cancelled interrupted)

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  for operation <- [
        :spawn_agent,
        :continue_agent,
        :cancel_agent,
        :list_agents,
        :wait_agents,
        :register_profile,
        :get_profile,
        :list_profiles,
        :delete_profile
      ] do
    def unquote(operation)(args, server \\ __MODULE__),
      do: GenServer.call(server, {unquote(operation), args}, :infinity)
  end

  # Keep the original spike aliases for local callers; MCP uses Tosi task names.
  def spawn_task(args, server \\ __MODULE__), do: spawn_agent(args, server)
  def continue_task(args, server \\ __MODULE__), do: continue_agent(args, server)
  def cancel_task(args, server \\ __MODULE__), do: cancel_agent(args, server)
  def list_tasks(args \\ %{}, server \\ __MODULE__), do: list_agents(args, server)
  def wait_tasks(args, server \\ __MODULE__), do: wait_agents(args, server)

  @doc false
  def server_info(server \\ __MODULE__), do: GenServer.call(server, :server_info, 5_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, tasks} = Task.Supervisor.start_link()
    {:ok, agents} = DynamicSupervisor.start_link(strategy: :one_for_one)

    with {:ok, store, restored, warnings} <- restore(Keyword.get(opts, :state_dir)),
         {:ok, profiles} <- restore_profiles(store) do
      {:ok,
       %{
         task_supervisor: tasks,
         agent_supervisor: agents,
         store: store,
         profiles: profiles,
         store_warnings: warnings,
         persistence_error: nil,
         files_monitor: Process.monitor(GenAgent.Structured.Files),
         tasks: restored,
         latest: latest(restored),
         default_backend: Keyword.get(opts, :default_backend, "claude"),
         waiters: %{},
         max_running: Keyword.get(opts, :max_running, 3),
         max_tasks: Keyword.get(opts, :max_tasks, 1024),
         backends:
           Keyword.get(opts, :backends, %{
             "echo" => GenAgent.Delegation.Echo,
             "claude" => GenAgent.Backends.Claude,
             "codex" => GenAgent.Backends.Codex
           }),
         backend_options: Keyword.get(opts, :backend_options, %{})
       }}
    else
      {:error, reason} ->
        Supervisor.stop(agents)
        Supervisor.stop(tasks)
        {:stop, {:state_store, reason}}
    end
  end

  @impl true
  def handle_call(:server_info, _from, state) do
    {:reply,
     %{
       "state_directory" => if(state.store, do: state.store.directory),
       "default_backend" => state.default_backend,
       "max_running" => state.max_running,
       "max_tasks" => state.max_tasks
     }, state}
  end

  def handle_call({:spawn_agent, args}, _from, state) do
    with {:ok, expanded, profile} <- profile_request(state, args),
         {:ok, spec} <-
           Options.spawn(expanded, %{
             default_backend: state.default_backend,
             backends: Map.keys(state.backends)
           }),
         spec = attach_profile(spec, profile),
         :ok <- capacity(state),
         {:ok, runtime} <- start_conversation(state, spec, id(), nil) do
      case submit(state, spec, runtime, nil) do
        {:ok, public, next} ->
          {:reply, {:ok, public}, next}

        {:error, reason} ->
          stop_conversation(state, runtime)
          {:reply, error("start_failed", reason), state}
      end
    else
      failure -> {:reply, failure, state}
    end
  end

  def handle_call({:continue_agent, args}, _from, state) do
    with :ok <- exact_keys(args, ~w(task_id message input)),
         {:ok, task} <- fetch(state, args["task_id"]),
         {:ok, spec} <- continuation_spec(task, args),
         true <-
           task.public["status"] == "completed" ||
             error("not_completed", "only successful tasks can continue"),
         true <-
           state.latest[task.public["conversation_id"]] == args["task_id"] ||
             error("stale_task", "continue the latest task"),
         :ok <- capacity(state),
         {:ok, runtime} <- ensure_conversation(state, task) do
      case submit(state, spec, runtime, args["task_id"]) do
        {:ok, public, next} -> {:reply, {:ok, public}, next}
        {:error, reason} -> {:reply, error("submit_failed", reason), state}
      end
    else
      failure -> {:reply, failure, state}
    end
  end

  def handle_call({:register_profile, args}, _from, state) do
    with {:ok, entry, profiles} <- ProfileCatalog.register(state.profiles, args),
         :ok <- persist_profiles(state.store, profiles) do
      {:reply, {:ok, ProfileCatalog.definition(entry)}, %{state | profiles: profiles}}
    else
      failure -> {:reply, failure, state}
    end
  end

  def handle_call({:get_profile, args}, _from, state) do
    with :ok <- exact_keys(args, ["name"]),
         {:ok, entry} <- ProfileCatalog.get(state.profiles, args["name"]) do
      {:reply, {:ok, ProfileCatalog.definition(entry)}, state}
    else
      failure -> {:reply, failure, state}
    end
  end

  def handle_call({:list_profiles, args}, _from, state) do
    with :ok <- exact_keys(args, []) do
      {:reply, {:ok, %{"profiles" => ProfileCatalog.list(state.profiles)}}, state}
    else
      failure -> {:reply, failure, state}
    end
  end

  def handle_call({:delete_profile, args}, _from, state) do
    with :ok <- exact_keys(args, ["name"]),
         {:ok, profiles} <- ProfileCatalog.delete(state.profiles, args["name"]),
         :ok <- persist_profiles(state.store, profiles) do
      {:reply, {:ok, %{"name" => args["name"], "deleted" => true}}, %{state | profiles: profiles}}
    else
      failure -> {:reply, failure, state}
    end
  end

  def handle_call({:cancel_agent, args}, _from, state) do
    with :ok <- exact_keys(args, ["task_id"]), {:ok, task} <- fetch(state, args["task_id"]) do
      next =
        if task.public["status"] == "running",
          do: cancel(state, args["task_id"], "cancelled"),
          else: state

      {:reply, {:ok, next.tasks[args["task_id"]].public}, wake(next)}
    else
      failure -> {:reply, failure, state}
    end
  end

  def handle_call({:list_agents, args}, _from, state) do
    with :ok <- exact_keys(args, ~w(limit status since full_result)),
         limit = Map.get(args, "limit", 50),
         true <-
           (is_integer(limit) and limit in 1..10_000) || Options.error("limit must be 1..10000"),
         true <-
           (is_nil(args["since"]) or (is_integer(args["since"]) and args["since"] >= 0)) ||
             Options.error("since must be a nonnegative Unix millisecond timestamp"),
         true <-
           is_boolean(Map.get(args, "full_result", false)) ||
             Options.error("full_result must be boolean"),
         true <-
           args["status"] in [nil, "running", "cancelling" | @terminal] ||
             Options.error("invalid status") do
      tasks =
        state.tasks
        |> Map.values()
        |> Enum.map(& &1.public)
        |> Enum.filter(&(is_nil(args["status"]) or &1["status"] == args["status"]))
        |> Enum.filter(&(is_nil(args["since"]) or &1["started_at_ms"] >= args["since"]))
        |> Enum.sort_by(& &1["started_at_ms"], :desc)
        |> Enum.take(limit)
        |> Enum.map(fn task ->
          if args["full_result"] == true, do: task, else: summary(task)
        end)

      {:reply, {:ok, %{"tasks" => tasks, "warnings" => state.store_warnings}}, state}
    else
      failure -> {:reply, failure, state}
    end
  end

  def handle_call({:wait_agents, args}, from, state) do
    with :ok <- exact_keys(args, ~w(task_ids timeout_ms)),
         ids = args["task_ids"],
         true <-
           (is_list(ids) and length(ids) in 1..32 and Enum.all?(ids, &is_binary/1)) ||
             Options.error("task_ids must contain 1..32 IDs"),
         timeout = Map.get(args, "timeout_ms", 30_000),
         true <-
           (is_integer(timeout) and timeout in 0..55_000) ||
             Options.error("timeout_ms must be 0..55000") do
      if ready?(state, ids) or timeout == 0 do
        {:reply, {:ok, snapshot(state, ids, not ready?(state, ids))}, state}
      else
        if map_size(state.waiters) >= 64 do
          {:reply, error("capacity", "too many waiting callers"), state}
        else
          key = make_ref()

          waiter = %{
            from: from,
            ids: ids,
            monitor: Process.monitor(elem(from, 0)),
            timer: Process.send_after(self(), {:wait_timeout, key}, timeout)
          }

          {:noreply, put_in(state.waiters[key], waiter)}
        end
      end
    else
      failure -> {:reply, failure, state}
    end
  end

  @impl true
  def handle_info({:gen_agent, :event, name, ref, event}, state) do
    case Enum.find(state.tasks, fn {_, t} ->
           t.name == name and t.ref == ref and t.public["status"] == "running"
         end) do
      {id, task} ->
        public =
          task.public
          |> Map.update("event_count", 1, &(&1 + 1))
          |> Map.put("last_event", Atom.to_string(event.kind))
          |> Map.put("last_activity_at_ms", System.system_time(:millisecond))

        {:noreply, put_in(state.tasks[id].public, public)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:delegation_checkpoint, name, session_id}, state) do
    case Enum.find(state.tasks, fn {_, t} ->
           t.name == name and state.latest[t.public["conversation_id"]] == t.public["task_id"]
         end) do
      {id, _} ->
        {:noreply,
         state |> put_in([:tasks, id, :public, "provider_session_id"], session_id) |> persist(id)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _, reason}, %{files_monitor: monitor} = state),
    do: {:stop, {:schema_file_owner_down, reason}, state}

  def handle_info({port, {:exit_status, reason}}, %{store: %Store{keeper: port}} = state),
    do: {:stop, {:state_store_lock_lost, reason}, state}

  def handle_info({:gen_agent, :completion, name, ref, outcome}, state) do
    case Enum.find(state.tasks, fn {_id, task} ->
           task.name == name and task.ref == ref and task.public["status"] == "running"
         end) do
      {id, _} -> {:noreply, state |> finish(id, outcome) |> wake()}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:deadline, id}, state) do
    if state.tasks[id].public["status"] == "running",
      do: {:noreply, state |> cancel(id, "timeout") |> wake()},
      else: {:noreply, state}
  end

  def handle_info({:wait_timeout, key}, state) do
    case Map.pop(state.waiters, key) do
      {nil, _} ->
        {:noreply, state}

      {waiter, rest} ->
        Process.demonitor(waiter.monitor, [:flush])

        GenServer.reply(
          waiter.from,
          {:ok, snapshot(state, waiter.ids, not ready?(state, waiter.ids))}
        )

        {:noreply, %{state | waiters: rest}}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    state =
      Enum.reduce(state.tasks, state, fn {id, task}, acc ->
        if task.monitor == monitor and task.public["status"] == "running",
          do: finish(acc, id, {:error, {:agent_down, reason}}),
          else: acc
      end)

    waiters =
      Enum.reject(state.waiters, fn {_key, waiter} ->
        if waiter.monitor == monitor, do: Process.cancel_timer(waiter.timer)
        waiter.monitor == monitor
      end)
      |> Map.new()

    {:noreply, wake(%{state | waiters: waiters})}
  end

  def handle_info({:EXIT, pid, reason}, state)
      when pid == state.agent_supervisor or pid == state.task_supervisor,
      do: {:stop, {:supervisor_down, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for pid <- [state.agent_supervisor, state.task_supervisor],
        Process.alive?(pid),
        do: Supervisor.stop(pid)

    if state.store, do: Store.close(state.store)
    if Process.whereis(Files), do: Files.release(self())
    :ok
  end

  defp profile_request(state, args) when is_map(args) do
    if is_nil(args["profile"]) do
      if Map.has_key?(args, "input"),
        do: Options.error("input requires a named profile"),
        else: {:ok, Map.delete(args, "profile"), nil}
    else
      with true <- Map.has_key?(args, "input") || Options.error("profile tasks require input"),
           false <- Map.has_key?(args, "task") or Map.has_key?(args, "output_schema"),
           {:ok, entry} <- ProfileCatalog.get(state.profiles, args["profile"]),
           {:ok, prompt} <- ProfileCatalog.render(entry, args["input"]) do
        expanded =
          args
          |> Map.drop(~w(profile input))
          |> Map.put("task", prompt)
          |> Map.put("output_schema", entry.snapshot["output_schema"])

        {:ok, expanded, entry}
      else
        true -> Options.error("profile tasks cannot override task or output_schema")
        failure -> failure
      end
    end
  end

  defp profile_request(_, _), do: Options.error("arguments must be an object")

  defp attach_profile(spec, nil), do: spec

  defp attach_profile(spec, entry),
    do: Map.put(spec, "profile_snapshot", ProfileCatalog.definition(entry))

  defp profile_identity(%{"profile_snapshot" => profile}),
    do: Map.take(profile, ~w(name revision))

  defp profile_identity(_), do: nil

  defp continuation_spec(%{spec: %{"profile_snapshot" => snapshot} = spec}, args) do
    with true <-
           Map.has_key?(args, "input") || Options.error("profile continuations require input"),
         false <- Map.has_key?(args, "message"),
         {:ok, entry} <- ProfileCatalog.restore(snapshot),
         {:ok, prompt} <- ProfileCatalog.render(entry, args["input"]) do
      {:ok, Map.put(spec, "task", prompt)}
    else
      true -> Options.error("profile continuations cannot use message; provide input")
      failure -> failure
    end
  end

  defp continuation_spec(task, args) do
    cond do
      Map.has_key?(args, "input") ->
        Options.error("ordinary continuations require message, not input")

      not Options.text?(args["message"]) ->
        Options.error("message must be nonempty")

      true ->
        {:ok, Map.put(task.spec, "task", args["message"])}
    end
  end

  defp restore_profiles(nil), do: ProfileCatalog.seed()

  defp restore_profiles(store) do
    with {:ok, saved} <- Store.load_profiles(store) do
      if is_nil(saved) do
        with {:ok, catalog} <- ProfileCatalog.seed(),
             :ok <- persist_profiles(store, catalog),
             do: {:ok, catalog}
      else
        Enum.reduce_while(saved, {:ok, %{}}, fn snapshot, {:ok, catalog} ->
          case ProfileCatalog.restore(snapshot) do
            {:ok, entry} ->
              if Map.has_key?(catalog, entry.profile.name),
                do: {:halt, error("invalid_profile_catalog", "duplicate saved profile name")},
                else: {:cont, {:ok, Map.put(catalog, entry.profile.name, entry)}}

            failure ->
              {:halt, failure}
          end
        end)
      end
    end
  end

  defp persist_profiles(nil, _), do: :ok

  defp persist_profiles(store, catalog) do
    snapshots = catalog |> Map.values() |> Enum.map(&ProfileCatalog.definition/1)

    case Store.save_profiles(store, snapshots) do
      :ok -> :ok
      {:error, reason} -> error("persistence_failed", reason)
    end
  end

  defp start_conversation(state, spec, conversation, session_id) do
    name = {__MODULE__, self(), conversation}

    with {:ok, contract} <- Options.contract(spec["output_schema"]),
         {:ok, backend_opts} <- prepare_options(state, spec),
         {:ok, pid} <-
           safely(fn ->
             DynamicSupervisor.start_child(
               state.agent_supervisor,
               {Worker,
                [
                  name: name,
                  backend: GenAgent.Delegation.Backend,
                  task_supervisor: state.task_supervisor,
                  backend_opts: [
                    manager: self(),
                    name: name,
                    backend: Map.fetch!(state.backends, spec["backend"]),
                    backend_opts: backend_opts,
                    provider_session_id: session_id
                  ],
                  watchdog_ms: spec["timeout_secs"] * 1000,
                  max_tell_results: 1
                ]}
             )
           end) do
      {:ok,
       %{
         conversation: conversation,
         name: name,
         pid: pid,
         monitor: Process.monitor(pid),
         contract: contract
       }}
    else
      {:error, reason} -> error("start_failed", reason)
    end
  end

  defp prepare_options(state, spec) do
    opts =
      Keyword.merge(
        Options.backend_opts(spec),
        Map.get(state.backend_options, spec["backend"], [])
      )

    case {spec["backend"], spec["output_schema"]} do
      {_, nil} ->
        {:ok, opts}

      {"claude", schema} ->
        Providers.Claude.prepare(schema, opts, nil)

      {"codex", schema} ->
        with {:ok, dir, _} <- Files.allocate(self()),
             do: Providers.Codex.prepare(schema, opts, dir)

      _ ->
        error("invalid_args", "structured output requires Claude or Codex")
    end
  end

  defp ensure_conversation(state, task) do
    cond do
      is_pid(task.pid) and Process.alive?(task.pid) ->
        {:ok, task}

      is_binary(task.public["provider_session_id"]) ->
        start_conversation(
          state,
          task.spec,
          task.public["conversation_id"],
          task.public["provider_session_id"]
        )

      true ->
        error("session_unavailable", "no retained provider session ID to resume")
    end
  end

  defp stop_conversation(state, runtime) do
    DynamicSupervisor.terminate_child(state.agent_supervisor, runtime.pid)
    Process.demonitor(runtime.monitor, [:flush])
  end

  defp submit(state, spec, runtime, parent) do
    case safely(fn ->
           GenAgent.tell_with_completion(runtime.name, Options.task_prompt(spec), self(), 5000,
             on_halt: :fail,
             stream_to: self()
           )
         end) do
      {:ok, ref} ->
        id = id()

        public =
          Map.take(spec, ~w(backend cwd model effort access timeout_secs output_schema selection))
          |> Map.merge(%{
            "task_id" => id,
            "conversation_id" => runtime.conversation,
            "parent_task_id" => parent,
            "status" => "running",
            "started_at_ms" => System.system_time(:millisecond),
            "finished_at_ms" => nil,
            "result" => nil,
            "structured_result" => nil,
            "error" => nil,
            "error_info" => nil,
            "provider_session_id" =>
              if(parent, do: state.tasks[parent].public["provider_session_id"]),
            "profile" => profile_identity(spec),
            "usage" => nil,
            "result_truncated" => false,
            "event_count" => 0
          })

        task =
          Map.merge(runtime, %{
            public: public,
            spec: Map.delete(spec, "task"),
            ref: ref,
            timer: Process.send_after(self(), {:deadline, id}, spec["timeout_secs"] * 1000)
          })

        next =
          %{
            state
            | tasks: Map.put(state.tasks, id, task),
              latest: Map.put(state.latest, runtime.conversation, id)
          }
          |> persist(id)

        {:ok, next.tasks[id].public, next}

      failure ->
        failure
    end
  end

  defp finish(state, id, outcome) do
    task = state.tasks[id]
    Process.cancel_timer(task.timer)

    fields =
      case outcome do
        {:ok, response} -> response_fields(task, response)
        {:error, reason} -> failure_fields(reason)
      end

    public =
      task.public
      |> Map.merge(fields)
      |> Map.put("finished_at_ms", System.system_time(:millisecond))

    state |> put_in([:tasks, id, :public], public) |> persist(id)
  end

  defp cancel(state, id, status) do
    task = state.tasks[id]

    result =
      safely(fn ->
        case GenAgent.cancel_request(task.name, task.ref, 5000) do
          {:error, :current} -> GenAgent.interrupt_request(task.name, task.ref, 5000)
          result -> result
        end
      end)

    case result do
      {:ok, _} ->
        state =
          finish(state, id, {:error, if(status == "timeout", do: :timeout, else: :cancelled)})

        public =
          Map.merge(state.tasks[id].public, %{
            "status" => if(status == "timeout", do: "failed", else: status),
            "cancellation_scope" => "gen_agent_request",
            "provider_settled" => false
          })

        state |> put_in([:tasks, id, :public], public) |> persist(id)

      _ ->
        # Completion can win the race before its notification reaches us.
        case safely(fn -> GenAgent.poll(task.name, task.ref, 5000) end) do
          {:ok, :completed, response} -> finish(state, id, {:ok, response})
          {:error, reason} -> finish(state, id, {:error, reason})
          _ -> finish(state, id, {:error, {:cancellation_unconfirmed, result}})
        end
    end
  end

  defp wake(state) do
    waiters =
      Enum.reject(state.waiters, fn {_key, waiter} ->
        if ready?(state, waiter.ids) do
          Process.cancel_timer(waiter.timer)
          Process.demonitor(waiter.monitor, [:flush])
          GenServer.reply(waiter.from, {:ok, snapshot(state, waiter.ids, false)})
          true
        else
          false
        end
      end)
      |> Map.new()

    %{state | waiters: waiters}
  end

  defp ready?(state, ids),
    do:
      Enum.any?(
        ids,
        &(not Map.has_key?(state.tasks, &1) or state.tasks[&1].public["status"] in @terminal)
      )

  # Default list rows are an explicit allowlist; anything not named here
  # (output, schemas, usage, provider metadata, session IDs, selection)
  # requires `full_result: true` or `wait_tasks`.
  @summary_keys ~w(task_id conversation_id parent_task_id cwd backend status started_at_ms
                   finished_at_ms last_activity_at_ms event_count last_event access model
                   effort timeout_secs result_truncated)

  defp summary(task) do
    task
    |> Map.take(@summary_keys)
    |> put_summary_profile(task)
    |> put_summary_error(task)
  end

  defp put_summary_profile(summary, %{"profile" => %{} = profile}),
    do: Map.put(summary, "profile", Map.take(profile, ~w(name revision)))

  defp put_summary_profile(summary, %{"profile" => nil}), do: Map.put(summary, "profile", nil)
  defp put_summary_profile(summary, _task), do: summary

  defp put_summary_error(summary, task) do
    summary =
      case task do
        %{"error" => error} when is_binary(error) ->
          # Bound by code points so the limit holds however graphemes are counted.
          bounded = error |> Store.redact() |> String.codepoints() |> Enum.take(256)
          Map.put(summary, "error", Enum.join(bounded))

        %{"error" => nil} ->
          Map.put(summary, "error", nil)

        _ ->
          summary
      end

    case task do
      %{"error_info" => %{} = info} ->
        Map.put(summary, "error_info", Map.take(info, ["kind", "retryable?"]))

      %{"error_info" => nil} ->
        Map.put(summary, "error_info", nil)

      _ ->
        summary
    end
  end

  defp snapshot(state, ids, timed_out) do
    {known, missing} = Enum.split_with(Enum.uniq(ids), &Map.has_key?(state.tasks, &1))

    %{
      "tasks" => Enum.map(known, &Map.delete(state.tasks[&1].public, "output_schema")),
      "errors" => Enum.map(missing, &%{"task_id" => &1, "error" => "not_found"}),
      "timed_out" => timed_out
    }
  end

  defp fetch(state, id) do
    case Map.fetch(state.tasks, id) do
      {:ok, task} -> {:ok, task}
      :error -> error("not_found", "unknown task ID")
    end
  end

  defp capacity(state) do
    cond do
      state.persistence_error != nil ->
        error("persistence_failed", state.persistence_error)

      map_size(state.tasks) >= state.max_tasks ->
        error(
          "capacity",
          "task history is full; use a new state directory or archive its records while stopped"
        )

      Enum.count(state.tasks, fn {_, t} -> t.public["status"] == "running" end) >=
          state.max_running ->
        error("capacity", "worker limit reached")

      true ->
        :ok
    end
  end

  defp response_fields(task, response) do
    text = response.final_message || response.text || ""

    common = %{
      "provider_session_id" => response.session_id || task.public["provider_session_id"],
      "usage" => json_value(response.usage),
      "provider_metadata" =>
        response.terminal
        |> Map.get(:data, %{})
        |> Map.take([:cost_usd, :duration_ms, :num_turns])
        |> json_value(),
      "selection" => selection(task, response)
    }

    case structured_value(task, response) do
      {:ok, value} ->
        Map.merge(common, %{
          "status" => "completed",
          "result" => String.slice(text, 0, 65_536),
          "result_truncated" => String.length(text) > 65_536,
          "structured_result" => value
        })

      {:error, reason} ->
        Map.merge(common, failure_fields({:structured_output, reason}))
    end
  end

  defp structured_value(%{contract: nil}, _), do: {:ok, nil}

  defp structured_value(task, response) do
    provider = if task.spec["backend"] == "claude", do: Providers.Claude, else: Providers.Codex

    with {:ok, value} <- provider.extract(response, task.spec["output_schema"]),
         :ok <- Contract.validate_output(task.contract, value),
         do: {:ok, value}
  end

  defp selection(task, response) do
    source = Map.get(response.terminal || %{}, :data, %{}) |> Map.get(:model_source)

    reported =
      if is_binary(response.model) and source != :requested,
        do: %{"model" => response.model},
        else: %{}

    Map.put(task.spec["selection"] || %{}, "reported", reported)
  end

  defp failure_fields(reason) do
    info =
      case reason do
        %GenAgent.Backend.Error{} = value ->
          value
          |> Map.from_struct()
          |> Map.take([:provider, :kind, :retryable?, :status, :retry_after, :message])
          |> json_value()

        :timeout ->
          %{"kind" => "timeout", "retryable?" => true}

        :cancelled ->
          %{"kind" => "cancelled", "retryable?" => false}

        {:structured_output, value} ->
          %{
            "kind" => "invalid_structured_output",
            "message" => safe_message(value),
            "retryable?" => false
          }

        value ->
          %{"kind" => "provider_failure", "message" => safe_message(value), "retryable?" => false}
      end
      |> Store.redact()
      |> Map.update("message", nil, fn message ->
        if is_binary(message), do: String.slice(message, 0, 2000), else: nil
      end)

    fields = %{
      "status" => "failed",
      "error" => info["message"] || info["kind"],
      "error_info" => info
    }

    fields =
      case reason do
        %GenAgent.Backend.Error{raw: raw} when is_map(raw) ->
          metadata =
            raw
            |> Map.take([:subtype, :usage, :cost_usd, :num_turns])
            |> json_value()
            |> Store.redact()

          fields = Map.put(fields, "provider_metadata", metadata)

          fields =
            if is_map(raw[:usage]),
              do: Map.put(fields, "usage", json_value(raw[:usage])),
              else: fields

          if is_binary(raw[:session_id]),
            do: Map.put(fields, "provider_session_id", raw[:session_id]),
            else: fields

        _ ->
          fields
      end

    if reason in [:timeout, :cancelled],
      do:
        Map.merge(fields, %{
          "cancellation_scope" => "gen_agent_request",
          "provider_settled" => false
        }),
      else: fields
  end

  defp safe_message(reason) do
    # Redact complete diagnostic text before bounding the public string.
    reason
    |> inspect(limit: :infinity, printable_limit: :infinity)
    |> Store.redact()
    |> String.slice(0, 2000)
  end

  defp restore(nil), do: {:ok, nil, %{}, []}

  defp restore(dir) do
    with {:ok, store} <- Store.open(dir) do
      case Store.load(store) do
        {:ok, records, warnings} ->
          tasks =
            Map.new(records, fn record ->
              public = record["snapshot"]

              {public["task_id"],
               %{
                 public: public,
                 spec: record["spec"],
                 conversation: public["conversation_id"],
                 name: nil,
                 pid: nil,
                 monitor: nil,
                 ref: nil,
                 timer: nil,
                 contract: nil
               }}
            end)

          {:ok, store, tasks, Enum.map(warnings, &safe_message/1)}

        failure ->
          Store.close(store)
          failure
      end
    end
  end

  defp latest(tasks) do
    parents = MapSet.new(tasks, fn {_, task} -> task.public["parent_task_id"] end)

    tasks
    |> Map.values()
    |> Enum.reject(&MapSet.member?(parents, &1.public["task_id"]))
    |> Enum.sort_by(& &1.public["started_at_ms"])
    |> Map.new(&{&1.public["conversation_id"], &1.public["task_id"]})
  end

  defp persist(%{store: nil} = state, _), do: state

  defp persist(state, id) do
    task = state.tasks[id]

    case Store.save(state.store, task.public, task.spec) do
      :ok ->
        state

      {:error, reason} ->
        message = safe_message(reason)

        state
        |> Map.put(:persistence_error, message)
        |> put_in([:tasks, id, :public, "persistence_error"], message)
    end
  end

  defp exact_keys(args, keys) when is_map(args) do
    if Map.keys(args) -- keys == [], do: :ok, else: Options.error("unsupported arguments")
  end

  defp exact_keys(_, _), do: Options.error("arguments must be an object")
  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp json_value(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> Jason.decode!(encoded)
      {:error, _} -> nil
    end
  end

  defp error(code, reason),
    do:
      {:error,
       %{
         code: code,
         message:
           if(is_binary(reason),
             do: reason |> Store.redact() |> String.slice(0, 2000),
             else: safe_message(reason)
           )
       }}

  defp safely(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:call_exit, reason}}
  end
end
