defmodule GenAgent.EventCaptureTest do
  use ExUnit.Case, async: true

  alias GenAgent.Event

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      state = %{observer: Keyword.fetch!(opts, :observer), seen_count: 0, decisions: []}
      {:ok, [scripts: Keyword.fetch!(opts, :scripts)], state}
    end

    @impl true
    def handle_stream_event(_event, state) do
      %{state | seen_count: state.seen_count + 1}
    end

    @impl true
    def handle_response(ref, _response, state) do
      send(state.observer, {:decision, ref, :ok, state.seen_count})
      {:noreply, %{state | decisions: [{ref, :ok} | state.decisions]}}
    end

    @impl true
    def handle_error(ref, reason, state) do
      send(state.observer, {:decision, ref, {:error, reason}, state.seen_count})
      {:noreply, %{state | decisions: [{ref, :error} | state.decisions]}}
    end
  end

  defp start_agent(scripts, opts \\ []) do
    name = "event-capture-#{System.unique_integer([:positive])}"

    agent_opts =
      Keyword.merge(
        [name: name, backend: GenAgent.Backends.Mock, scripts: scripts, observer: self()],
        opts
      )

    {:ok, _pid} = GenAgent.start_agent(Agent, agent_opts)

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    name
  end

  defp tell_and_wait(name, prompt) do
    assert {:ok, ref} = GenAgent.tell(name, prompt)
    assert_receive {:decision, ^ref, outcome, seen_count}
    {ref, outcome, seen_count}
  end

  test "the default event-count limit rejects a terminal result after many small events" do
    text_events = for _ <- 1..1_000, do: Event.new(:text, %{text: "x"})
    first_script = text_events ++ [Event.new(:result, %{text: "complete"})]
    second_script = [Event.new(:result, %{text: "next turn"})]
    name = start_agent([first_script, second_script])

    {ref, outcome, seen_count} = tell_and_wait(name, "long turn")
    assert seen_count == 1_000

    assert {:error, {:event_capture_overflow, diagnostics}} = outcome
    assert diagnostics.limit == :events
    assert diagnostics.max_events == 1_000
    assert diagnostics.retained_events == 1_000
    assert diagnostics.retained_bytes <= diagnostics.max_bytes
    assert diagnostics.rejected_event_kind == :result
    assert {:error, {:event_capture_overflow, ^diagnostics}} = GenAgent.poll(name, ref)

    # A late unconditional interrupt is idle and cannot convert the next
    # turn's bounded result into an overflow or replay the failed turn.
    assert :ok = GenAgent.interrupt(name)
    {next_ref, :ok, 1_001} = tell_and_wait(name, "next turn")
    assert {:ok, :completed, response} = GenAgent.poll(name, next_ref)
    assert response.text == "next turn"
    assert length(response.events) == 1
  end

  test "a single oversized event fails without entering callback state or cached success" do
    oversized = Event.new(:text, %{text: String.duplicate("x", 1_000)})
    normal = Event.new(:result, %{text: "small"})
    name = start_agent([[oversized, normal], [normal]], max_event_bytes_per_turn: 256)

    {ref, outcome, 0} = tell_and_wait(name, "oversized")
    assert {:error, {:event_capture_overflow, diagnostics}} = outcome
    assert diagnostics.limit == :bytes
    assert diagnostics.max_bytes == 256
    assert diagnostics.retained_events == 0
    assert diagnostics.retained_bytes == 0
    assert diagnostics.rejected_event_kind == :text
    assert diagnostics.rejected_event_bytes > 256
    assert {:error, {:event_capture_overflow, ^diagnostics}} = GenAgent.poll(name, ref)

    {next_ref, :ok, 1} = tell_and_wait(name, "usable again")
    assert {:ok, :completed, %{text: "small"}} = GenAgent.poll(name, next_ref)
  end

  test "aggregate byte limit and oversized terminal error retain bounded diagnostics" do
    text = Event.new(:text, %{text: "small"})
    error = Event.new(:error, %{reason: String.duplicate("private", 200)})
    text_bytes = :erlang.external_size(text)
    name = start_agent([[text, error]], max_event_bytes_per_turn: text_bytes + 1)

    {ref, outcome, 1} = tell_and_wait(name, "error too large")
    assert {:error, {:event_capture_overflow, diagnostics}} = outcome
    assert diagnostics.limit == :bytes
    assert diagnostics.retained_bytes == text_bytes
    assert diagnostics.retained_events == 1
    assert diagnostics.rejected_event_kind == :error
    refute inspect(outcome) =~ "privateprivate"
    assert {:error, {:event_capture_overflow, ^diagnostics}} = GenAgent.poll(name, ref)
  end

  test "terminal error within bounds retains its original reason" do
    name =
      start_agent([
        [Event.new(:text, %{text: "partial"}), Event.new(:error, %{reason: :rate_limited})]
      ])

    {ref, {:error, :rate_limited}, 2} = tell_and_wait(name, "failed turn")
    assert {:error, :rate_limited} = GenAgent.poll(name, ref)
  end

  test "overflow halts the enumerable and leaves the agent usable" do
    observer = self()

    script = fn _prompt ->
      Stream.resource(
        fn -> 0 end,
        fn n -> {[Event.new(:text, %{text: Integer.to_string(n)})], n + 1} end,
        fn _ -> send(observer, :stream_closed) end
      )
    end

    name = start_agent([script, [Event.new(:result, %{text: "after"})]], max_events_per_turn: 3)

    {ref, {:error, {:event_capture_overflow, diagnostics}}, 3} =
      tell_and_wait(name, "overflow")

    assert diagnostics.limit == :events
    assert_receive :stream_closed
    assert {:error, {:event_capture_overflow, ^diagnostics}} = GenAgent.poll(name, ref)

    {next_ref, :ok, 4} = tell_and_wait(name, "after overflow")
    assert {:ok, :completed, %{text: "after"}} = GenAgent.poll(name, next_ref)
  end

  test "interruption before a pending overflow keeps the interruption outcome" do
    observer = self()

    script = fn _prompt ->
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {[Event.new(:text, %{text: "accepted"})], :blocked}

          :blocked ->
            send(observer, {:waiting_to_overflow, self()})

            receive do
              :release -> {[Event.new(:text, %{text: "rejected"})], :done}
            end

          :done ->
            {:halt, :done}
        end,
        fn _ -> :ok end
      )
    end

    name = start_agent([script, [Event.new(:result, %{text: "next"})]], max_events_per_turn: 1)
    assert {:ok, ref} = GenAgent.tell(name, "interrupt")
    assert_receive {:waiting_to_overflow, task_pid}
    task_monitor = Process.monitor(task_pid)

    assert :ok = GenAgent.interrupt(name)
    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :killed}
    assert_receive {:decision, ^ref, {:error, :interrupted}, 0}
    assert {:error, :interrupted} = GenAgent.poll(name, ref)

    {next_ref, :ok, 1} = tell_and_wait(name, "next")
    assert {:ok, :completed, %{text: "next"}} = GenAgent.poll(name, next_ref)
  end
end
