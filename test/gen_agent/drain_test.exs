defmodule GenAgent.DrainTest do
  use ExUnit.Case, async: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      {:ok, [scripts: Keyword.fetch!(opts, :scripts)],
       %{observer: Keyword.fetch!(opts, :observer), chain?: Keyword.get(opts, :chain?, false)}}
    end

    @impl true
    def handle_response(ref, _response, state) do
      send(state.observer, {:response, ref})

      if state.chain? do
        {:prompt, "follow-up", %{state | chain?: false}}
      else
        {:noreply, state}
      end
    end

    @impl true
    def post_turn(_outcome, ref, state) do
      send(state.observer, {:post_turn, ref})
      {:ok, state}
    end

    @impl true
    def handle_event(event, state) do
      send(state.observer, {:event, event})
      {:noreply, state}
    end

    @impl true
    def terminate_agent(reason, state) do
      send(state.observer, {:terminated, reason})
      :ok
    end
  end

  defp blocked_turn(observer) do
    fn _prompt ->
      Stream.resource(
        fn -> :start end,
        fn
          :start ->
            send(observer, {:turn_started, self()})

            receive do
              :release -> {[Event.new(:result, %{text: "done"})], :done}
            end

          :done ->
            {:halt, :done}
        end,
        fn _ -> :ok end
      )
    end
  end

  defp start_agent(scripts, opts \\ []) do
    name = "drain-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      GenAgent.start_agent(
        Agent,
        Keyword.merge([name: name, backend: Mock, scripts: scripts, observer: self()], opts)
      )

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(GenAgent.AgentSupervisor, pid)
    end)

    {name, pid}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  test "drain refuses new work, rejects queued work, and finishes the active turn" do
    observer = self()

    follow_up = fn _prompt ->
      send(observer, :follow_up_started)
      [Event.new(:result, %{text: "unexpected"})]
    end

    {name, pid} = start_agent([blocked_turn(observer), follow_up], chain?: true)
    backend_pid = :gen_statem.call(pid, :get_backend_session).agent

    {:ok, active_ref} = GenAgent.tell_with_completion(name, "active")
    assert_receive {:turn_started, turn_pid}

    queued_ask = Task.async(fn -> GenAgent.ask(name, "queued ask") end)
    eventually(fn -> GenAgent.runtime_snapshot(name).pending_prompts == 1 end)
    {:ok, queued_ref} = GenAgent.tell_with_completion(name, "queued tell")
    :ok = GenAgent.notify(name, :queued_event)
    eventually(fn -> GenAgent.runtime_snapshot(name).pending_notifications == 1 end)

    drainer = Task.async(fn -> GenAgent.drain(name) end)
    eventually(fn -> GenAgent.runtime_snapshot(name).draining end)

    assert {:error, :draining} = Task.await(queued_ask)
    assert_receive {:gen_agent, :completion, ^name, ^queued_ref, {:error, :draining}}
    assert GenAgent.runtime_snapshot(name).pending_prompts == 0
    assert GenAgent.runtime_snapshot(name).pending_notifications == 0
    assert GenAgent.status(name).draining

    assert {:error, :draining} = GenAgent.ask(name, "new ask")
    assert {:error, :draining} = GenAgent.tell(name, "new tell")
    assert {:error, :draining} = GenAgent.tell_with_completion(name, "new completion")
    assert {:error, :draining} = GenAgent.notify_ack(name, :new_event)
    assert :ok = GenAgent.notify(name, :ignored_cast)

    send(turn_pid, :release)
    assert_receive {:response, ^active_ref}
    assert_receive {:post_turn, ^active_ref}
    assert_receive {:gen_agent, :completion, ^name, ^active_ref, {:ok, %{text: "done"}}}
    assert :ok = Task.await(drainer, 2_000)
    assert_receive {:terminated, :normal}
    refute Process.alive?(backend_pid)
    assert GenAgent.whereis(name) == nil
    refute_receive :follow_up_started, 0
    refute_receive {:event, _}, 0
  end

  test "drain stops an idle agent and waits for cleanup" do
    {name, pid} = start_agent([])
    backend_pid = :gen_statem.call(pid, :get_backend_session).agent

    assert :ok = GenAgent.drain(name)
    assert_receive {:terminated, :normal}
    refute Process.alive?(backend_pid)
    assert GenAgent.whereis(name) == nil
    assert {:error, :not_found} = GenAgent.drain(name)
  end

  test "a caller timeout does not cancel an accepted drain" do
    observer = self()
    {name, pid} = start_agent([blocked_turn(observer)])
    {:ok, ref} = GenAgent.tell_with_completion(name, "active")
    assert_receive {:turn_started, turn_pid}

    assert {:error, :timeout} = GenAgent.drain(name, 50)
    assert GenAgent.runtime_snapshot(name).draining
    assert Process.alive?(pid)

    send(turn_pid, :release)
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, _}}
    eventually(fn -> not Process.alive?(pid) end)
    assert_receive {:terminated, :normal}
  end
end
