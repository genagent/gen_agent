defmodule GenAgent.EventCaptureTest do
  use ExUnit.Case, async: true

  alias GenAgent.Event
  import GenAgent.TestDownAssertions

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

  test "compact retention delivers a long turn and updates the backend session" do
    deltas = for _ <- 1..1_500, do: Event.new(:text, %{text: "x"})
    usage = Event.new(:usage, %{input_tokens: 12, output_tokens: 34})
    terminal = Event.new(:result, %{text: "complete", session_id: "session-1"})
    name = start_agent([deltas ++ [usage, terminal], [Event.new(:result, %{text: "next"})]])

    {ref, :ok, 1_502} = tell_and_wait(name, "long turn")
    assert {:ok, :completed, response} = GenAgent.poll(name, ref)
    assert response.text == "complete"
    assert response.usage == %{input_tokens: 12, output_tokens: 34}
    assert response.session_id == "session-1"
    assert response.terminal == terminal
    assert length(response.events) == 1_000

    assert response.event_coverage == %{
             mode: :compact,
             observed_events: 1_502,
             retained_events: 1_000,
             omitted_events: 502,
             retained_bytes: response.event_coverage.retained_bytes,
             first_omission: %{limit: :events, event_kind: :text}
           }

    session = :gen_statem.call(GenAgent.whereis(name), :get_backend_session)
    assert session.session_id == "session-1"
    {next_ref, :ok, 1_503} = tell_and_wait(name, "after compact turn")
    assert {:ok, :completed, next_response} = GenAgent.poll(name, next_ref)
    assert next_response.event_coverage.mode == :exact
  end

  test "compact retention handles oversized tool results without losing callbacks" do
    results =
      for _ <- 1..17,
          do: Event.new(:tool_result, %{content: String.duplicate("r", 64 * 1_024)})

    terminal = Event.new(:result, %{text: "finished"})
    name = start_agent([results ++ [terminal]])

    {ref, :ok, 18} = tell_and_wait(name, "read files")
    assert {:ok, :completed, response} = GenAgent.poll(name, ref)
    assert response.text == "finished"
    assert response.terminal == terminal
    assert response.event_coverage.mode == :compact

    assert response.event_coverage.first_omission ==
             %{limit: :bytes, event_kind: :tool_result}

    assert response.event_coverage.observed_events == 18
    assert response.event_coverage.retained_bytes <= 1_048_576
    assert length(response.events) == response.event_coverage.retained_events
  end

  test "compact text fallback uses omitted deltas and respects terminal empty text" do
    first = Event.new(:text, %{text: "first"})
    second = Event.new(:text, %{text: "second", message_boundary: true})
    usage = Event.new(:usage, %{output_tokens: 2})

    name =
      start_agent(
        [
          [first, second, usage, Event.new(:result, %{})],
          [first, second, Event.new(:result, %{text: ""})]
        ],
        max_events_per_turn: 1
      )

    {ref, :ok, 4} = tell_and_wait(name, "fallback")
    assert {:ok, :completed, response} = GenAgent.poll(name, ref)
    assert response.text == "first\n\nsecond"
    assert response.final_message == "second"
    assert response.usage == %{output_tokens: 2}
    assert response.events == [first]
    assert response.event_coverage.omitted_events == 3

    {next_ref, :ok, 7} = tell_and_wait(name, "empty terminal")
    assert {:ok, :completed, next_response} = GenAgent.poll(name, next_ref)
    assert next_response.text == ""
    assert next_response.final_message == ""
  end

  test "lossless retention rejects a terminal result after many small events" do
    text_events = for _ <- 1..1_000, do: Event.new(:text, %{text: "x"})
    first_script = text_events ++ [Event.new(:result, %{text: "complete"})]
    second_script = [Event.new(:result, %{text: "next turn"})]
    name = start_agent([first_script, second_script], event_retention: :lossless)

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

    name =
      start_agent([[oversized, normal], [normal]],
        max_event_bytes_per_turn: 256,
        event_retention: :lossless
      )

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

    name =
      start_agent([[text, error]],
        max_event_bytes_per_turn: text_bytes + 1,
        event_retention: :lossless
      )

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

    name =
      start_agent([script, [Event.new(:result, %{text: "after"})]],
        max_events_per_turn: 3,
        event_retention: :lossless
      )

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

    name =
      start_agent([script, [Event.new(:result, %{text: "next"})]],
        max_events_per_turn: 1,
        event_retention: :lossless
      )

    assert {:ok, ref} = GenAgent.tell(name, "interrupt")
    assert_receive {:waiting_to_overflow, task_pid}
    task_monitor = Process.monitor(task_pid)

    assert :ok = GenAgent.interrupt(name)
    assert_killed_or_gone(task_monitor, task_pid)
    assert_receive {:decision, ^ref, {:error, :interrupted}, 0}
    assert {:error, :interrupted} = GenAgent.poll(name, ref)

    {next_ref, :ok, 1} = tell_and_wait(name, "next")
    assert {:ok, :completed, %{text: "next"}} = GenAgent.poll(name, next_ref)
  end
end
