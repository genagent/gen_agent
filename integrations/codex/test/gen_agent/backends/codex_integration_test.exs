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
  alias GenAgent.CodexTranscripts, as: Transcripts

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

  for recording <- Transcripts.names() do
    @tag recording: recording
    test "recorded #{recording} traverses the backend and callbacks", %{recording: recording} do
      events = Transcripts.load(recording)
      name = start_codex_agent(fn _, _ -> {:ok, events} end)

      if recording == "failure" do
        reason = Transcripts.failure()
        assert {:error, ^reason} = GenAgent.ask(name, recording)
      else
        assert {:ok, response} = GenAgent.ask(name, recording)
        Transcripts.assert_events(response.events, recording)
        assert response.text == Transcripts.text(recording)
        assert response.session_id == Transcripts.thread_id(recording)
        assert response.usage == Keyword.fetch!(Transcripts.expected(recording), :usage)
      end

      Transcripts.assert_events(GenAgent.status(name).agent_state.stream_events, recording)
    end
  end

  test "recorded resume pair retains the initial thread identity" do
    observer = self()

    name =
      start_codex_agent(fn recording, session ->
        send(observer, {:resume_thread, session.thread_id})
        {:ok, Transcripts.load(recording)}
      end)

    assert {:ok, initial} = GenAgent.ask(name, "resume-initial")
    assert_receive {:resume_thread, nil}
    assert {:ok, followup} = GenAgent.ask(name, "resume-followup")
    id = initial.session_id
    assert_receive {:resume_thread, ^id}
    assert followup.session_id == id
    assert initial.text == "ok"
    assert followup.text == "42"

    # Recorded totals are 14956 then 29938; the follow-up reports the difference.
    assert initial.usage.input_tokens == 14_956
    assert followup.usage.input_tokens == 14_982
    assert followup.usage.cached_input_tokens == 12_160
    assert followup.usage.output_tokens == 5
    assert followup.usage.cache_write_input_tokens == 0
    assert followup.usage.reasoning_output_tokens == 0
  end

  test "host-recorded live totals report a per-turn delta of 16294" do
    first = [
      event("thread.started", %{"thread_id" => "thread-live"}),
      event("turn.completed", %{
        "usage" => %{
          "input_tokens" => 14_985,
          "cached_input_tokens" => 11_008,
          "cache_write_input_tokens" => 0,
          "output_tokens" => 5,
          "reasoning_output_tokens" => 0
        }
      })
    ]

    second = [
      event("thread.started", %{"thread_id" => "thread-live"}),
      event("turn.completed", %{
        "usage" => %{
          "input_tokens" => 31_279,
          "cached_input_tokens" => 25_088,
          "cache_write_input_tokens" => 0,
          "output_tokens" => 11,
          "reasoning_output_tokens" => 0
        }
      })
    ]

    {:ok, agent} = Agent.start_link(fn -> [first, second] end)

    name =
      start_codex_agent(fn _, _ ->
        {:ok, Agent.get_and_update(agent, fn [h | t] -> {h, t} end)}
      end)

    assert {:ok, one} = GenAgent.ask(name, "one")
    assert {:ok, two} = GenAgent.ask(name, "two")
    assert one.usage.input_tokens == 14_985
    assert two.usage.input_tokens == 16_294
    assert two.usage.cached_input_tokens == 14_080
    assert two.usage.output_tokens == 6
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

    test "resumes after turn.failed using the earlier thread.started ID" do
      observer = self()

      exec_fn = fn prompt, session ->
        send(observer, {:exec_call, prompt, session.thread_id})

        if prompt == "fail" do
          {:ok,
           [
             event("thread.started", %{"thread_id" => "failed-thread"}),
             event("turn.failed", %{"error" => "provider failed"})
           ]}
        else
          {:ok,
           [
             event("thread.started", %{"thread_id" => "failed-thread"}),
             event("turn.completed", %{})
           ]}
        end
      end

      name = start_codex_agent(exec_fn)
      assert {:error, "provider failed"} = GenAgent.ask(name, "fail")
      assert_receive {:exec_call, "fail", nil}
      assert {:ok, _} = GenAgent.ask(name, "next")
      assert_receive {:exec_call, "next", "failed-thread"}
    end

    test "thread.started checkpoint survives an interrupted Codex stream" do
      observer = self()

      exec_fn = fn prompt, session ->
        send(observer, {:exec_call, prompt, session.thread_id})

        if prompt == "hold" do
          {:ok,
           Stream.concat(
             [event("thread.started", %{"thread_id" => "interrupted-thread"})],
             Stream.map([:wait], fn _ ->
               send(observer, :codex_waiting)
               Process.sleep(30_000)
               event("turn.completed", %{})
             end)
           )}
        else
          {:ok, [event("turn.completed", %{})]}
        end
      end

      name = start_codex_agent(exec_fn)
      assert {:ok, ref} = GenAgent.tell(name, "hold")
      assert_receive :codex_waiting
      assert {:ok, :accepted} = GenAgent.interrupt_request(name, ref)
      assert {:error, :interrupted} = GenAgent.poll(name, ref)
      assert {:ok, _} = GenAgent.ask(name, "next")
      assert_receive {:exec_call, "next", "interrupted-thread"}
    end

    test "a malformed raw Codex thread ID fails the turn" do
      exec_fn = fn _prompt, _session ->
        {:ok, [event("thread.started", %{"thread_id" => "bad\nthread"})]}
      end

      name = start_codex_agent(exec_fn)
      assert {:error, :invalid_session_id} = GenAgent.ask(name, "go")
      session = :gen_statem.call(GenAgent.whereis(name), :get_backend_session)
      assert session.thread_id == nil
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

    test "synthetic: parsed action items reach stream callback in order" do
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
