defmodule GenAgentEnsemble.AsyncLifecycleTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.ControlledBackend

  defmodule Member do
    use GenAgent

    @impl true
    def init_agent(opts) do
      send(opts[:observer], {:member_initialized, opts[:tag], self()})

      if opts[:hold_start] do
        receive do
          :release_start -> :ok
        end
      end

      {:ok, Keyword.take(opts, [:observer, :tag]), Map.new(opts)}
    end

    @impl true
    def handle_response(_, _, state), do: {:noreply, state}

    @impl true
    def terminate_agent(_, %{tag: "held", observer: observer}) do
      send(observer, {:shutdown_held, self()})

      receive do
        :release_shutdown -> :ok
      after
        5_000 -> :ok
      end
    end

    def terminate_agent(_, _), do: :ok
  end

  defmodule Strategy do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(opts) do
      observer = Keyword.fetch!(opts, :observer)
      {:ok, observer, [spec("held", observer)]}
    end

    @impl true
    def handle_tell("stop", _, token, observer),
      do: {:ok, [{:stop, "held"}, {:reply, token, "stopped"}], observer}

    def handle_tell("start", _, token, observer),
      do: {:ok, [{:start, spec("next", observer)}, {:dispatch, "next", "work", token}], observer}

    def handle_tell("ops", opts, token, observer),
      do: {:ok, opts[:ops].(token), observer}

    @impl true
    def handle_notify({:ops, ops}, observer), do: {:ok, ops, observer}

    def handle_notify(:halt, observer), do: {:ok, [{:halt, :test_halt}], observer}

    @impl true
    def handle_start_rejected(name, reason, observer) do
      send(observer, {:start_rejected, name, reason})
      {:ok, [], observer}
    end

    @impl true
    def handle_agent_down(name, reason, observer) do
      send(observer, {:unexpected_recovery, name, reason})
      {:ok, [], observer}
    end

    @impl true
    def handle_ask(prompt, opts, token, state), do: handle_tell(prompt, opts, token, state)

    @impl true
    def handle_response(_, _, observer), do: lifecycle_output(observer)

    @impl true
    def handle_error(_, _, observer), do: lifecycle_output(observer)

    defp lifecycle_output(observer),
      do: {:ok, [{:stop, "held"}, {:start, spec("recovered", observer)}], observer}

    defp spec(tag, observer),
      do: {tag, Member, [backend: ControlledBackend, observer: observer, tag: tag]}
  end

  setup do
    name = "async-life-#{System.unique_integer([:positive])}"
    {:ok, server} = Ensemble.start_link(name: name, strategy: Strategy, opts: [observer: self()])
    assert_receive {:member_initialized, "held", held}

    on_exit(fn ->
      send(held, :release_shutdown)

      if Process.alive?(server) do
        try do
          GenServer.stop(server, :normal, 10_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{name: name, server: server, held: held}
  end

  for source <- [:notify, :response, :error] do
    test "#{source} lifecycle output suspends stop then starts once", %{
      name: name,
      held: held,
      server: server
    } do
      source = unquote(source)

      if source == :notify do
        Ensemble.notify(
          name,
          {:ops,
           [
             {:stop, "held"},
             {:start,
              {"recovered", Member,
               [backend: ControlledBackend, observer: self(), tag: "recovered"]}}
           ]}
        )
      else
        {:ok, _} =
          Ensemble.tell(name, "ops", ops: fn token -> [{:dispatch, "held", "source", token}] end)

        assert_receive {:controlled_prompt, "held", "source", task}
        send(task, if(source == :response, do: {:result, "done"}, else: {:error, :test_error}))
      end

      assert_receive {:shutdown_held, ^held}
      assert {:ok, _} = Ensemble.status(name)
      assert {:ok, []} = Ensemble.inbox(name)
      assert :sys.get_state(server).runtime.active.kind == :stop
      refute_received {:member_initialized, "recovered", _}
      send(held, :release_shutdown)
      assert_receive {:member_initialized, "recovered", _}, 2_000
      assert {:ok, _} = Ensemble.status(name)
      refute_received {:member_initialized, "recovered", _}
      refute_received {:unexpected_recovery, "held", _}
    end
  end

  test "Pool DOWN replacement initialization remains responsive", %{name: name} do
    pool_name = name <> "-pool"
    owner = self()

    starter =
      Task.async(fn ->
        {:ok, pool} =
          Ensemble.start_link(
            name: pool_name,
            strategy: GenAgentEnsemble.Strategies.Pool,
            opts: [
              worker_count: 1,
              worker_template:
                {"worker", Member,
                 [backend: ControlledBackend, observer: owner, tag: "pool", hold_start: true]}
            ]
          )

        send(owner, {:pool_started, pool})

        receive do
          :stop_pool -> GenServer.stop(pool)
        end
      end)

    assert_receive {:member_initialized, "pool", first}
    send(first, :release_start)
    assert_receive {:pool_started, pool}
    on_exit(fn -> if Process.alive?(pool), do: Process.exit(pool, :kill) end)
    Process.exit(first, :kill)
    assert_receive {:member_initialized, "pool", replacement}
    on_exit(fn -> send(replacement, :release_start) end)
    assert replacement != first
    assert {:ok, _} = Ensemble.status(pool_name)
    assert {:ok, []} = Ensemble.inbox(pool_name)
    assert :sys.get_state(pool).runtime.active.kind == :start
    {:ok, token} = Ensemble.tell(pool_name, "queued")
    assert {:ok, :pending} = Ensemble.poll(pool_name, token)
    :erlang.trace(pool, true, [:receive])
    send(replacement, :release_start)
    # The member's dispatch admission proves the replacement is installed.
    # Its init notification alone precedes the supervisor result.
    receive do
      {:trace, ^pool, :receive, {:lifecycle_result, _, _, _, _, _}} -> :ok
    after
      2_000 -> flunk("replacement lifecycle result missing")
    end

    :erlang.trace(pool, false, [:receive])
    assert_receive {:controlled_prompt, "pool", "queued", task}
    send(task, {:result, "done"})
    assert {:ok, %{text: "done"}} = Ensemble.await(pool_name, token, 2_000)
    send(starter.pid, :stop_pool)
    Task.await(starter)
    refute_received {:member_initialized, "pool", _}
  end

  test "cross-batch stop then start reuses the member after cleanup", %{name: name, held: held} do
    {:ok, stopped} = Ensemble.tell(name, "stop")
    assert_receive {:shutdown_held, ^held}
    observer = self()

    {:ok, restarted} =
      Ensemble.tell(name, "ops",
        ops: fn token ->
          [
            {:start,
             {"held", Member,
              [backend: ControlledBackend, observer: observer, tag: "replacement"]}},
            {:dispatch, "held", "restart", token},
            {:reply, token, "restarted"}
          ]
        end
      )

    assert {:ok, :pending} = Ensemble.poll(name, restarted)
    send(held, :release_shutdown)
    assert {:ok, "stopped"} = Ensemble.await(name, stopped)
    assert_receive {:member_initialized, "replacement", replacement}
    assert replacement != held
    assert_receive {:controlled_prompt, "replacement", "restart", task}
    assert {:ok, "restarted"} = Ensemble.await(name, restarted)
    send(task, {:result, "done"})
  end

  test "Supervisor fresh tell waits for held fan-in cleanup", %{name: name} do
    supervisor_name = name <> "-supervisor"

    {:ok, server} =
      Ensemble.start_link(
        name: supervisor_name,
        strategy: GenAgentEnsemble.Strategies.Supervisor,
        opts: [
          coordinator:
            {"coordinator", Member,
             [backend: ControlledBackend, observer: self(), tag: "coordinator"]},
          worker_template:
            {"w", Member, [backend: ControlledBackend, observer: self(), tag: "held"]},
          decomposer: fn _ -> ["work"] end
        ]
      )

    on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :kill) end)
    {:ok, first} = Ensemble.tell(supervisor_name, "first")
    assert_receive {:controlled_prompt, "coordinator", "first", coordinator}
    send(coordinator, {:result, "plan"})
    assert_receive {:member_initialized, "held", worker}
    assert_receive {:controlled_prompt, "held", "work", task}
    send(task, {:result, "first done"})
    assert {:ok, _} = Ensemble.await(supervisor_name, first)
    assert_receive {:shutdown_held, ^worker}
    {:ok, second} = Ensemble.tell(supervisor_name, "second")
    assert_receive {:controlled_prompt, "coordinator", "second", coordinator2}
    :erlang.trace(server, true, [:receive])
    send(coordinator2, {:result, "plan"})
    assert_receive {:trace, ^server, :receive, {:gen_agent, :completion, _, _, _}}
    :erlang.trace(server, false, [:receive])
    assert :queue.len(:sys.get_state(server).runtime.queue) == 1
    assert {:ok, :pending} = Ensemble.poll(supervisor_name, second)
    send(worker, :release_shutdown)
    assert_receive {:member_initialized, "held", replacement}
    assert replacement != worker
    assert_receive {:controlled_prompt, "held", "work", task2}
    send(task2, {:result, "second done"})
    assert {:ok, _} = Ensemble.await(supervisor_name, second)
    assert_receive {:shutdown_held, ^replacement}
    send(replacement, :release_shutdown)
    GenServer.stop(server)
  end

  for failure <- [:error, :worker_down] do
    @tag failure: failure
    test "Supervisor #{failure} fences late old-run output before held cleanup", %{
      name: name,
      failure: failure
    } do
      name = name <> "-terminal-#{failure}"
      work = if failure == :error, do: ["one", "two"], else: ["one", "two", "three"]

      {:ok, server} =
        Ensemble.start_link(
          name: name,
          strategy: GenAgentEnsemble.Strategies.Supervisor,
          opts: [
            coordinator:
              {"coordinator", Member,
               [backend: ControlledBackend, observer: self(), tag: "coordinator"]},
            worker_template:
              {"w", Member, [backend: ControlledBackend, observer: self(), tag: "held"]},
            decomposer: fn _ -> work end
          ]
        )

      on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :kill) end)
      {:ok, first} = Ensemble.tell_with_completion(name, "first")
      assert_receive {:controlled_prompt, "coordinator", "first", coordinator}
      send(coordinator, {:result, "plan"})

      for _ <- work, do: assert_receive({:member_initialized, "held", _})
      assert_receive {:controlled_prompt, "held", "one", task1}
      assert_receive {:controlled_prompt, "held", "two", task2}

      if failure == :error do
        send(task1, {:error, :test_error})
      else
        assert_receive {:controlled_prompt, "held", "three", _}
        Process.exit(:sys.get_state(server).agents["w-3"], :kill)
      end

      assert_receive {:shutdown_held, worker1}
      on_exit(fn -> send(worker1, :release_shutdown) end)
      assert_receive {:gen_agent_ensemble, :completion, ^name, ^first, {:error, _}}
      refute Map.has_key?(:sys.get_state(server).pending, first)
      {:ok, second} = Ensemble.tell(name, "second")
      assert_receive {:controlled_prompt, "coordinator", "second", coordinator2}
      :erlang.trace(server, true, [:receive])
      send(coordinator2, {:result, "plan"})
      assert_receive {:trace, ^server, :receive, {:gen_agent, :completion, _, _, _}}
      assert :queue.len(:sys.get_state(server).runtime.queue) == 1

      send(task2, {:result, "STALE t1 text"})
      assert_receive {:trace, ^server, :receive, {:gen_agent, :completion, _, _, _}}
      :erlang.trace(server, false, [:receive])
      assert {:fanning_out, ^second, progress} = :sys.get_state(server).strategy_state.phase
      assert Enum.all?(progress, fn {_, value} -> value == :pending end)
      send(worker1, :release_shutdown)
      assert_receive {:shutdown_held, worker2}
      send(worker2, :release_shutdown)

      for _ <- work, do: assert_receive({:member_initialized, "held", _}, 2_000)

      for prompt <- work do
        assert_receive {:controlled_prompt, "held", ^prompt, task}
        send(task, {:result, "fresh t2 #{prompt}"})
      end

      assert {:ok, %{text: text}} = Ensemble.await(name, second)
      refute text =~ "STALE"
      for prompt <- work, do: assert(text =~ "fresh t2 #{prompt}")
      assert {:error, _} = Ensemble.poll(name, first)
      refute_received {:gen_agent_ensemble, :completion, ^name, ^first, _}

      for _ <- work do
        assert_receive {:shutdown_held, worker}
        send(worker, :release_shutdown)
      end

      GenServer.stop(server)
    end
  end

  test "held shutdown leaves status, poll and inbox responsive", %{name: name, held: held} do
    call = Task.async(fn -> Ensemble.tell(name, "stop") end)
    assert_receive {:shutdown_held, ^held}
    {:ok, token} = Task.await(call, 1_000)
    assert {:ok, _} = Ensemble.status(name)
    assert {:ok, :pending} = Ensemble.poll(name, token)
    assert {:ok, []} = Ensemble.inbox(name)
    assert Process.alive?(held)
    send(held, :release_shutdown)
    assert {:ok, "stopped"} = Ensemble.await(name, token, 2_000)
  end

  test "start and dispatch wait behind held stop while reads remain responsive", %{
    name: name,
    server: server,
    held: held
  } do
    stop_call = Task.async(fn -> Ensemble.tell(name, "stop") end)
    assert_receive {:shutdown_held, ^held}
    {:ok, stopped} = Task.await(stop_call, 1_000)
    start_call = Task.async(fn -> Ensemble.tell(name, "start") end)
    {:ok, next} = Task.await(start_call, 1_000)
    assert {:ok, _} = Ensemble.status(name)
    assert {:ok, :pending} = Ensemble.poll(name, next)
    assert {:ok, []} = Ensemble.inbox(name)

    # The initiating call and reads are mailbox barriers. The executor has
    # reached the start, but has issued only the captured stop to the supervisor.
    state = :sys.get_state(server)
    assert state.runtime.active.kind == :stop
    assert :queue.len(state.runtime.queue) == 1
    refute_received {:member_initialized, "next", _}
    refute_received {:controlled_prompt, "next", _, _}

    send(held, :release_shutdown)
    assert {:ok, "stopped"} = Ensemble.await(name, stopped, 2_000)
    assert_receive {:member_initialized, "next", _}, 2_000
    assert_receive {:controlled_prompt, "next", "work", task}, 2_000
    send(task, {:result, "done"})
  end

  test "queued starts and stopping-member operations wait for reservations", %{
    name: name,
    server: server,
    held: held
  } do
    {:ok, stopped} = Ensemble.tell(name, "stop")
    assert_receive {:shutdown_held, ^held}
    {:ok, _next} = Ensemble.tell(name, "start")
    {:ok, duplicate} = Ensemble.tell(name, "start")
    assert {:ok, :pending} = Ensemble.poll(name, duplicate)
    assert :queue.len(:sys.get_state(server).runtime.queue) == 2

    {:ok, blocked} =
      Ensemble.tell(name, "ops",
        ops: fn token ->
          [{:forward, "held", :blocked}, {:dispatch, "held", "blocked", token}]
        end
      )

    assert {:ok, :pending} = Ensemble.poll(name, blocked)

    refute_received {:controlled_prompt, "held", _, _}
    send(held, :release_shutdown)
    assert {:ok, "stopped"} = Ensemble.await(name, stopped)
    assert_receive {:start_rejected, "next", {:duplicate_sub_agent, "next"}}

    assert {:error, {:dispatch_rejected, "held", {:agent_not_running, "held"}}} =
             Ensemble.await(name, blocked)

    assert_receive {:member_initialized, "next", _}
    assert_receive {:controlled_prompt, "next", "work", task}
    send(task, {:result, "done"})
    refute_received {:unexpected_recovery, _, _}
  end

  test "intentional DOWN before worker result retains slot and retires its monitor once", %{
    name: name,
    server: server,
    held: held
  } do
    {:ok, stopped} = Ensemble.tell(name, "stop")
    assert_receive {:shutdown_held, ^held}
    state = :sys.get_state(server)
    worker = state.runtime.active.worker
    [{monitor, "held"}] = Map.to_list(state.monitors)
    :erlang.suspend_process(worker)
    watch = Process.monitor(held)

    try do
      send(held, :release_shutdown)
      assert_receive {:DOWN, ^watch, :process, ^held, _}
      # A message from the test is not an ordering barrier for another sender's
      # DOWN. Inject the exact evidence too; both copies must be harmless.
      send(server, {:DOWN, monitor, :process, held, :normal})
      state = :sys.get_state(server)
      assert state.agents["held"] == held
      assert state.runtime.stopping["held"].pid == held
      refute_received {:unexpected_recovery, _, _}
    after
      :erlang.resume_process(worker)
    end

    assert {:ok, "stopped"} = Ensemble.await(name, stopped)
    state = :sys.get_state(server)
    assert state.agents == %{}
    assert state.monitors == %{}
    assert state.runtime.stopping == %{}
    send(server, {:DOWN, monitor, :process, held, :normal})
    assert {:ok, _} = Ensemble.status(name)
    refute_received {:unexpected_recovery, _, _}
  end

  test "result before delayed intentional DOWN removes the old monitor", %{
    name: name,
    server: server,
    held: held
  } do
    {:ok, stopped} = Ensemble.tell(name, "stop")
    assert_receive {:shutdown_held, ^held}
    [{monitor, "held"}] = Map.to_list(:sys.get_state(server).monitors)

    :sys.replace_state(server, fn state ->
      Process.demonitor(monitor, [:flush])
      state
    end)

    send(held, :release_shutdown)
    assert {:ok, "stopped"} = Ensemble.await(name, stopped)
    assert :sys.get_state(server).monitors == %{}
    send(server, {:DOWN, monitor, :process, held, :normal})
    assert {:ok, _} = Ensemble.status(name)
    refute_received {:unexpected_recovery, _, _}
  end

  test "failed stop retires a dead captured incarnation without recovery", %{
    name: name,
    server: server,
    held: held
  } do
    observer = self()

    supervisor =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:terminate_child, pid}} ->
            send(observer, {:stop_called, self(), pid})

            receive do
              :resolve -> GenServer.reply(from, {:error, :stop_refused})
            end
        end
      end)

    original = :sys.get_state(server).agent_supervisor
    :sys.replace_state(server, &%{&1 | agent_supervisor: supervisor})

    try do
      {:ok, token} = Ensemble.tell(name, "stop")
      assert_receive {:stop_called, ^supervisor, ^held}
      watch = Process.monitor(held)
      Process.exit(held, :kill)
      assert_receive {:DOWN, ^watch, :process, ^held, _}
      [{monitor, "held"}] = Map.to_list(:sys.get_state(server).monitors)
      send(server, {:DOWN, monitor, :process, held, :killed})
      assert :sys.get_state(server).agents["held"] == held
      send(supervisor, :resolve)
      assert {:ok, "stopped"} = Ensemble.await(name, token)
      state = :sys.get_state(server)
      assert state.agents == %{}
      assert state.monitors == %{}
      assert state.runtime.stopping == %{}
      refute_received {:unexpected_recovery, _, _}
    after
      send(supervisor, :resolve)
      :sys.replace_state(server, &%{&1 | agent_supervisor: original})
    end
  end

  for kind <- [:start, :stop] do
    test "halt retires held #{kind} and queued continuations", %{
      name: name,
      server: server,
      held: held
    } do
      observer = self()
      telemetry_id = make_ref()

      :ok =
        :telemetry.attach(
          telemetry_id,
          [:gen_agent_ensemble, :session, :halt],
          fn _, _, _, _ -> send(observer, :observed_halt) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(telemetry_id) end)

      {:ok, completed} =
        Ensemble.tell(name, "ops", ops: fn token -> [{:reply, token, "saved"}] end)

      {:ok, token} =
        if unquote(kind) == :stop do
          Ensemble.tell(name, "stop")
        else
          Ensemble.tell(name, "ops",
            ops: fn token ->
              [
                {:start,
                 {"blocked", Member,
                  [
                    backend: ControlledBackend,
                    observer: observer,
                    tag: "blocked",
                    hold_start: true
                  ]}},
                {:reply, token, "unsafe"}
              ]
            end
          )
        end

      barrier =
        if unquote(kind) == :stop do
          assert_receive {:shutdown_held, ^held}
          held
        else
          assert_receive {:member_initialized, "blocked", pid}
          pid
        end

      on_exit(fn ->
        send(barrier, :release_start)
        send(barrier, :release_shutdown)
      end)

      {:ok, queued} = Ensemble.tell(name, "start")
      active = :sys.get_state(server).runtime.active
      watch = Process.monitor(active.worker)
      Ensemble.notify(name, :halt)
      assert {:error, {:halted, :test_halt}} = Ensemble.await(name, token)
      assert {:error, {:halted, :test_halt}} = Ensemble.await(name, queued)
      assert_receive {:DOWN, ^watch, :process, _, _}
      state = :sys.get_state(server)
      assert state.runtime.active == nil
      assert :queue.is_empty(state.runtime.queue)
      assert state.runtime.starting == %{}
      assert state.runtime.stopping == %{}

      send(
        server,
        {:lifecycle_result, active.id, active.worker, active.supervisor, active.argument, :ok}
      )

      send(server, {:DOWN, active.monitor, :process, active.worker, :killed})
      Ensemble.notify(name, :halt)
      assert {:ok, :completed, "saved"} = Ensemble.poll(name, completed)
      assert_receive :observed_halt
      refute_received :observed_halt
      send(barrier, :release_start)
      send(barrier, :release_shutdown)
      refute_received {:member_initialized, "next", _}
    end
  end

  test "worker crash stops session without replaying tail", %{
    name: name,
    server: server,
    held: held
  } do
    {:ok, _} = Ensemble.tell(name, "stop")
    assert_receive {:shutdown_held, ^held}
    {:ok, _} = Ensemble.tell(name, "start")
    active = :sys.get_state(server).runtime.active
    Process.unlink(server)
    watch = Process.monitor(server)
    Process.exit(active.worker, :kill)
    send(held, :release_shutdown)
    assert_receive {:DOWN, ^watch, :process, ^server, :lifecycle_worker_failed}, 2_000
    refute_received {:member_initialized, "next", _}
  end

  test "stale identities do not release active call", %{name: name, server: server, held: held} do
    {:ok, token} = Ensemble.tell(name, "stop")
    assert_receive {:shutdown_held, ^held}
    active = :sys.get_state(server).runtime.active

    for {id, worker, supervisor, argument} <- [
          {make_ref(), active.worker, active.supervisor, active.argument},
          {active.id, self(), active.supervisor, active.argument},
          {active.id, active.worker, self(), active.argument},
          {active.id, active.worker, active.supervisor, self()}
        ] do
      send(server, {:lifecycle_result, id, worker, supervisor, argument, :ok})
    end

    send(server, {:DOWN, make_ref(), :process, active.worker, :killed})
    send(server, {:DOWN, active.monitor, :process, self(), :killed})
    assert :sys.get_state(server).runtime.active == active
    assert {:ok, :pending} = Ensemble.poll(name, token)
    send(held, :release_shutdown)
    assert {:ok, "stopped"} = Ensemble.await(name, token)
  end

  test "server death retires worker and old tree before same-name reuse", %{
    name: name,
    server: server,
    held: held
  } do
    {:ok, _} = Ensemble.tell(name, "stop")
    assert_receive {:shutdown_held, ^held}
    {:ok, _} = Ensemble.tell(name, "start")
    state = :sys.get_state(server)
    worker = state.runtime.active.worker
    worker_watch = Process.monitor(worker)
    tree_watch = Process.monitor(state.agent_tree)
    Process.unlink(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^worker_watch, :process, ^worker, :killed}
    send(held, :release_shutdown)
    assert_receive {:DOWN, ^tree_watch, :process, _, _}, 2_000

    {:ok, replacement} =
      Ensemble.start_link(name: name, strategy: Strategy, opts: [observer: self()])

    assert_receive {:member_initialized, "held", replacement_member}

    on_exit(fn ->
      send(replacement_member, :release_shutdown)

      if Process.alive?(replacement) do
        try do
          GenServer.stop(replacement)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert :sys.get_state(replacement).agent_tree != state.agent_tree
    send(replacement_member, :release_shutdown)
    GenServer.stop(replacement)
    refute_received {:member_initialized, "next", _}
  end

  test "graceful stop retires worker while waiting for held tree", %{
    name: name,
    server: server,
    held: held
  } do
    {:ok, _} = Ensemble.tell(name, "stop")
    assert_receive {:shutdown_held, ^held}
    state = :sys.get_state(server)
    watch = Process.monitor(state.runtime.active.worker)
    stopped = Task.async(fn -> GenServer.stop(server, :normal, :infinity) end)
    assert_receive {:DOWN, ^watch, :process, _, :killed}
    assert Process.alive?(state.agent_tree)
    assert Task.yield(stopped, 0) == nil
    send(held, :release_shutdown)
    assert Task.await(stopped) == :ok
    refute Process.alive?(state.agent_tree)
  end
end
