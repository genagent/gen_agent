defmodule GenAgent.Backends.CodexIntegrationTest do
  @moduledoc """
  End-to-end tests that drive a real `GenAgent` process with the
  Codex backend, but with Codex execution stubbed out via an injected
  `exec_fn`. Exercises the full state-machine path:
  `GenAgent.start_agent/2` -> `GenAgent.ask/2` -> `Codex.prompt/2` ->
  fake exec_fn -> `EventTranslator` -> back into the state machine and
  delivered as a `GenAgent.Response`.

  The live-CLI integration test lives in `codex_live_test.exs`.
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias CodexWrapper.JsonLineEvent

  defmodule CodexAgent do
    use GenAgent

    defmodule State do
      defstruct responses: [], stream_events: [], observer: nil
    end

    @impl true
    def init_agent(opts) do
      backend_opts =
        Keyword.take(opts, [
          :exec_fn,
          :sandbox,
          :skip_git_repo_check,
          :model,
          :cwd,
          :working_dir
        ])

      {:ok, backend_opts, %State{observer: opts[:observer]}}
    end

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      {:noreply, %{state | responses: state.responses ++ [response]}}
    end

    @impl true
    def handle_stream_event(event, %State{} = state) do
      if state.observer, do: send(state.observer, {:stream_event, event.kind})
      %{state | stream_events: state.stream_events ++ [event]}
    end
  end

  defmodule PatternAgent do
    use GenAgent

    @impl true
    def init_agent(_opts) do
      {:ok, [system: "You are a researcher.", max_tokens: 512], %{}}
    end

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  defp event(type, data), do: %JsonLineEvent{event_type: type, data: data, raw: ""}

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "guide-style callback options identify the unsupported Codex option" do
    assert {:error, {:backend_start_failed, {:unsupported_option, :system}}} =
             GenAgent.start_agent(PatternAgent,
               name: unique_name("pattern-codex"),
               backend: GenAgent.Backends.Codex
             )
  end

  defp start_codex_agent(exec_fn, extra_opts \\ []) do
    name = unique_name("codex")

    {:ok, _pid} =
      GenAgent.start_agent(
        CodexAgent,
        [
          name: name,
          backend: GenAgent.Backends.Codex,
          exec_fn: exec_fn
        ] ++ extra_opts
      )

    on_exit(fn ->
      case GenAgent.whereis(name) do
        nil -> :ok
        _ -> GenAgent.stop(name)
      end
    end)

    name
  end

  describe "round trip through GenAgent.ask/2" do
    test "assembles a Response with text from agent_message items" do
      exec_fn = fn _prompt, _session ->
        {:ok,
         [
           event("thread.started", %{"thread_id" => "thread-101"}),
           event("turn.started", %{}),
           event("item.completed", %{
             "item" => %{"type" => "agent_message", "text" => "pong"}
           }),
           event("turn.completed", %{
             "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
           })
         ]}
      end

      name = start_codex_agent(exec_fn)

      assert {:ok, response} = GenAgent.ask(name, "ping")
      assert response.text == "pong"
      assert response.session_id == "thread-101"
      assert Enum.map(response.events, & &1.kind) == [:text, :usage, :result]
      assert response.usage == %{input_tokens: 10, output_tokens: 2}
    end

    test "threads thread_id across multiple turns" do
      test_pid = self()

      exec_fn = fn prompt, session ->
        send(test_pid, {:exec_call, prompt, session.thread_id})

        {:ok,
         [
           event("thread.started", %{"thread_id" => "thread-persist"}),
           event("item.completed", %{
             "item" => %{"type" => "agent_message", "text" => "ack #{prompt}"}
           }),
           event("turn.completed", %{})
         ]}
      end

      name = start_codex_agent(exec_fn)

      {:ok, _} = GenAgent.ask(name, "turn 1")
      assert_receive {:exec_call, "turn 1", nil}

      {:ok, _} = GenAgent.ask(name, "turn 2")
      assert_receive {:exec_call, "turn 2", "thread-persist"}

      {:ok, _} = GenAgent.ask(name, "turn 3")
      assert_receive {:exec_call, "turn 3", "thread-persist"}
    end

    test "delivers :no_terminal_event when turn.completed is missing" do
      exec_fn = fn _prompt, _session ->
        {:ok,
         [
           event("thread.started", %{"thread_id" => "t"}),
           event("item.completed", %{
             "item" => %{"type" => "agent_message", "text" => "partial"}
           })
         ]}
      end

      name = start_codex_agent(exec_fn)

      assert {:error, :no_terminal_event} = GenAgent.ask(name, "go")
    end

    test "delivers error when the exec_fn returns {:error, reason}" do
      exec_fn = fn _prompt, _session -> {:error, :codex_missing} end

      name = start_codex_agent(exec_fn)

      assert {:error, :codex_missing} = GenAgent.ask(name, "hello")
    end

    test "delivers a terminal :error event as the error reason" do
      exec_fn = fn _prompt, _session ->
        {:ok, [event("turn.failed", %{"error" => "sandbox violation"})]}
      end

      name = start_codex_agent(exec_fn)

      assert {:error, "sandbox violation"} = GenAgent.ask(name, "ouch")
    end

    test "a lazy stream continues past an error notification and records a completed thread" do
      test_pid = self()

      exec_fn = fn _prompt, session ->
        send(test_pid, {:thread_id_seen, session.thread_id})

        {:ok,
         Stream.map(
           [
             event("thread.started", %{"thread_id" => "thread-retry"}),
             event("turn.started", %{}),
             event("error", %{"message" => "Reconnecting... 1/5"}),
             event("item.completed", %{
               "item" => %{"type" => "agent_message", "text" => "recovered"}
             }),
             event("turn.completed", %{})
           ],
           fn event ->
             send(test_pid, {:pulled, event.event_type})
             event
           end
         )}
      end

      name = start_codex_agent(exec_fn)

      assert {:ok, %{text: "recovered", session_id: "thread-retry"}} = GenAgent.ask(name, "go")
      assert_receive {:thread_id_seen, nil}

      for type <- ["thread.started", "turn.started", "error", "item.completed", "turn.completed"] do
        assert_receive {:pulled, ^type}
      end

      assert {:ok, %{session_id: "thread-retry"}} = GenAgent.ask(name, "again")
      assert_receive {:thread_id_seen, "thread-retry"}
    end

    test "a lazy stream continues past an error notification to turn.failed" do
      test_pid = self()

      exec_fn = fn _prompt, _session ->
        {:ok,
         Stream.map(
           [
             event("thread.started", %{"thread_id" => "thread-failed"}),
             event("error", %{"message" => "Reconnecting... 1/5"}),
             event("turn.failed", %{"error" => %{"message" => "connection lost"}})
           ],
           fn event ->
             send(test_pid, {:pulled, event.event_type})
             event
           end
         )}
      end

      name = start_codex_agent(exec_fn)

      assert {:error, %{"message" => "connection lost"}} = GenAgent.ask(name, "go")
      assert_receive {:pulled, "thread.started"}
      assert_receive {:pulled, "error"}
      assert_receive {:pulled, "turn.failed"}
    end

    test "parsed action items reach stream callback in order" do
      lines = [
        ~s({"type":"thread.started","thread_id":"t-mcp"}),
        ~s({"type":"item.started","item":{"type":"mcp_tool_call","id":"call-2","status":"in_progress"}}),
        ~s({"type":"item.completed","item":{"type":"mcp_tool_call","id":"call-2","server":"fixture","tool":"read","arguments":{},"result":{"content":[]},"status":"completed"}}),
        ~s({"type":"item.completed","item":{"type":"agent_message","text":"done"}}),
        ~s({"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":2}})
      ]

      exec_fn = fn _prompt, _session ->
        {:ok,
         Stream.map(lines, fn line ->
           {:ok, parsed} = JsonLineEvent.parse(line)
           parsed
         end)}
      end

      name = start_codex_agent(exec_fn)
      assert {:ok, response} = GenAgent.ask(name, "read")
      assert response.text == "done"
      assert response.session_id == "t-mcp"

      assert Enum.map(response.events, & &1.kind) ==
               [:tool_use, :tool_result, :text, :usage, :result]

      assert Enum.map(GenAgent.status(name).agent_state.stream_events, & &1.kind) ==
               [:tool_use, :tool_result, :text, :usage, :result]
    end

    test "stream callbacks observe text before the terminal event arrives" do
      parent = self()

      exec_fn = fn _prompt, _session ->
        {:ok,
         Stream.resource(
           fn -> :start end,
           fn
             :start ->
               {[
                  event("thread.started", %{"thread_id" => "t-live"}),
                  event("item.completed", %{
                    "item" => %{"type" => "agent_message", "text" => "early"}
                  })
                ], :waiting}

             :waiting ->
               send(parent, {:terminal_waiting, self()})

               receive do
                 :complete -> {[event("turn.completed", %{})], :done}
               end

             :done ->
               {:halt, :done}
           end,
           fn _ -> :ok end
         )}
      end

      name = start_codex_agent(exec_fn, observer: parent)
      caller = Task.async(fn -> GenAgent.ask(name, "go") end)
      assert_receive {:stream_event, :text}
      assert_receive {:terminal_waiting, task_pid}
      send(task_pid, :complete)
      assert {:ok, %{text: "early", session_id: "t-live"}} = Task.await(caller)
    end
  end
end
