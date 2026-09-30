defmodule GenAgent.IntegrationTest do
  @moduledoc """
  End-to-end tests that go through the public `GenAgent` API and the
  OTP supervision tree rather than starting the server directly. This
  is the "real user" path: `GenAgent.start_agent/2` -> Registry lookup
  -> `GenAgent.ask/2` etc.
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias GenAgent.Event

  defmodule SimpleAgent do
    use GenAgent

    defmodule State do
      defstruct responses: [], events: [], extra: %{}
    end

    @impl true
    def init_agent(opts) do
      scripts = Keyword.get(opts, :scripts, [])
      {:ok, [scripts: scripts], %State{}}
    end

    @impl true
    def handle_response(ref, response, %State{} = state) do
      {:noreply, %{state | responses: state.responses ++ [{ref, response.text}]}}
    end
  end

  defmodule EventDrivenAgent do
    use GenAgent

    defmodule State do
      defstruct responses: []
    end

    @impl true
    def init_agent(opts) do
      {:ok, [scripts: Keyword.get(opts, :scripts, [])], %State{}}
    end

    @impl true
    def handle_response(_ref, response, state) do
      {:noreply, %{state | responses: state.responses ++ [response.text]}}
    end

    @impl true
    def handle_event({:say, what}, state) do
      {:prompt, what, state}
    end

    def handle_event(:halt_me, state) do
      {:halt, state}
    end
  end

  defmodule MinimalAgent do
    @behaviour GenAgent

    @impl true
    def init_agent(opts) do
      {:ok, [scripts: Keyword.fetch!(opts, :scripts)], []}
    end

    @impl true
    def handle_response(_ref, response, state), do: {:noreply, [response.text | state]}
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp start_simple(scripts) do
    name = unique_name("simple")

    {:ok, _pid} =
      GenAgent.start_agent(SimpleAgent,
        name: name,
        backend: GenAgent.Backends.Mock,
        scripts: scripts
      )

    on_exit(fn ->
      case GenAgent.whereis(name) do
        nil -> :ok
        _ -> GenAgent.stop(name)
      end
    end)

    name
  end

  defp start_caller_tree do
    {:ok, root} =
      Supervisor.start_link(
        [Task.Supervisor, {DynamicSupervisor, strategy: :one_for_one}],
        strategy: :rest_for_one
      )

    Process.unlink(root)

    on_exit(fn ->
      if Process.alive?(root), do: Supervisor.stop(root)
    end)

    children = Map.new(Supervisor.which_children(root), fn {id, pid, _, _} -> {id, pid} end)
    {root, Map.fetch!(children, Task.Supervisor), Map.fetch!(children, DynamicSupervisor)}
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  describe "start_agent/2" do
    test "registers the agent under the given name" do
      name = start_simple([])
      assert is_pid(GenAgent.whereis(name))
    end

    test "requires :name and :backend" do
      assert_raise KeyError, fn ->
        GenAgent.start_agent(SimpleAgent, backend: GenAgent.Backends.Mock)
      end

      assert_raise KeyError, fn ->
        GenAgent.start_agent(SimpleAgent, name: "no-backend")
      end
    end
  end

  describe "stop/1" do
    test "stops a running agent and deregisters it" do
      name = start_simple([])
      pid = GenAgent.whereis(name)
      assert is_pid(pid)

      assert :ok = GenAgent.stop(name)

      # Wait briefly for Registry to clean up.
      wait_until(fn -> GenAgent.whereis(name) == nil end)
      refute Process.alive?(pid)
    end

    test "returns {:error, :not_found} for unknown names" do
      assert {:error, :not_found} = GenAgent.stop("nope-#{System.unique_integer()}")
    end
  end

  describe "caller-owned supervision" do
    test "requires an explicit task supervisor and preserves temporary children" do
      assert_raise KeyError, fn ->
        GenAgent.child_spec(SimpleAgent,
          name: unique_name("missing-tasks"),
          backend: GenAgent.Backends.Mock
        )
      end

      {_, task_supervisor, agent_supervisor} = start_caller_tree()
      name = unique_name("owned")

      spec =
        GenAgent.child_spec(SimpleAgent,
          name: name,
          backend: GenAgent.Backends.Mock,
          task_supervisor: task_supervisor,
          scripts: [[Event.new(:result, %{text: "owned"})]]
        )

      assert spec.restart == :temporary
      assert {:ok, pid} = DynamicSupervisor.start_child(agent_supervisor, spec)
      assert GenAgent.whereis(name) == pid
      assert {:ok, %{text: "owned"}} = GenAgent.ask(name, "hi")
      assert {:error, :not_found} = GenAgent.stop(name)
      assert :ok = GenAgent.stop(name, agent_supervisor)
      wait_until(fn -> GenAgent.whereis(name) == nil end)
    end

    test "stopping and restarting the caller's tree removes its idle and busy agents" do
      {root, task_supervisor, agent_supervisor} = start_caller_tree()
      global_name = start_simple([[Event.new(:result, %{text: "global"})]])
      idle_name = unique_name("owned-idle")
      busy_name = unique_name("owned-busy")

      for {name, scripts} <- [
            {idle_name, []},
            {busy_name, [blocking_script(:stream)]}
          ] do
        spec =
          GenAgent.child_spec(SimpleAgent,
            name: name,
            backend: GenAgent.Backends.Mock,
            task_supervisor: task_supervisor,
            scripts: scripts
          )

        assert {:ok, _pid} = DynamicSupervisor.start_child(agent_supervisor, spec)
      end

      idle_pid = GenAgent.whereis(idle_name)
      busy_pid = GenAgent.whereis(busy_name)
      idle_monitor = Process.monitor(idle_pid)
      busy_monitor = Process.monitor(busy_pid)

      assert {:ok, _ref} = GenAgent.tell(busy_name, "hold")
      assert_receive {:prompt_blocked, task_pid, :stream}
      task_monitor = Process.monitor(task_pid)
      assert task_pid in Task.Supervisor.children(task_supervisor)
      refute task_pid in Task.Supervisor.children(GenAgent.TaskSupervisor)

      assert :ok = Supervisor.stop(root)
      assert_receive {:DOWN, ^idle_monitor, :process, ^idle_pid, _}
      assert_receive {:DOWN, ^busy_monitor, :process, ^busy_pid, _}
      assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, _}

      wait_until(fn ->
        GenAgent.whereis(idle_name) == nil and GenAgent.whereis(busy_name) == nil
      end)

      assert {:ok, %{text: "global"}} = GenAgent.ask(global_name, "still here")

      {_, new_tasks, new_agents} = start_caller_tree()

      spec =
        GenAgent.child_spec(SimpleAgent,
          name: busy_name,
          backend: GenAgent.Backends.Mock,
          task_supervisor: new_tasks,
          scripts: [[Event.new(:result, %{text: "restarted"})]]
        )

      assert {:ok, _pid} = DynamicSupervisor.start_child(new_agents, spec)
      assert {:ok, %{text: "restarted"}} = GenAgent.ask(busy_name, "again")
    end

    test "task-supervisor failure stops caller-owned agents before replacement" do
      {root, task_supervisor, agent_supervisor} = start_caller_tree()
      name = unique_name("owned-task-failure")

      spec =
        GenAgent.child_spec(SimpleAgent,
          name: name,
          backend: GenAgent.Backends.Mock,
          task_supervisor: task_supervisor,
          scripts: []
        )

      assert {:ok, agent_pid} = DynamicSupervisor.start_child(agent_supervisor, spec)
      agent_monitor = Process.monitor(agent_pid)
      Process.exit(task_supervisor, :kill)

      assert_receive {:DOWN, ^agent_monitor, :process, ^agent_pid, _}
      wait_until(fn -> GenAgent.whereis(name) == nil end)

      wait_until(fn ->
        children = Map.new(Supervisor.which_children(root), fn {id, pid, _, _} -> {id, pid} end)

        is_pid(children[Task.Supervisor]) and children[Task.Supervisor] != task_supervisor and
          is_pid(children[DynamicSupervisor]) and
          children[DynamicSupervisor] != agent_supervisor
      end)
    end

    for phase <- [:prompt, :stream] do
      test "abrupt exit cancels a caller-owned task blocked in #{phase}" do
        phase = unquote(phase)
        {_, task_supervisor, agent_supervisor} = start_caller_tree()
        name = unique_name("owned-kill")

        spec =
          GenAgent.child_spec(SimpleAgent,
            name: name,
            backend: GenAgent.Backends.Mock,
            task_supervisor: task_supervisor,
            scripts: [blocking_script(phase)]
          )

        assert {:ok, agent_pid} = DynamicSupervisor.start_child(agent_supervisor, spec)
        assert {:ok, _ref} = GenAgent.tell(name, "hold")
        assert_receive {:prompt_blocked, task_pid, ^phase}
        task_monitor = Process.monitor(task_pid)

        Process.exit(agent_pid, :kill)

        assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :killed}
        wait_until(fn -> GenAgent.whereis(name) == nil end)
        refute task_pid in Task.Supervisor.children(task_supervisor)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ask / tell / poll
  # ---------------------------------------------------------------------------

  describe "ask/2" do
    test "round-trips a prompt through the whole stack" do
      name = start_simple([[Event.new(:result, %{text: "pong"})]])

      assert {:ok, response} = GenAgent.ask(name, "ping")
      assert response.text == "pong"

      status = GenAgent.status(name)
      assert status.state == :idle
      assert [{_ref, "pong"}] = status.agent_state.responses
    end

    test "returns {:error, reason} for a backend error" do
      name = start_simple([{:error, :backend_down}])
      assert {:error, :backend_down} = GenAgent.ask(name, "hi")
    end
  end

  describe "tell/2 + poll/2" do
    test "returns a ref and makes the result pollable" do
      name = start_simple([[Event.new(:result, %{text: "done"})]])

      assert {:ok, ref} = GenAgent.tell(name, "work")

      wait_until(fn ->
        match?({:ok, :completed, _}, GenAgent.poll(name, ref))
      end)

      assert {:ok, :completed, response} = GenAgent.poll(name, ref)
      assert response.text == "done"
    end
  end

  # ---------------------------------------------------------------------------
  # notify / interrupt / resume
  # ---------------------------------------------------------------------------

  describe "notify/2" do
    test "routes events to handle_event and dispatches prompts" do
      name = unique_name("event")

      {:ok, _} =
        GenAgent.start_agent(EventDrivenAgent,
          name: name,
          backend: GenAgent.Backends.Mock,
          scripts: [[Event.new(:result, %{text: "hello josh"})]]
        )

      on_exit(fn ->
        case GenAgent.whereis(name) do
          nil -> :ok
          _ -> GenAgent.stop(name)
        end
      end)

      assert :ok = GenAgent.notify(name, {:say, "hi"})

      wait_until(fn ->
        match?(%{agent_state: %{responses: ["hello josh"]}}, GenAgent.status(name))
      end)
    end

    test "handle_event {:halt, state} puts the agent into halted mode" do
      name = unique_name("event")

      {:ok, _} =
        GenAgent.start_agent(EventDrivenAgent,
          name: name,
          backend: GenAgent.Backends.Mock,
          scripts: []
        )

      on_exit(fn ->
        case GenAgent.whereis(name) do
          nil -> :ok
          _ -> GenAgent.stop(name)
        end
      end)

      GenAgent.notify(name, :halt_me)

      wait_until(fn -> GenAgent.status(name).halted end)

      assert GenAgent.status(name).halted
    end
  end

  describe "interrupt/1" do
    test "cancels an in-flight ask and returns {:error, :interrupted}" do
      slow = fn _ ->
        Stream.resource(
          fn -> :s end,
          fn
            :s ->
              Process.sleep(500)
              {[Event.new(:result, %{text: "never"})], :d}

            :d ->
              {:halt, :d}
          end,
          fn _ -> :ok end
        )
      end

      name = start_simple([slow])

      caller = Task.async(fn -> GenAgent.ask(name, "start") end)
      Process.sleep(20)
      assert :ok = GenAgent.interrupt(name)

      assert {:error, :interrupted} = Task.await(caller)
    end
  end

  describe "resume/1" do
    test "unhalts an agent and drains the mailbox" do
      name = unique_name("event")

      {:ok, _} =
        GenAgent.start_agent(EventDrivenAgent,
          name: name,
          backend: GenAgent.Backends.Mock,
          scripts: [[Event.new(:result, %{text: "after resume"})]]
        )

      on_exit(fn ->
        case GenAgent.whereis(name) do
          nil -> :ok
          _ -> GenAgent.stop(name)
        end
      end)

      GenAgent.notify(name, :halt_me)
      wait_until(fn -> GenAgent.status(name).halted end)

      {:ok, ref} = GenAgent.tell(name, "queued")
      assert {:ok, :pending} = GenAgent.poll(name, ref)

      :ok = GenAgent.resume(name)

      wait_until(fn ->
        match?({:ok, :completed, _}, GenAgent.poll(name, ref))
      end)

      {:ok, :completed, response} = GenAgent.poll(name, ref)
      assert response.text == "after resume"
      refute GenAgent.status(name).halted
    end
  end

  # ---------------------------------------------------------------------------
  # use GenAgent macro -- defaults for optional callbacks
  # ---------------------------------------------------------------------------

  describe "use GenAgent" do
    test "provides default handle_event that keeps state" do
      # SimpleAgent does not override handle_event -- the default from the
      # use macro should accept any event and return :noreply.
      name = start_simple([])
      assert :ok = GenAgent.notify(name, {:random_event, 1})

      # Agent should still be idle and alive with unchanged state.
      Process.sleep(10)
      assert GenAgent.status(name).state == :idle
    end
  end

  describe "optional callbacks without use GenAgent" do
    defp start_minimal(scripts) do
      name = unique_name("minimal")

      {:ok, _pid} =
        GenAgent.start_agent(MinimalAgent,
          name: name,
          backend: GenAgent.Backends.Mock,
          scripts: scripts
        )

      on_exit(fn -> GenAgent.stop(name) end)
      name
    end

    test "a module implementing only required callbacks completes turns" do
      name =
        start_minimal([
          [Event.new(:text, %{text: "hello"}), Event.new(:result, %{text: "hello"})],
          {:error, :unavailable},
          [Event.new(:result, %{text: "again"})]
        ])

      assert {:ok, %{text: "hello"}} = GenAgent.ask(name, "first")
      assert {:error, :unavailable} = GenAgent.ask(name, "second")
      assert {:ok, %{text: "again"}} = GenAgent.ask(name, "third")
      assert GenAgent.status(name).agent_state == ["again", "hello"]
    end

    test "an omitted handle_event callback ignores notifications without logging errors" do
      name = start_minimal([])

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert :ok = GenAgent.notify(name, :unused)
               assert %{state: :idle, agent_state: []} = GenAgent.status(name)
             end) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Supervised shutdown -- regression tests for the trap_exit fix
  # ---------------------------------------------------------------------------

  describe "supervised shutdown" do
    defmodule SlowScriptAgent do
      @moduledoc false
      use GenAgent

      defmodule State, do: defstruct([])

      @impl true
      def init_agent(opts) do
        scripts = Keyword.get(opts, :scripts, [])
        {:ok, [scripts: scripts], %State{}}
      end

      @impl true
      def handle_response(_ref, _response, state), do: {:noreply, state}
    end

    # The task announces its own pid at the exact blocking point. This
    # avoids depending on scheduling delays or other agents' shared tasks.
    defp blocking_script(phase) do
      parent = self()

      block = fn ->
        send(parent, {:prompt_blocked, self(), phase})

        receive do
          :continue -> [Event.new(:result, %{text: "released"})]
        end
      end

      case phase do
        :prompt -> fn _prompt -> block.() end
        :stream -> fn _prompt -> Stream.flat_map([:turn], fn _ -> block.() end) end
      end
    end

    test "the agent traps exits so DynamicSupervisor.terminate_child reaches terminate/3" do
      name = unique_name("trap")

      {:ok, _pid} =
        GenAgent.start_agent(SlowScriptAgent,
          name: name,
          backend: GenAgent.Backends.Mock,
          scripts: []
        )

      on_exit(fn ->
        case GenAgent.whereis(name) do
          nil -> :ok
          _ -> GenAgent.stop(name)
        end
      end)

      pid = GenAgent.whereis(name)
      assert {:trap_exit, true} = Process.info(pid, :trap_exit)
    end

    test "GenAgent.stop/1 kills the in-flight task via terminate/3" do
      name = start_simple([blocking_script(:stream)])
      {:ok, _ref} = GenAgent.tell(name, "hang forever")

      assert_receive {:prompt_blocked, task_pid, :stream}
      task_monitor = Process.monitor(task_pid)

      :ok = GenAgent.stop(name)

      assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :killed}
      wait_until(fn -> is_nil(GenAgent.whereis(name)) end)
    end

    for phase <- [:prompt, :stream] do
      test "killing an agent cancels its task blocked in #{phase} and preserves other agents" do
        phase = unquote(phase)
        other_name = start_simple([blocking_script(:stream), [Event.new(:result, %{text: "ok"})]])
        {:ok, other_ref} = GenAgent.tell(other_name, "unrelated turn")
        assert_receive {:prompt_blocked, other_task_pid, :stream}

        name = start_simple([blocking_script(phase)])
        agent_pid = GenAgent.whereis(name)
        agent_monitor = Process.monitor(agent_pid)
        {:ok, _ref} = GenAgent.tell(name, "blocked turn")
        assert_receive {:prompt_blocked, task_pid, ^phase}
        task_monitor = Process.monitor(task_pid)

        Process.exit(agent_pid, :kill)

        assert_receive {:DOWN, ^agent_monitor, :process, ^agent_pid, :killed}
        assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :killed}
        wait_until(fn -> is_nil(GenAgent.whereis(name)) end)

        assert Process.alive?(other_task_pid)
        assert {:ok, :pending} = GenAgent.poll(other_name, other_ref)
        send(other_task_pid, :continue)
        assert {:ok, %{text: "ok"}} = GenAgent.ask(other_name, "next turn")
        assert {:ok, :completed, %{text: "released"}} = GenAgent.poll(other_name, other_ref)

        # Neither agent nor task is restarted by the shared supervisors.
        refute task_pid in Task.Supervisor.children(GenAgent.TaskSupervisor)
        assert GenAgent.whereis(name) == nil
      end
    end

    test "killed agents do not auto-restart (restart: :temporary)" do
      name = unique_name("kill")

      {:ok, _pid} =
        GenAgent.start_agent(SlowScriptAgent,
          name: name,
          backend: GenAgent.Backends.Mock,
          scripts: []
        )

      pid = GenAgent.whereis(name)
      assert is_pid(pid)

      Process.exit(pid, :kill)

      wait_until(fn -> is_nil(GenAgent.whereis(name)) end)

      # A subsequent start_agent with the same name should succeed
      # (the old name is not registered to a zombie).
      {:ok, _new_pid} =
        GenAgent.start_agent(SlowScriptAgent,
          name: name,
          backend: GenAgent.Backends.Mock,
          scripts: []
        )

      on_exit(fn ->
        case GenAgent.whereis(name) do
          nil -> :ok
          _ -> GenAgent.stop(name)
        end
      end)

      new_pid = GenAgent.whereis(name)
      assert is_pid(new_pid)
      assert new_pid != pid
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp wait_until(fun, timeout \\ 1_000, interval \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline, interval)
  end

  defp do_wait(fun, deadline, interval) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timeout")
      else
        Process.sleep(interval)
        do_wait(fun, deadline, interval)
      end
    end
  end
end
