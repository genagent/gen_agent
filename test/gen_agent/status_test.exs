defmodule GenAgent.StatusTest do
  use ExUnit.Case, async: true

  alias GenAgent.Event

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      state = %{
        observer: Keyword.fetch!(opts, :observer),
        payload: String.duplicate("secret-payload", 100),
        seen: [],
        notifications: []
      }

      {:ok, [scripts: Keyword.fetch!(opts, :scripts)], state}
    end

    @impl true
    def handle_stream_event(event, state) do
      %{state | seen: [event.kind | state.seen]}
    end

    @impl true
    def handle_response(ref, response, state) do
      send(state.observer, {:decision, ref, :ok})

      if response.text == "chain" do
        {:prompt, "follow-up", state}
      else
        {:noreply, state}
      end
    end

    @impl true
    def handle_error(ref, reason, state) do
      send(state.observer, {:decision, ref, {:error, reason}})
      {:noreply, state}
    end

    @impl true
    def handle_event(:halt, state), do: {:halt, state}

    def handle_event({:prompt, prompt}, state), do: {:prompt, prompt, state}

    def handle_event(event, state) do
      {:noreply, %{state | notifications: [event | state.notifications]}}
    end
  end

  defp blocked_script(label, result) do
    observer = self()

    fn _prompt ->
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {[Event.new(:text, %{text: "partial"})], :waiting}

          :waiting ->
            send(observer, {:blocked, label, self()})

            receive do
              :release -> {[Event.new(:result, %{text: result})], :done}
            end

          :done ->
            {:halt, :done}
        end,
        fn _ -> :ok end
      )
    end
  end

  defp start_agent(scripts) do
    name = "snapshot-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      GenAgent.start_agent(Agent,
        name: name,
        backend: GenAgent.Backends.Mock,
        watchdog_ms: 30_000,
        scripts: scripts,
        observer: self()
      )

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    name
  end

  defp assert_bounded(status) do
    assert Map.keys(status) |> Enum.sort() ==
             [
               :agent_state,
               :current_request,
               :current_turn,
               :halted,
               :name,
               :pending_notifications,
               :queued,
               :self_chain_pending,
               :state
             ]

    if status.current_turn do
      assert Map.keys(status.current_turn) |> Enum.sort() ==
               [:attempt, :elapsed_ms, :origin, :watchdog_ms]
    end

    refute inspect(Map.delete(status, :agent_state)) =~ "secret-payload"
  end

  test "idle status has empty counts and no turn metadata" do
    name = start_agent([])
    snapshot = GenAgent.status(name)

    assert_bounded(snapshot)

    assert Map.drop(snapshot, [:agent_state, :name]) == %{
             state: :idle,
             halted: false,
             queued: 0,
             pending_notifications: 0,
             self_chain_pending: false,
             current_request: nil,
             current_turn: nil
           }
  end

  test "active snapshot counts queued prompts and buffered notifications" do
    name =
      start_agent([
        blocked_script(:first, "first"),
        [Event.new(:result, %{text: "second"})]
      ])

    assert {:ok, first_ref} = GenAgent.tell(name, "first")
    assert_receive {:blocked, :first, first_task}
    assert {:ok, second_ref} = GenAgent.tell(name, "second")
    assert :ok = GenAgent.notify(name, :reconcile)

    snapshot = GenAgent.status(name)
    assert_bounded(snapshot)
    assert snapshot.state == :processing
    assert snapshot.halted == false
    assert snapshot.queued == 1
    assert snapshot.pending_notifications == 1
    assert snapshot.self_chain_pending == false
    assert snapshot.current_request == first_ref
    assert snapshot.current_turn.origin == :tell
    assert snapshot.current_turn.watchdog_ms == 30_000
    assert snapshot.current_turn.elapsed_ms >= 0

    # agent_state is the server's retained state, not task-local stream
    # callback state from the blocked prompt.
    assert snapshot.agent_state.seen == []

    send(first_task, :release)
    assert_receive {:decision, ^first_ref, :ok}
    assert_receive {:decision, ^second_ref, :ok}
    assert {:ok, :completed, _} = GenAgent.poll(name, first_ref)
    assert {:ok, :completed, _} = GenAgent.poll(name, second_ref)

    done = GenAgent.status(name)
    assert_bounded(done)
    assert done.state == :idle
    assert done.current_request == nil
    assert done.current_turn == nil
    assert done.queued == 0
    assert done.pending_notifications == 0
  end

  test "halted self-chain is visible and resume dispatches a callback turn" do
    name = start_agent([blocked_script(:first, "chain"), blocked_script(:follow, "done")])

    assert {:ok, first_ref} = GenAgent.tell(name, "first")
    assert_receive {:blocked, :first, first_task}
    assert :ok = GenAgent.notify(name, :halt)
    assert GenAgent.status(name).pending_notifications == 1

    send(first_task, :release)
    assert_receive {:decision, ^first_ref, :ok}

    halted = GenAgent.status(name)
    assert_bounded(halted)
    assert halted.state == :idle
    assert halted.halted
    assert halted.self_chain_pending
    assert halted.current_request == nil

    assert :ok = GenAgent.resume(name)
    assert_receive {:blocked, :follow, follow_task}

    resumed = GenAgent.status(name)
    assert_bounded(resumed)
    assert resumed.state == :processing
    refute resumed.halted
    refute resumed.self_chain_pending
    assert resumed.current_turn.origin == :self_chain

    send(follow_task, :release)
    assert_receive {:decision, _follow_ref, :ok}
    assert {:ok, :completed, _} = GenAgent.poll(name, first_ref)
    assert GenAgent.status(name).state == :idle
  end

  test "ask and event-origin turns identify their source without caller payloads" do
    name = start_agent([blocked_script(:ask, "asked"), blocked_script(:event, "notified")])

    caller = Task.async(fn -> GenAgent.ask(name, "private prompt") end)
    assert_receive {:blocked, :ask, ask_task}
    ask_snapshot = GenAgent.status(name)
    assert_bounded(ask_snapshot)
    assert ask_snapshot.current_turn.origin == :ask
    send(ask_task, :release)
    assert {:ok, %{text: "asked"}} = Task.await(caller)
    assert_receive {:decision, _ask_ref, :ok}

    assert :ok = GenAgent.notify(name, {:prompt, "event prompt"})
    assert_receive {:blocked, :event, event_task}
    event_snapshot = GenAgent.status(name)
    assert_bounded(event_snapshot)
    assert event_snapshot.current_turn.origin == :event
    send(event_task, :release)
    assert_receive {:decision, _event_ref, :ok}
    assert GenAgent.status(name).state == :idle
  end

  test "an errored turn returns to an empty idle snapshot" do
    name = start_agent([[Event.new(:error, %{reason: :fixture_error})]])
    assert {:ok, ref} = GenAgent.tell(name, "fail")
    assert_receive {:decision, ^ref, {:error, :fixture_error}}
    assert {:error, :fixture_error} = GenAgent.poll(name, ref)

    snapshot = GenAgent.status(name)
    assert_bounded(snapshot)
    assert snapshot.state == :idle
    assert snapshot.current_request == nil
    assert snapshot.queued == 0
    assert snapshot.pending_notifications == 0
  end
end
