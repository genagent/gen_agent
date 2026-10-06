defmodule GenAgent.StreamToTest do
  use ExUnit.Case, async: false

  alias GenAgent.Event

  defmodule Backend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts), do: {:ok, opts}

    @impl true
    def prompt(session, prompt) do
      send(session[:observer], {:started, prompt, self()})

      case prompt do
        "error" ->
          {:error, :backend_failed}

        "many" ->
          {:ok, events(["a", "b", "c"]) ++ [Event.new(:result, %{text: "done"})], session}

        "gated" ->
          # Emits one event, parks until released, then finishes. The gate
          # message tells the test the first event has been consumed.
          stream =
            Stream.flat_map([:first, :gate, :rest], fn
              :first ->
                events(["a"])

              :gate ->
                send(session[:observer], {:gate, self()})

                receive do
                  :release -> []
                after
                  5_000 -> []
                end

              :rest ->
                events(["b"]) ++ [Event.new(:result, %{text: "done"})]
            end)

          {:ok, stream, session}

        _ ->
          {:ok, events([prompt]) ++ [Event.new(:result, %{text: prompt})], session}
      end
    end

    defp events(texts), do: Enum.map(texts, &Event.new(:text, %{text: &1}))

    @impl true
    def terminate_session(_session), do: :ok
  end

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, opts, %{observer: Keyword.fetch!(opts, :observer)}}

    @impl true
    def pre_turn("skip", state), do: {:skip, state}
    def pre_turn("halt", state), do: {:halt, state}
    def pre_turn(prompt, state), do: {:ok, prompt, state}

    @impl true
    def handle_stream_event(event, state) do
      send(state.observer, {:callback, event.data[:text]})
      state
    end

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  defp start_agent(opts \\ []) do
    name = "stream-to-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      GenAgent.start_agent(
        Agent,
        Keyword.merge([name: name, backend: Backend, observer: self(), watchdog_ms: 10_000], opts)
      )

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    {name, pid}
  end

  defp tell(name, prompt, opts \\ []) do
    GenAgent.tell_with_completion(name, prompt, self(), 5_000, opts)
  end

  # Takes the next gen_agent message in mailbox order, so a reordering of
  # events and completion fails the assertion that follows.
  defp next_msg(timeout \\ 1_000) do
    receive do
      {:gen_agent, _, _, _, _} = msg -> msg
    after
      timeout -> flunk("no gen_agent message within #{timeout}ms")
    end
  end

  defp assert_text_event(name, ref, text) do
    assert {:gen_agent, :event, ^name, ^ref, %Event{kind: :text, data: %{text: ^text}}} =
             next_msg()
  end

  defp recipients(pid) do
    {_state, data} = :sys.get_state(pid)
    data.stream_recipients
  end

  test "events arrive in order, tagged with the ref, before completion" do
    {name, pid} = start_agent()
    assert {:ok, ref} = tell(name, "many", stream_to: self())

    for text <- ["a", "b", "c"], do: assert_text_event(name, ref, text)

    assert {:gen_agent, :event, ^name, ^ref, %Event{kind: :result}} = next_msg()
    assert {:gen_agent, :completion, ^name, ^ref, {:ok, _}} = next_msg()
    refute_received {:gen_agent, _, _, _, _}
    assert recipients(pid) == %{}
  end

  test "the callback runs before the event is relayed" do
    {name, _pid} = start_agent()
    assert {:ok, ref} = tell(name, "one", stream_to: self())
    assert_receive {:callback, "one"}, 1_000
    assert_receive {:gen_agent, :event, ^name, ^ref, %Event{data: %{text: "one"}}}, 1_000
  end

  test "streaming is off by default" do
    {name, _pid} = start_agent()
    assert {:ok, ref} = tell(name, "one")
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, _}}, 1_000
    refute_received {:gen_agent, :event, _, _, _}

    assert {:ok, ref} = tell(name, "one", stream_to: nil)
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, _}}, 1_000
    refute_received {:gen_agent, :event, _, _, _}
  end

  test "stream_to must be nil or a pid" do
    {name, _pid} = start_agent()

    for bad <- [:me, "pid", {:global, :x}] do
      assert_raise ArgumentError, ~r/stream_to/, fn -> tell(name, "one", stream_to: bad) end
    end
  end

  test "a separate recipient receives events and the completion recipient does not" do
    {name, _pid} = start_agent()
    test_pid = self()

    sink =
      spawn_link(fn ->
        receive do
          {:gen_agent, :event, _, _, _} = msg -> send(test_pid, {:sink, msg})
        end
      end)

    assert {:ok, ref} = tell(name, "one", stream_to: sink)
    assert_receive {:sink, {:gen_agent, :event, ^name, ^ref, %Event{data: %{text: "one"}}}}, 1_000
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, _}}, 1_000
    refute_received {:gen_agent, :event, _, _, _}
  end

  test "queued requests stream only their own events, in FIFO order" do
    {name, _pid} = start_agent()
    assert {:ok, first} = tell(name, "gated", stream_to: self())
    assert_receive {:gate, task}, 1_000
    assert {:ok, second} = tell(name, "two", stream_to: self())
    send(task, :release)

    assert_text_event(name, first, "a")
    assert_text_event(name, first, "b")
    assert {:gen_agent, :event, ^name, ^first, %Event{kind: :result}} = next_msg()
    assert {:gen_agent, :completion, ^name, ^first, {:ok, _}} = next_msg()
    assert_text_event(name, second, "two")
    assert {:gen_agent, :event, ^name, ^second, %Event{kind: :result}} = next_msg()
    assert {:gen_agent, :completion, ^name, ^second, {:ok, _}} = next_msg()
  end

  test "cancelling a queued request drops its recipient and streams nothing" do
    {name, pid} = start_agent()
    assert {:ok, first} = tell(name, "gated")
    assert_receive {:gate, task}, 1_000
    assert {:ok, queued} = tell(name, "two", stream_to: self())
    assert map_size(recipients(pid)) == 1

    assert {:ok, :cancelled} = GenAgent.cancel_request(name, queued)
    assert recipients(pid) == %{}
    assert_receive {:gen_agent, :completion, ^name, ^queued, {:error, :cancelled}}, 1_000

    send(task, :release)
    assert_receive {:gen_agent, :completion, ^name, ^first, {:ok, _}}, 1_000
    refute_received {:gen_agent, :event, _, _, _}
  end

  test "pre-turn skip and halt produce no events and leave no recipient" do
    {name, pid} = start_agent()

    for {prompt, reason} <- [{"skip", :pre_turn_skipped}, {"halt", :pre_turn_halted}] do
      assert {:ok, ref} = tell(name, prompt, stream_to: self())
      assert_receive {:gen_agent, :completion, ^name, ^ref, {:error, ^reason}}, 1_000
      assert recipients(pid) == %{}
    end

    refute_received {:gen_agent, :event, _, _, _}
  end

  test "halt-aware rejection returns :halted and registers nothing" do
    {name, pid} = start_agent()
    assert {:ok, ref} = tell(name, "halt")
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:error, :pre_turn_halted}}, 1_000

    assert {:error, :halted} = tell(name, "one", on_halt: :fail, stream_to: self())
    assert recipients(pid) == %{}
  end

  test "an opted-in queued request failed by a halt leaves no recipient" do
    {name, pid} = start_agent()
    assert {:ok, _first} = tell(name, "gated")
    assert_receive {:gate, task}, 1_000
    assert {:ok, halter} = tell(name, "halt")
    assert {:ok, queued} = tell(name, "two", on_halt: :fail, stream_to: self())

    send(task, :release)
    assert_receive {:gen_agent, :completion, ^name, ^halter, {:error, :pre_turn_halted}}, 1_000
    assert_receive {:gen_agent, :completion, ^name, ^queued, {:error, :halted}}, 1_000
    assert recipients(pid) == %{}
    refute_received {:gen_agent, :event, _, _, _}
  end

  test "overload rejects without registering a recipient" do
    {name, pid} = start_agent(max_pending_prompts: 1)
    assert {:ok, _} = tell(name, "gated")
    assert_receive {:gate, task}, 1_000
    assert {:ok, _} = tell(name, "two", stream_to: self())
    assert {:error, {:overloaded, _}} = tell(name, "three", stream_to: self())
    assert map_size(recipients(pid)) == 1
    send(task, :release)
    assert_receive {:gen_agent, :completion, _, _, _}, 1_000
    assert_receive {:gen_agent, :completion, _, _, _}, 1_000
    assert recipients(pid) == %{}
  end

  test "backend failure before a stream produces no events" do
    {name, pid} = start_agent()
    assert {:ok, ref} = tell(name, "error", stream_to: self())
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:error, :backend_failed}}, 1_000
    assert recipients(pid) == %{}
    refute_received {:gen_agent, :event, _, _, _}
  end

  test "interrupt stops relaying for the interrupted ref only" do
    {name, _pid} = start_agent()
    assert {:ok, ref} = tell(name, "gated", stream_to: self())
    assert_receive {:gate, _task}, 1_000
    assert_receive {:gen_agent, :event, ^name, ^ref, %Event{data: %{text: "a"}}}, 1_000

    assert {:ok, :accepted} = GenAgent.interrupt_request(name, ref)
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:error, :interrupted}}, 1_000

    assert {:ok, next} = tell(name, "two", stream_to: self())
    assert_text_event(name, next, "two")
    assert {:gen_agent, :event, ^name, ^next, %Event{kind: :result}} = next_msg()
    assert {:gen_agent, :completion, ^name, ^next, {:ok, _}} = next_msg()
    refute_received {:gen_agent, :event, ^name, ^ref, _}
  end

  test "watchdog timeout stops relaying" do
    {name, _pid} = start_agent(watchdog_ms: 200)
    assert {:ok, ref} = tell(name, "gated", stream_to: self())
    assert_receive {:gate, _task}, 1_000
    assert_receive {:gen_agent, :event, ^name, ^ref, %Event{data: %{text: "a"}}}, 1_000
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:error, :timeout}}, 2_000
    refute_received {:gen_agent, :event, ^name, ^ref, _}
  end

  test "forged and stale relay messages are not forwarded" do
    {name, pid} = start_agent()
    assert {:ok, ref} = tell(name, "gated", stream_to: self())
    assert_receive {:gate, task}, 1_000
    assert_receive {:gen_agent, :event, ^name, ^ref, %Event{data: %{text: "a"}}}, 1_000

    {_state, data} = :sys.get_state(pid)
    active_tag = data.current_request.stream_tag
    stale = make_ref()
    send(pid, {:gen_agent_stream, stale, active_tag, Event.new(:text, %{text: "stale"})})
    send(pid, {:gen_agent_stream, ref, make_ref(), Event.new(:text, %{text: "forged"})})
    _ = GenAgent.status(name)
    refute_received {:gen_agent, :event, ^name, ^ref, %Event{data: %{text: "forged"}}}
    send(task, :release)

    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, _}}, 1_000
    send(pid, {:gen_agent_stream, ref, active_tag, Event.new(:text, %{text: "late"})})
    # A synchronous call to the agent orders after both injected messages.
    _ = GenAgent.status(name)
    refute_received {:gen_agent, :event, _, ^stale, _}
    refute_received {:gen_agent, :event, ^name, ^ref, %Event{data: %{text: "late"}}}
  end

  test "a dead recipient does not stop the agent" do
    {name, pid} = start_agent()
    dead = spawn(fn -> :ok end)
    mon = Process.monitor(dead)
    assert_receive {:DOWN, ^mon, :process, ^dead, _}, 1_000

    assert {:ok, ref} = tell(name, "many", stream_to: dead)
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, _}}, 1_000
    assert Process.alive?(pid)
  end

  test "compact retention relays events omitted from retained history" do
    {name, _pid} = start_agent(event_retention: :compact, max_events_per_turn: 1)
    assert {:ok, ref} = tell(name, "many", stream_to: self())

    for text <- ["a", "b", "c"], do: assert_text_event(name, ref, text)

    assert {:gen_agent, :event, ^name, ^ref, %Event{kind: :result}} = next_msg()
    assert {:gen_agent, :completion, ^name, ^ref, {:ok, _}} = next_msg()
  end

  test "lossless retention does not relay the event rejected for overflow" do
    {name, _pid} = start_agent(event_retention: :lossless, max_events_per_turn: 2)
    assert {:ok, ref} = tell(name, "many", stream_to: self())

    assert_text_event(name, ref, "a")
    assert_text_event(name, ref, "b")

    assert {:gen_agent, :completion, ^name, ^ref, {:error, {:event_capture_overflow, _}}} =
             next_msg()

    refute_received {:gen_agent, _, _, _, _}
  end

  test "an unavailable task supervisor fails once with no events and no recipient" do
    sup_name = :"stream_to_sup_#{System.unique_integer([:positive])}"
    {:ok, sup} = Task.Supervisor.start_link(name: sup_name)

    {:ok, pid} =
      GenAgent.Server.start_link(
        name: "stream-to-nosup",
        backend: Backend,
        module: Agent,
        task_supervisor: sup_name,
        init_opts: [observer: self()],
        watchdog_ms: 10_000
      )

    on_exit(fn ->
      try do
        :gen_statem.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    Supervisor.stop(sup)
    assert Process.whereis(sup_name) == nil

    assert {:ok, ref} =
             :gen_statem.call(pid, {:tell_with_completion, "one", self(), :queue, self()})

    assert {:gen_agent, :completion, "stream-to-nosup", ^ref,
            {:error, :task_supervisor_unavailable}} = next_msg()

    refute_received {:gen_agent, _, _, _, _}
    refute_received {:started, _, _}
    assert Process.alive?(pid)
    assert recipients(pid) == %{}
  end
end
