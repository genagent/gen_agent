defmodule GenAgent.InfoMessagesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GenAgent.Backends.Mock
  alias GenAgent.Event

  defmodule InfoAgent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      {:ok, [scripts: Keyword.get(opts, :scripts, [])],
       %{observer: Keyword.fetch!(opts, :observer), turns: 0, infos: []}}
    end

    @impl true
    def handle_response(_ref, _response, state) do
      send(state.observer, {:response, state.turns})
      {:noreply, %{state | turns: state.turns + 1}}
    end

    @impl true
    def handle_event({:monitor, pid}, state) do
      Process.monitor(pid)
      {:noreply, state}
    end

    def handle_event({:delegate, worker}, state) do
      {:ok, ref} = GenAgent.tell_with_completion(worker, "delegated")
      send(state.observer, {:delegated, ref})
      {:noreply, state}
    end

    @impl true
    def handle_info({:prompt, prompt}, state) do
      send(state.observer, {:info_prompt, prompt})
      {:prompt, prompt, state}
    end

    def handle_info(message, state) do
      send(state.observer, {:info, message, state.turns})
      {:noreply, %{state | infos: state.infos ++ [message]}}
    end
  end

  defp start_agent(module \\ InfoAgent, opts \\ []) do
    name = "info-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      GenAgent.start_agent(
        module,
        Keyword.merge([name: name, backend: Mock, observer: self()], opts)
      )

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(GenAgent.AgentSupervisor, pid)
    end)

    {name, pid}
  end

  test "plain timers, real monitor DOWNs, and another agent's completion reach handle_info" do
    {worker, _worker_pid} =
      start_agent(InfoAgent, scripts: [[Event.new(:result, %{text: "done"})]])

    {name, pid} = start_agent()

    Process.send_after(pid, :tick, 1)
    assert_receive {:info, :tick, 0}

    target =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = GenAgent.notify_ack(name, {:monitor, target})
    Process.exit(target, :kill)
    assert_receive {:info, {:DOWN, _ref, :process, ^target, :killed}, 0}

    assert :ok = GenAgent.notify_ack(name, {:delegate, worker})
    assert_receive {:delegated, ref}
    assert_receive {:info, {:gen_agent, :completion, ^worker, ^ref, {:ok, _result}}, 0}
  end

  test "info received during a turn is deferred and sees the completed state" do
    script = Mock.gate(:turn, [Event.new(:result, %{text: "done"})])
    {name, pid} = start_agent(InfoAgent, scripts: [script])

    {:ok, _ref} = GenAgent.tell(name, "work")
    assert_receive {:mock_blocked, :turn, task_pid}

    send(pid, :during_turn)
    assert GenAgent.runtime_snapshot(name).pending_notifications == 1
    refute_receive {:info, :during_turn, _}, 0

    send(task_pid, {:mock_release, :turn})
    assert_receive {:response, 0}
    assert_receive {:info, :during_turn, 1}
    assert GenAgent.status(name).agent_state.infos == [:during_turn]
  end

  test "a timer can start a prompt without blocking the agent process" do
    {name, pid} =
      start_agent(InfoAgent, scripts: [[Event.new(:result, %{text: "done"})]])

    Process.send_after(pid, {:prompt, "retry"}, 1)
    assert_receive {:info_prompt, "retry"}
    assert_receive {:response, 0}
    assert Mock.history(name) == ["retry"]
  end

  test "late task replies and exits remain internal after the turn" do
    script = Mock.gate(:stale, [Event.new(:result, %{text: "done"})])
    {name, pid} = start_agent(InfoAgent, scripts: [script])

    {:ok, _ref} = GenAgent.tell(name, "work")
    assert_receive {:mock_blocked, :stale, task_pid}
    {:processing, data} = :sys.get_state(pid)
    task_ref = data.current_request.task_ref

    send(task_pid, {:mock_release, :stale})
    assert_receive {:response, 0}
    assert GenAgent.runtime_snapshot(name).phase == :idle

    send(pid, {task_ref, :late_result})
    send(pid, {:DOWN, task_ref, :process, task_pid, :late_failure})
    send(pid, {:EXIT, task_pid, :late_failure})
    assert GenAgent.status(name).agent_state.infos == []
    refute_receive {:info, _, _}, 0
  end

  test "linked helper exits are logged and delivered; unknown calls and casts do not crash the agent" do
    {name, pid} = start_agent()
    helper = :gen_statem.call(pid, :get_backend_session).agent

    log =
      capture_log(fn ->
        Process.exit(helper, :boom)
        assert_receive {:info, {:EXIT, ^helper, :boom}, 0}
      end)

    assert log =~ "linked process exited (:boom)"
    assert {:error, :unknown_request} = :gen_statem.call(pid, :unknown)
    :ok = :gen_statem.cast(pid, :unknown)
    assert GenAgent.status(name).agent_state.infos == [{:EXIT, helper, :boom}]
    assert Process.alive?(pid)
  end

  test "unexpected info is logged when no handle_info callback exists" do
    {name, pid} = start_agent(GenAgent.Support.TestAgent)

    log =
      capture_log(fn ->
        send(pid, {:unexpected, "private payload"})
        assert %{agent_state: _} = GenAgent.status(name)
      end)

    assert log =~ "unexpected info message"
    refute log =~ "private payload"
    assert Process.alive?(pid)
  end
end
