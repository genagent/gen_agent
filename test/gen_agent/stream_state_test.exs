defmodule GenAgent.StreamStateTest do
  use ExUnit.Case, async: true

  alias GenAgent.Event

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      state = %{
        observer: Keyword.fetch!(opts, :observer),
        seen: [],
        decisions: [],
        post_turns: []
      }

      {:ok, [scripts: Keyword.fetch!(opts, :scripts)], state}
    end

    @impl true
    def handle_stream_event(event, state) do
      %{state | seen: state.seen ++ [event.kind]}
    end

    @impl true
    def handle_response(ref, response, state) do
      send(state.observer, {:decision, {:ok, response}, ref, state.seen})
      {:noreply, %{state | decisions: [{ref, :ok} | state.decisions]}}
    end

    @impl true
    def handle_error(ref, reason, state) do
      send(state.observer, {:decision, {:error, reason}, ref, state.seen})
      {:noreply, %{state | decisions: [{ref, :error} | state.decisions]}}
    end

    @impl true
    def post_turn(outcome, ref, state) do
      send(state.observer, {:post_turn, outcome, ref, state.seen})
      {:ok, %{state | post_turns: [{ref, outcome} | state.post_turns]}}
    end
  end

  defp start_agent(script) do
    name = "stream-state-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      GenAgent.start_agent(Agent,
        name: name,
        backend: GenAgent.Backends.Mock,
        scripts: [script],
        observer: self()
      )

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    name
  end

  defp assert_turn(name, expected_outcome, expected_seen) do
    assert {:ok, ref} = GenAgent.tell(name, "go")
    assert_receive {:decision, decision, ^ref, ^expected_seen}
    assert_receive {:post_turn, post_outcome, ^ref, ^expected_seen}

    case expected_outcome do
      :ok ->
        assert {:ok, %GenAgent.Response{}} = decision
        assert {:ok, %GenAgent.Response{}} = post_outcome
        assert {:ok, :completed, %GenAgent.Response{}} = GenAgent.poll(name, ref)

      {:error, reason} ->
        assert decision == {:error, reason}
        assert post_outcome == {:error, reason}
        assert GenAgent.poll(name, ref) == {:error, reason}
    end

    status = GenAgent.status(name)
    assert status.state == :idle
    assert status.queued == 0
    assert status.agent_state.seen == expected_seen
    decision_kind = if expected_outcome == :ok, do: :ok, else: :error
    assert status.agent_state.decisions == [{ref, decision_kind}]
    assert length(status.agent_state.post_turns) == 1
    refute_receive {:decision, _, _, _}
    refute_receive {:post_turn, _, _, _}
  end

  test "success passes final stream state through decision and post-turn" do
    name =
      start_agent([
        Event.new(:text, %{text: "partial"}),
        Event.new(:result, %{text: "complete"})
      ])

    assert_turn(name, :ok, [:text, :result])
  end

  test "terminal error preserves partial stream state" do
    name =
      start_agent([
        Event.new(:text, %{text: "partial"}),
        Event.new(:error, %{reason: :fixture_failure})
      ])

    assert_turn(name, {:error, :fixture_failure}, [:text, :error])
  end

  test "normal EOF preserves partial stream state" do
    name = start_agent([Event.new(:text, %{text: "partial"})])
    assert_turn(name, {:error, :no_terminal_event}, [:text])
  end

  test "synchronous backend error has no stream callback state" do
    name = start_agent({:error, :backend_down})
    assert_turn(name, {:error, :backend_down}, [])
  end

  test "interruption cannot recover task-local callback state" do
    observer = self()

    script = fn _prompt ->
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {[Event.new(:text, %{text: "partial"})], :blocked}

          :blocked ->
            send(observer, {:stream_blocked, self()})

            receive do
              :continue -> {[Event.new(:result, %{text: "complete"})], :done}
            end

          :done ->
            {:halt, :done}
        end,
        fn _ -> :ok end
      )
    end

    name = start_agent(script)
    assert {:ok, ref} = GenAgent.tell(name, "go")
    assert_receive {:stream_blocked, task_pid}
    task_monitor = Process.monitor(task_pid)

    assert :ok = GenAgent.interrupt(name)
    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, down_reason}
    # Monitor registration can race with the interrupt killing the task.
    # Then the monitor reports :noproc instead of the task's kill reason.
    assert down_reason in [:killed, :noproc]
    assert_receive {:decision, {:error, :interrupted}, ^ref, []}
    assert_receive {:post_turn, {:error, :interrupted}, ^ref, []}
    assert {:error, :interrupted} = GenAgent.poll(name, ref)

    status = GenAgent.status(name)
    assert status.state == :idle
    assert status.agent_state.seen == []
    assert status.agent_state.decisions == [{ref, :error}]
    assert length(status.agent_state.post_turns) == 1
  end
end
