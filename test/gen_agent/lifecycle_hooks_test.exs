defmodule GenAgent.LifecycleHooksTest do
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

  defp start_server(task_sup, scripts, init_opts \\ []) do
    opts = [
      name: "lifecycle-test-#{System.unique_integer([:positive])}",
      backend: Mock,
      module: TestAgent,
      task_supervisor: task_sup,
      init_opts: Keyword.merge([scripts: scripts], init_opts),
      watchdog_ms: 5_000
    ]

    {:ok, pid} = Server.start_link(opts)

    on_exit(fn ->
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
  defp notify(pid, event), do: :gen_statem.cast(pid, {:notify, event})

  # ---------------------------------------------------------------------------
  # pre_run
  # ---------------------------------------------------------------------------

  describe "pre_run/1" do
    test "fires after init, before the first turn", %{task_sup: task_sup} do
      pre_run = fn state ->
        {:ok, %{state | extra: Map.put(state.extra, :pre_run_ran, true)}}
      end

      pid =
        start_server(task_sup, [result_events("ok")],
          notify_pid: self(),
          pre_run: pre_run
        )

      # Give the internal :pre_run event time to fire.
      assert_receive {:test_agent, :pre_run, _}, 500

      assert status(pid).agent_state.extra[:pre_run_ran] == true
    end

    test "fires before any prompt dispatches", %{task_sup: task_sup} do
      parent = self()

      pre_run = fn state ->
        send(parent, {:ordering, :pre_run})
        {:ok, state}
      end

      responder = fn _ref, _resp, state ->
        send(parent, {:ordering, :handle_response})
        {:noreply, state}
      end

      pid =
        start_server(task_sup, [result_events("ok")],
          pre_run: pre_run,
          responder: responder
        )

      assert {:ok, _} = ask(pid, "go")

      assert_received {:ordering, :pre_run}
      assert_received {:ordering, :handle_response}
    end

    test "error return stops the agent with :pre_run_failed", %{task_sup: task_sup} do
      pre_run = fn _state -> {:error, :setup_impossible} end

      Process.flag(:trap_exit, true)

      pid =
        start_server(task_sup, [result_events("ok")],
          pre_run: pre_run,
          notify_pid: self()
        )

      assert_receive {:EXIT, ^pid, {:pre_run_failed, :setup_impossible}}, 500
      # terminate_agent is called with the stop reason.
      assert_received {:test_agent, :terminate_agent, {:pre_run_failed, :setup_impossible}}
    end

    test "crash stops the agent with :pre_run_crashed", %{task_sup: task_sup} do
      pre_run = fn _state -> raise "boom" end

      Process.flag(:trap_exit, true)

      pid =
        start_server(task_sup, [result_events("ok")],
          pre_run: pre_run,
          notify_pid: self()
        )

      assert_receive {:EXIT, ^pid, {:pre_run_crashed, %RuntimeError{message: "boom"}}}, 500
      assert_received {:test_agent, :terminate_agent, {:pre_run_crashed, _}}
    end
  end

  # ---------------------------------------------------------------------------
  # pre_turn
  # ---------------------------------------------------------------------------

  describe "pre_turn/2" do
    test "fires before each dispatch with the prompt", %{task_sup: task_sup} do
      pid =
        start_server(task_sup, [result_events("ok")], notify_pid: self())

      assert {:ok, _} = ask(pid, "hello")
      assert_received {:test_agent, :pre_turn, {"hello", _}}
    end

    test ":ok can rewrite the prompt", %{task_sup: task_sup} do
      parent = self()

      pre_turn = fn prompt, state ->
        send(parent, {:rewrote, prompt})
        {:ok, "[prefix] " <> prompt, state}
      end

      # Mock backend records the prompt it receives in Mock state;
      # use the result events but also assert the rewritten prompt
      # reached the dispatch via telemetry (below test covers telemetry).
      pid =
        start_server(task_sup, [result_events("ok")], pre_turn: pre_turn)

      assert {:ok, _} = ask(pid, "hello")
      assert_received {:rewrote, "hello"}
    end

    test ":skip delivers :pre_turn_skipped to ask caller", %{task_sup: task_sup} do
      pre_turn = fn _prompt, state -> {:skip, state} end

      pid =
        start_server(task_sup, [result_events("ok")], pre_turn: pre_turn)

      assert {:error, :pre_turn_skipped} = ask(pid, "anything")
      # Agent should still be :idle and accepting work (the script is
      # untouched because the turn never dispatched).
      assert status(pid).state == :idle
    end

    test ":halt stops dispatch and fires post_run", %{task_sup: task_sup} do
      parent = self()

      pre_turn = fn _prompt, state -> {:halt, state} end

      post_run = fn state ->
        send(parent, {:post_run_fired, state})
        :ok
      end

      pid =
        start_server(task_sup, [result_events("ok")],
          pre_turn: pre_turn,
          post_run: post_run,
          notify_pid: self()
        )

      assert {:error, :pre_turn_halted} = ask(pid, "anything")
      assert_received {:post_run_fired, _}
      assert status(pid).halted == true
    end

    test "crash is caught and turn is skipped", %{task_sup: task_sup} do
      pre_turn = fn _prompt, _state -> raise "templating bug" end

      pid =
        start_server(task_sup, [result_events("ok")], pre_turn: pre_turn)

      assert {:error, :pre_turn_skipped} = ask(pid, "anything")
      # Agent is still alive and :idle.
      assert status(pid).state == :idle
    end
  end

  # ---------------------------------------------------------------------------
  # post_turn
  # ---------------------------------------------------------------------------

  describe "post_turn/3" do
    test "fires after handle_response on success", %{task_sup: task_sup} do
      parent = self()

      post_turn = fn outcome, _ref, state ->
        send(parent, {:post_turn_outcome, outcome})
        {:ok, %{state | extra: Map.put(state.extra, :post_turn_ran, true)}}
      end

      pid =
        start_server(task_sup, [result_events("hello")], post_turn: post_turn)

      assert {:ok, _} = ask(pid, "go")
      assert_receive {:post_turn_outcome, {:ok, %GenAgent.Response{}}}
      assert status(pid).agent_state.extra[:post_turn_ran] == true
    end

    test "fires after handle_error on failure", %{task_sup: task_sup} do
      parent = self()

      post_turn = fn outcome, _ref, state ->
        send(parent, {:post_turn_outcome, outcome})
        {:ok, state}
      end

      pid =
        start_server(task_sup, [{:error, :backend_down}], post_turn: post_turn)

      assert {:error, :backend_down} = ask(pid, "go")
      assert_receive {:post_turn_outcome, {:error, :backend_down}}
    end

    test "runs between decision callback and transition", %{task_sup: task_sup} do
      parent = self()

      responder = fn _ref, _resp, state ->
        send(parent, {:ordering, :handle_response})
        {:noreply, state}
      end

      post_turn = fn _outcome, _ref, state ->
        send(parent, {:ordering, :post_turn})
        {:ok, state}
      end

      pid =
        start_server(task_sup, [result_events("ok")],
          responder: responder,
          post_turn: post_turn
        )

      assert {:ok, _} = ask(pid, "go")
      assert_received {:ordering, :handle_response}
      assert_received {:ordering, :post_turn}
    end

    test "crash is caught and transition proceeds", %{task_sup: task_sup} do
      post_turn = fn _outcome, _ref, _state -> raise "hook bug" end

      pid =
        start_server(task_sup, [result_events("ok")], post_turn: post_turn)

      # Decision callback already ran and the transition to :idle
      # still completes; the caller gets the response.
      assert {:ok, _} = ask(pid, "go")
      assert status(pid).state == :idle
    end
  end

  # ---------------------------------------------------------------------------
  # post_run
  # ---------------------------------------------------------------------------

  describe "post_run/1" do
    test "fires on {:halt, state} from handle_response", %{task_sup: task_sup} do
      parent = self()

      responder = fn _ref, _resp, state -> {:halt, state} end
      post_run = fn state -> send(parent, {:post_run_fired, state}) end

      pid =
        start_server(task_sup, [result_events("done")],
          responder: responder,
          post_run: post_run
        )

      assert {:ok, _} = ask(pid, "go")
      assert_receive {:post_run_fired, _}
      assert status(pid).halted == true
    end

    test "fires on {:halt, state} from handle_event", %{task_sup: task_sup} do
      parent = self()

      event_handler = fn _event, state -> {:halt, state} end
      post_run = fn state -> send(parent, {:post_run_fired, state}) end

      pid =
        start_server(task_sup, [],
          event_handler: event_handler,
          post_run: post_run
        )

      notify(pid, :stop)
      assert_receive {:post_run_fired, _}
      assert status(pid).halted == true
    end

    test "does NOT fire on normal stop/terminate_agent", %{task_sup: task_sup} do
      parent = self()
      post_run = fn state -> send(parent, {:post_run_fired, state}) end

      pid =
        start_server(task_sup, [result_events("ok")],
          post_run: post_run,
          notify_pid: self()
        )

      assert {:ok, _} = ask(pid, "go")
      :gen_statem.stop(pid, :normal, 1_000)

      refute_received {:post_run_fired, _}
      assert_received {:test_agent, :terminate_agent, :normal}
    end

    test "fires exactly once per halt", %{task_sup: task_sup} do
      parent = self()

      responder = fn _ref, _resp, state -> {:halt, state} end

      post_run = fn state ->
        send(parent, :post_run_fired)
        state
      end

      pid =
        start_server(task_sup, [result_events("done")],
          responder: responder,
          post_run: post_run
        )

      assert {:ok, _} = ask(pid, "go")
      assert_receive :post_run_fired

      # Ensure no duplicate.
      refute_receive :post_run_fired, 100

      assert status(pid).halted == true
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry enrichment
  # ---------------------------------------------------------------------------

  describe "telemetry metadata enrichment" do
    test "prompt.start carries prompt, original_prompt, rewritten flag, agent_state",
         %{task_sup: task_sup} do
      parent = self()
      handler_id = "lc-prompt-start-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:gen_agent, :prompt, :start],
        fn _event, _measurements, meta, _ ->
          send(parent, {:tel_start, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      pre_turn = fn prompt, state -> {:ok, "[rewritten] " <> prompt, state} end

      pid =
        start_server(task_sup, [result_events("ok")], pre_turn: pre_turn)

      assert {:ok, _} = ask(pid, "hello")

      assert_receive {:tel_start, meta}, 500
      assert meta.prompt == "[rewritten] hello"
      assert meta.original_prompt == "hello"
      assert meta.rewritten == true
      assert %TestAgent.State{} = meta.agent_state
    end

    test "prompt.start rewritten flag is false when pre_turn is identity",
         %{task_sup: task_sup} do
      parent = self()
      handler_id = "lc-prompt-start-id-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:gen_agent, :prompt, :start],
        fn _event, _measurements, meta, _ -> send(parent, {:tel_start, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      pid = start_server(task_sup, [result_events("ok")])
      assert {:ok, _} = ask(pid, "hello")

      assert_receive {:tel_start, meta}, 500
      assert meta.rewritten == false
      assert meta.prompt == "hello"
      assert meta.original_prompt == "hello"
    end

    test "halted event carries agent_state", %{task_sup: task_sup} do
      parent = self()
      handler_id = "lc-halted-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:gen_agent, :halted],
        fn _event, _measurements, meta, _ -> send(parent, {:tel_halted, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      responder = fn _ref, _resp, state -> {:halt, state} end

      pid =
        start_server(task_sup, [result_events("done")], responder: responder)

      assert {:ok, _} = ask(pid, "go")
      assert_receive {:tel_halted, meta}, 500
      assert %TestAgent.State{} = meta.agent_state
    end
  end
end
