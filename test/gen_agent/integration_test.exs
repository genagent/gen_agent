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

    # Produces an event stream that blocks forever so the prompt task
    # stays in-flight until we kill it.
    defp blocking_script do
      fn _prompt ->
        Stream.resource(
          fn -> :go end,
          fn state ->
            Process.sleep(10_000)
            {[], state}
          end,
          fn _ -> :ok end
        )
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
      name = unique_name("inflight")

      {:ok, _pid} =
        GenAgent.start_agent(SlowScriptAgent,
          name: name,
          backend: GenAgent.Backends.Mock,
          scripts: [blocking_script()]
        )

      # Send a prompt that hangs indefinitely in the backend stream.
      {:ok, _ref} = GenAgent.tell(name, "hang forever")

      wait_until(fn ->
        GenAgent.status(name).state == :processing
      end)

      # Locate the in-flight task pid via the agent's current_request.
      # The task is a child of GenAgent.TaskSupervisor.
      task_pids_before = Task.Supervisor.children(GenAgent.TaskSupervisor)
      assert task_pids_before != []

      :ok = GenAgent.stop(name)

      # After stop, the agent is gone AND the in-flight task is dead.
      wait_until(fn -> is_nil(GenAgent.whereis(name)) end)

      Process.sleep(50)

      # Any task that was running before stop should now be dead.
      alive_after =
        Enum.filter(task_pids_before, &Process.alive?/1)

      assert alive_after == [],
             "in-flight task survived GenAgent.stop -- " <>
               "terminate/3 / cleanup_task did not run"
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
