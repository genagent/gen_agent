defmodule GenAgent.ServerTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgent.Server
  alias GenAgent.Support.TestAgent

  setup do
    sup_name = :"task_sup_#{System.unique_integer([:positive])}"
    task_sup = start_supervised!({Task.Supervisor, name: sup_name})
    %{task_sup: task_sup}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_server(task_sup, scripts, init_opts \\ [], server_opts \\ []) do
    opts =
      [
        name: "test",
        backend: Mock,
        module: TestAgent,
        task_supervisor: task_sup,
        init_opts: Keyword.merge([scripts: scripts], init_opts),
        watchdog_ms: Keyword.get(server_opts, :watchdog_ms, 5_000)
      ]

    {:ok, pid} = Server.start_link(opts)

    on_exit(fn ->
      # With trap_exit enabled in Server.init, the server will catch
      # the test process's normal exit and terminate itself via the
      # {:EXIT, parent, :normal} path before on_exit runs. Guard
      # against the race where :gen_statem.stop hits an
      # already-shutting-down process.
      if Process.alive?(pid) do
        try do
          :gen_statem.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    pid
  end

  defp result_events(text), do: [Event.new(:result, %{text: text})]

  defp status(pid), do: :gen_statem.call(pid, :status)
  defp ask(pid, prompt), do: :gen_statem.call(pid, {:ask, prompt})
  defp tell(pid, prompt), do: :gen_statem.call(pid, {:tell, prompt})
  defp poll(pid, ref), do: :gen_statem.call(pid, {:poll, ref})
  defp notify(pid, event), do: :gen_statem.cast(pid, {:notify, event})
  defp interrupt(pid), do: :gen_statem.cast(pid, :interrupt)
  defp resume(pid), do: :gen_statem.cast(pid, :resume)

  # ---------------------------------------------------------------------------
  # Startup
  # ---------------------------------------------------------------------------

  describe "startup" do
    test "starts in :idle with no current request", %{task_sup: task_sup} do
      pid = start_server(task_sup, [])
      s = status(pid)

      assert s.state == :idle
      assert s.queued == 0
      assert s.current_request == nil
      refute s.halted
    end
  end

  # ---------------------------------------------------------------------------
  # ask -- happy path
  # ---------------------------------------------------------------------------

  describe "ask/2" do
    test "returns {:ok, response} with the assembled text", %{task_sup: task_sup} do
      pid = start_server(task_sup, [result_events("hello")])

      assert {:ok, response} = ask(pid, "hi")
      assert response.text == "hello"
      assert %Event{kind: :result} = List.last(response.events)
    end

    test "returns the agent to :idle after the turn", %{task_sup: task_sup} do
      pid = start_server(task_sup, [result_events("ok")])
      {:ok, _} = ask(pid, "go")

      assert status(pid).state == :idle
    end

    test "propagates a synchronous backend error to the caller", %{task_sup: task_sup} do
      pid = start_server(task_sup, [{:error, :backend_down}])

      assert {:error, :backend_down} = ask(pid, "ping")
      assert status(pid).state == :idle
    end

    test "queues a second ask while one is in-flight and replies to both",
         %{task_sup: task_sup} do
      slow_first = fn _prompt ->
        Stream.resource(
          fn -> :start end,
          fn
            :start -> {[Event.new(:result, %{text: "first"})], :done}
            :done -> {:halt, :done}
          end,
          fn _ -> :ok end
        )
      end

      pid = start_server(task_sup, [slow_first, result_events("second")])

      task1 = Task.async(fn -> ask(pid, "a") end)
      # Give task1 a chance to enter :processing.
      Process.sleep(20)
      task2 = Task.async(fn -> ask(pid, "b") end)

      assert {:ok, r1} = Task.await(task1)
      assert {:ok, r2} = Task.await(task2)

      assert r1.text == "first"
      assert r2.text == "second"
    end
  end

  # ---------------------------------------------------------------------------
  # tell + poll
  # ---------------------------------------------------------------------------

  describe "tell/2 + poll/2" do
    test "returns a ref and makes the result pollable", %{task_sup: task_sup} do
      pid = start_server(task_sup, [result_events("async")])

      {:ok, ref} = tell(pid, "do it")
      # Spin briefly for the task to finish.
      Process.sleep(20)

      assert {:ok, :completed, response} = poll(pid, ref)
      assert response.text == "async"
    end

    test "poll returns :pending while a tell is queued behind another prompt",
         %{task_sup: task_sup} do
      slow_first = fn _prompt ->
        Stream.resource(
          fn -> :start end,
          fn
            :start ->
              Process.sleep(50)
              {[Event.new(:result, %{text: "first"})], :done}

            :done ->
              {:halt, :done}
          end,
          fn _ -> :ok end
        )
      end

      pid = start_server(task_sup, [slow_first, result_events("second")])

      _ask_task = Task.async(fn -> ask(pid, "a") end)
      Process.sleep(10)
      {:ok, ref} = tell(pid, "b")

      assert {:ok, :pending} = poll(pid, ref)
    end

    test "poll returns {:error, :not_found} for unknown refs", %{task_sup: task_sup} do
      pid = start_server(task_sup, [])
      assert {:error, :not_found} = poll(pid, make_ref())
    end

    test "poll returns the error for a failed tell", %{task_sup: task_sup} do
      pid = start_server(task_sup, [{:error, :nope}])

      {:ok, ref} = tell(pid, "fail")
      Process.sleep(20)

      assert {:error, :nope} = poll(pid, ref)
    end
  end

  # ---------------------------------------------------------------------------
  # Self-chain -- handle_response returns {:prompt, ...}
  # ---------------------------------------------------------------------------

  describe "self-chain via {:prompt, ...}" do
    test "immediately dispatches a second turn", %{task_sup: task_sup} do
      responder = fn
        _ref, %{text: "first"}, state -> {:prompt, "go again", state}
        _ref, %{text: "second"}, state -> {:noreply, state}
      end

      pid =
        start_server(
          task_sup,
          [result_events("first"), result_events("second")],
          responder: responder
        )

      {:ok, response} = ask(pid, "start")
      assert response.text == "first"

      # After the ask returns, the self-chain is in flight or already done.
      # Give it a moment.
      Process.sleep(30)

      s = status(pid)
      assert s.state == :idle
      assert length(s.agent_state.responses) == 2
    end

    test "self-chain runs ahead of mailbox-queued prompts", %{task_sup: task_sup} do
      responder = fn
        _ref, %{text: "first"}, state -> {:prompt, "chained", state}
        _ref, _response, state -> {:noreply, state}
      end

      pid =
        start_server(
          task_sup,
          [
            fn _ ->
              Stream.resource(
                fn -> :s end,
                fn
                  :s ->
                    Process.sleep(30)
                    {[Event.new(:result, %{text: "first"})], :d}

                  :d ->
                    {:halt, :d}
                end,
                fn _ -> :ok end
              )
            end,
            result_events("chained"),
            result_events("queued")
          ],
          responder: responder
        )

      ask_task = Task.async(fn -> ask(pid, "a") end)
      Process.sleep(5)
      queued_tell = Task.async(fn -> tell(pid, "b") end)

      assert {:ok, %{text: "first"}} = Task.await(ask_task)
      {:ok, _ref} = Task.await(queued_tell)

      Process.sleep(50)

      # Order of responses in agent_state: first, chained (self-chain), queued (mailbox).
      texts =
        status(pid).agent_state.responses
        |> Enum.map(fn {_ref, r} -> r.text end)

      assert texts == ["first", "chained", "queued"]
    end
  end

  # ---------------------------------------------------------------------------
  # Halt + resume
  # ---------------------------------------------------------------------------

  describe "halt + resume" do
    test "halt freezes the mailbox until resume", %{task_sup: task_sup} do
      responder = fn
        _ref, %{text: "halt me"}, state -> {:halt, state}
        _ref, _response, state -> {:noreply, state}
      end

      pid =
        start_server(
          task_sup,
          [result_events("halt me"), result_events("after")],
          responder: responder
        )

      {:ok, _} = ask(pid, "first")
      assert status(pid).halted

      {:ok, ref} = tell(pid, "should queue")
      Process.sleep(10)
      assert {:ok, :pending} = poll(pid, ref)
      assert status(pid).queued == 1

      resume(pid)
      Process.sleep(20)

      assert {:ok, :completed, response} = poll(pid, ref)
      assert response.text == "after"
      refute status(pid).halted
    end
  end

  # ---------------------------------------------------------------------------
  # notify / handle_event
  # ---------------------------------------------------------------------------

  describe "notify/2" do
    test "dispatches a prompt returned from handle_event when idle",
         %{task_sup: task_sup} do
      event_handler = fn {:go, what}, state -> {:prompt, "do #{what}", state} end

      pid =
        start_server(
          task_sup,
          [result_events("done")],
          event_handler: event_handler
        )

      notify(pid, {:go, "it"})
      Process.sleep(20)

      s = status(pid)
      assert length(s.agent_state.events) == 1
      assert length(s.agent_state.responses) == 1
    end

    test "halts the agent when handle_event returns :halt", %{task_sup: task_sup} do
      event_handler = fn :stop, state -> {:halt, state} end

      pid = start_server(task_sup, [], event_handler: event_handler)

      notify(pid, :stop)
      Process.sleep(5)

      assert status(pid).halted
    end
  end

  # ---------------------------------------------------------------------------
  # interrupt
  # ---------------------------------------------------------------------------

  describe "interrupt/1" do
    test "kills in-flight task and delivers :interrupted to the ask caller",
         %{task_sup: task_sup} do
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

      pid = start_server(task_sup, [slow])

      caller = Task.async(fn -> ask(pid, "start") end)
      Process.sleep(20)
      interrupt(pid)

      assert {:error, :interrupted} = Task.await(caller)
      assert status(pid).state == :idle
    end
  end

  # ---------------------------------------------------------------------------
  # Task crash
  # ---------------------------------------------------------------------------

  describe "task crash" do
    test "delivers {:task_crashed, reason} to the ask caller", %{task_sup: task_sup} do
      pid = start_server(task_sup, [{:raise, :boom}])

      assert {:error, {:task_crashed, _}} = ask(pid, "go")
      assert status(pid).state == :idle
    end
  end

  # ---------------------------------------------------------------------------
  # Backend session update from :result event data
  # ---------------------------------------------------------------------------

  describe "backend session update" do
    test "update_session is called with the :result event data", %{task_sup: task_sup} do
      events = [
        Event.new(:text, %{text: "hi"}),
        Event.new(:result, %{text: "hi", session_id: "captured-session-1"})
      ]

      pid = start_server(task_sup, [events])

      before = :gen_statem.call(pid, :get_backend_session)
      assert before.session_id == nil

      {:ok, response} = ask(pid, "hello")

      after_turn = :gen_statem.call(pid, :get_backend_session)
      assert after_turn.session_id == "captured-session-1"
      assert response.session_id == "captured-session-1"
    end

    test "backend session survives across turns", %{task_sup: task_sup} do
      scripts = [
        [Event.new(:result, %{text: "a", session_id: "s-1"})],
        [Event.new(:result, %{text: "b"})]
      ]

      pid = start_server(task_sup, scripts)

      {:ok, _} = ask(pid, "first")
      mid = :gen_statem.call(pid, :get_backend_session)
      assert mid.session_id == "s-1"

      {:ok, _} = ask(pid, "second")
      final = :gen_statem.call(pid, :get_backend_session)
      # Second turn's result had no session_id, so the previous one sticks.
      assert final.session_id == "s-1"
    end
  end

  # ---------------------------------------------------------------------------
  # Stream events -- handle_stream_event threading
  # ---------------------------------------------------------------------------

  describe "handle_stream_event" do
    test "is called for every event in order and threads agent_state",
         %{task_sup: task_sup} do
      events = [
        Event.new(:text, %{text: "hel"}),
        Event.new(:text, %{text: "lo"}),
        Event.new(:usage, %{input_tokens: 10, output_tokens: 2}),
        Event.new(:result, %{text: "hello"})
      ]

      pid = start_server(task_sup, [events])
      {:ok, _} = ask(pid, "hi")

      stream_events = status(pid).agent_state.stream_events
      assert Enum.map(stream_events, & &1.kind) == [:text, :text, :usage, :result]
    end

    test "runs inside the task, so state mutations per event are visible to handle_response",
         %{task_sup: task_sup} do
      events = [
        Event.new(:text, %{text: "a"}),
        Event.new(:text, %{text: "b"}),
        Event.new(:text, %{text: "c"}),
        Event.new(:result, %{text: "abc"})
      ]

      # handle_response sees state.stream_events populated by handle_stream_event,
      # which only works if the stream callback ran and threaded state into the
      # final agent_state delivered to handle_response.
      responder = fn _ref, _response, state ->
        send(state.notify_pid, {:stream_event_count, length(state.stream_events)})
        {:noreply, state}
      end

      pid =
        start_server(
          task_sup,
          [events],
          responder: responder,
          notify_pid: self()
        )

      {:ok, _} = ask(pid, "go")

      assert_receive {:stream_event_count, 4}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Watchdog
  # ---------------------------------------------------------------------------

  describe "watchdog" do
    test "fires after the configured timeout and delivers :timeout",
         %{task_sup: task_sup} do
      slow = fn _ ->
        Stream.resource(
          fn -> :s end,
          fn
            :s ->
              Process.sleep(1_000)
              {[Event.new(:result, %{text: "never"})], :d}

            :d ->
              {:halt, :d}
          end,
          fn _ -> :ok end
        )
      end

      pid = start_server(task_sup, [slow], [], watchdog_ms: 50)

      assert {:error, :timeout} = ask(pid, "go")
      assert status(pid).state == :idle
    end
  end

  # ---------------------------------------------------------------------------
  # handle_error/3 callback
  # ---------------------------------------------------------------------------

  describe "handle_error/3" do
    test "is called on synchronous backend error with the reason",
         %{task_sup: task_sup} do
      pid =
        start_server(
          task_sup,
          [{:error, :backend_down}],
          notify_pid: self()
        )

      assert {:error, :backend_down} = ask(pid, "go")

      assert_receive {:test_agent, :handle_error, {_ref, :backend_down}}
      assert status(pid).state == :idle
      assert [{_ref, :backend_down}] = status(pid).agent_state.errors
    end

    test "is called on a terminal :error event from the stream",
         %{task_sup: task_sup} do
      events = [Event.new(:error, %{reason: :rate_limited})]

      pid = start_server(task_sup, [events], notify_pid: self())

      assert {:error, :rate_limited} = ask(pid, "go")

      assert_receive {:test_agent, :handle_error, {_ref, :rate_limited}}
      assert [{_ref, :rate_limited}] = status(pid).agent_state.errors
    end

    test "is called on task crash", %{task_sup: task_sup} do
      pid =
        start_server(
          task_sup,
          [{:raise, :boom}],
          notify_pid: self()
        )

      assert {:error, {:task_crashed, _}} = ask(pid, "go")

      assert_receive {:test_agent, :handle_error, {_ref, {:task_crashed, _}}}
      assert [{_ref, {:task_crashed, _}}] = status(pid).agent_state.errors
    end

    test "is called on watchdog timeout", %{task_sup: task_sup} do
      slow = fn _ ->
        Stream.resource(
          fn -> :s end,
          fn
            :s ->
              Process.sleep(1_000)
              {[Event.new(:result, %{text: "never"})], :d}

            :d ->
              {:halt, :d}
          end,
          fn _ -> :ok end
        )
      end

      pid =
        start_server(
          task_sup,
          [slow],
          [notify_pid: self()],
          watchdog_ms: 50
        )

      assert {:error, :timeout} = ask(pid, "go")

      assert_receive {:test_agent, :handle_error, {_ref, :timeout}}
      assert [{_ref, :timeout}] = status(pid).agent_state.errors
    end

    test "is called on interrupt with reason :interrupted", %{task_sup: task_sup} do
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

      pid = start_server(task_sup, [slow], notify_pid: self())

      caller = Task.async(fn -> ask(pid, "start") end)
      Process.sleep(20)
      interrupt(pid)

      assert {:error, :interrupted} = Task.await(caller)
      assert_receive {:test_agent, :handle_error, {_ref, :interrupted}}
      assert [{_ref, :interrupted}] = status(pid).agent_state.errors
    end

    test "{:prompt, ...} return retries via self-chain", %{task_sup: task_sup} do
      error_handler = fn _ref, :rate_limited, state ->
        {:prompt, "retry after rate limit", state}
      end

      scripts = [
        [Event.new(:error, %{reason: :rate_limited})],
        [Event.new(:result, %{text: "succeeded on retry"})]
      ]

      pid =
        start_server(
          task_sup,
          scripts,
          error_handler: error_handler
        )

      # First turn errors, handle_error triggers retry via self-chain.
      assert {:error, :rate_limited} = ask(pid, "go")

      # Wait for the self-chained retry to land.
      Process.sleep(50)

      s = status(pid)
      assert s.state == :idle
      assert [{_, :rate_limited}] = s.agent_state.errors
      assert [{_, %GenAgent.Response{text: "succeeded on retry"}}] = s.agent_state.responses
    end

    test "{:halt, ...} return halts the agent", %{task_sup: task_sup} do
      error_handler = fn _ref, _reason, state -> {:halt, state} end

      pid =
        start_server(
          task_sup,
          [{:error, :fatal}],
          error_handler: error_handler
        )

      assert {:error, :fatal} = ask(pid, "go")
      assert status(pid).halted
    end

    test "default handle_error is {:noreply, state} (via use GenAgent)",
         %{task_sup: task_sup} do
      # Without an error_handler keyword, TestAgent defaults to noreply,
      # which mirrors the `use GenAgent` default. Verify a failed turn
      # leaves the agent idle and ready for more work.
      pid = start_server(task_sup, [{:error, :boom}, result_events("ok after error")])

      assert {:error, :boom} = ask(pid, "first")
      assert status(pid).state == :idle

      assert {:ok, response} = ask(pid, "second")
      assert response.text == "ok after error"
    end
  end
end
