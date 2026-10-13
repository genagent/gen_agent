defmodule GenAgent.Backends.ClaudeIntegrationTest do
  @moduledoc """
  End-to-end tests that drive a real `GenAgent` process with the
  `GenAgent.Backends.Claude` backend, but with the `ClaudeWrapper`
  subprocess stubbed out via an injected `stream_fn`.

  These tests exercise the full state-machine path:
  `GenAgent.start_agent/2` -> `GenAgent.ask/2` -> `Claude.prompt/2` ->
  fake stream -> `EventTranslator` -> back into the state machine and
  delivered as a `GenAgent.Response`.

  They are the second consumer of `GenAgent.Backend`, after the in-tree
  mock. If either end of that contract drifts, these break.
  """

  use ExUnit.Case, async: true

  alias ClaudeWrapper.StreamEvent

  defmodule ClaudeAgent do
    use GenAgent

    defmodule State do
      defstruct responses: [], errors: [], stream_events: []
    end

    @impl true
    def init_agent(opts) do
      backend_opts =
        Keyword.take(opts, [
          :stream_fn,
          :working_dir,
          :cwd,
          :model,
          :system_prompt,
          :permission_mode,
          :json_schema
        ])

      {:ok, backend_opts, %State{}}
    end

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      {:noreply, %{state | responses: state.responses ++ [response]}}
    end

    @impl true
    def handle_error(_ref, reason, %State{} = state) do
      {:noreply, %{state | errors: state.errors ++ [reason]}}
    end

    @impl true
    def handle_stream_event(event, %State{} = state) do
      %{state | stream_events: state.stream_events ++ [event]}
    end
  end

  defp stream_event(type, data), do: %StreamEvent{type: type, data: data, raw: ""}

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp start_claude_agent(stream_fn, extra_opts \\ []) do
    name = unique_name("claude")

    {:ok, _pid} =
      GenAgent.start_agent(
        ClaudeAgent,
        [
          name: name,
          backend: GenAgent.Backends.Claude,
          stream_fn: stream_fn
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
    test "assembles a Response from the translated stream" do
      stream_fn = fn _prompt, _opts ->
        [
          stream_event("system", %{"info" => "init"}),
          stream_event("assistant", %{
            "content" => [%{"type" => "text", "text" => "the answer is 42"}]
          }),
          stream_event("result", %{
            "result" => "the answer is 42",
            "session_id" => "sess-abc",
            "cost_usd" => 0.001,
            "duration_ms" => 123
          })
        ]
      end

      name = start_claude_agent(stream_fn)

      assert {:ok, response} = GenAgent.ask(name, "what is the answer?")
      assert response.text == "the answer is 42"
      assert response.session_id == "sess-abc"
      assert Enum.map(response.events, & &1.kind) == [:text, :result]
    end

    test "threads session_id across multiple turns via --resume" do
      test_pid = self()

      stream_fn = fn prompt, opts ->
        send(test_pid, {:claude_call, prompt, Keyword.get(opts, :resume)})

        [
          stream_event("result", %{
            "result" => "ack: #{prompt}",
            "session_id" => "sess-persist"
          })
        ]
      end

      name = start_claude_agent(stream_fn)

      {:ok, _} = GenAgent.ask(name, "turn 1")
      assert_receive {:claude_call, "turn 1", nil}

      {:ok, _} = GenAgent.ask(name, "turn 2")
      assert_receive {:claude_call, "turn 2", "sess-persist"}

      {:ok, _} = GenAgent.ask(name, "turn 3")
      assert_receive {:claude_call, "turn 3", "sess-persist"}
    end

    test "resumes after a failed Claude result using its raw session ID" do
      observer = self()

      stream_fn = fn prompt, opts ->
        send(observer, {:claude_call, prompt, Keyword.get(opts, :resume)})

        if prompt == "fail" do
          [
            stream_event("system", %{"session_id" => "failed-session"}),
            stream_event("result", %{
              "is_error" => true,
              "subtype" => "error_max_turns",
              "result" => "turn limit reached",
              "session_id" => "failed-session"
            })
          ]
        else
          [stream_event("result", %{"result" => "continued", "session_id" => "failed-session"})]
        end
      end

      name = start_claude_agent(stream_fn)
      assert {:error, reason} = GenAgent.ask(name, "fail")
      assert %{subtype: "error_max_turns"} = GenAgent.ClaudeErrors.raw(reason)
      assert_receive {:claude_call, "fail", nil}
      assert {:ok, response} = GenAgent.ask(name, "next")
      assert_receive {:claude_call, "next", "failed-session"}
      assert response.text == "continued"
    end

    test "an early system ID survives an interrupted Claude stream" do
      observer = self()

      stream_fn = fn prompt, opts ->
        send(observer, {:claude_call, prompt, Keyword.get(opts, :resume)})

        if prompt == "hold" do
          Stream.concat(
            [stream_event("system", %{"session_id" => "interrupted-session"})],
            Stream.map([:wait], fn _ ->
              send(observer, :claude_waiting)
              Process.sleep(30_000)
              stream_event("result", %{"result" => "late"})
            end)
          )
        else
          [stream_event("result", %{"result" => "resumed"})]
        end
      end

      name = start_claude_agent(stream_fn)
      assert {:ok, ref} = GenAgent.tell(name, "hold")
      assert_receive :claude_waiting
      assert {:ok, :accepted} = GenAgent.interrupt_request(name, ref)
      assert {:error, :interrupted} = GenAgent.poll(name, ref)
      assert {:ok, _} = GenAgent.ask(name, "next")
      assert_receive {:claude_call, "next", "interrupted-session"}
    end

    test "conflicting raw Claude IDs fail the turn without replacing the first ID" do
      stream_fn = fn _prompt, _opts ->
        [
          stream_event("system", %{"session_id" => "first-id"}),
          stream_event("result", %{"result" => "done", "session_id" => "different-id"})
        ]
      end

      name = start_claude_agent(stream_fn)
      assert {:error, :conflicting_session_id} = GenAgent.ask(name, "go")
      session = :gen_statem.call(GenAgent.whereis(name), :get_backend_session)
      assert session.session_id == "first-id"
    end

    test "resumes after compacting more than 1,000 Claude text deltas" do
      test_pid = self()

      delta =
        stream_event("stream_event", %{
          "event" => %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "x"}
          }
        })

      stream_fn = fn prompt, opts ->
        send(test_pid, {:claude_call, prompt, Keyword.get(opts, :resume)})

        if prompt == "long" do
          List.duplicate(delta, 1_001) ++
            [stream_event("result", %{"result" => "complete", "session_id" => "sess-long"})]
        else
          [stream_event("result", %{"result" => "continued", "session_id" => "sess-long"})]
        end
      end

      name = start_claude_agent(stream_fn)

      assert {:ok, response} = GenAgent.ask(name, "long")
      assert_receive {:claude_call, "long", nil}
      assert response.text == "complete"
      assert response.session_id == "sess-long"
      assert response.event_coverage.mode == :compact
      assert response.event_coverage.observed_events == 1_002
      assert response.event_coverage.retained_events == 1_000
      assert response.terminal.kind == :result

      assert {:ok, next_response} = GenAgent.ask(name, "next")
      assert_receive {:claude_call, "next", "sess-long"}
      assert next_response.text == "continued"
    end

    test "forwards init_agent opts (model, system_prompt) to the stream_fn" do
      test_pid = self()

      stream_fn = fn _prompt, opts ->
        send(test_pid, {:claude_opts, opts})
        [stream_event("result", %{"result" => "ok"})]
      end

      name =
        start_claude_agent(stream_fn,
          model: "sonnet",
          system_prompt: "You are a test agent.",
          cwd: "/tmp/test"
        )

      {:ok, _} = GenAgent.ask(name, "hello")

      assert_receive {:claude_opts, opts}
      assert opts[:model] == "sonnet"
      assert opts[:system_prompt] == "You are a test agent."
      assert opts[:working_dir] == "/tmp/test"
    end

    test "delivers a :no_terminal_event error when the stream ends without a result" do
      stream_fn = fn _prompt, _opts ->
        [stream_event("assistant", %{"content" => [%{"type" => "text", "text" => "partial"}]})]
      end

      name = start_claude_agent(stream_fn)

      assert {:error, :no_terminal_event} = GenAgent.ask(name, "go")
    end

    test "delivers an error terminal event through the state machine" do
      stream_fn = fn _prompt, _opts ->
        [
          stream_event("error", %{"error" => "rate limited"})
        ]
      end

      name = start_claude_agent(stream_fn)

      assert {:error, reason} = GenAgent.ask(name, "boom")
      assert reason == GenAgent.ClaudeErrors.expected("rate limited")
    end

    test "empty or absent result text falls back to assistant text after ExitPlanMode" do
      for result <- [%{"result" => ""}, %{}] do
        stream_fn = fn _prompt, _opts ->
          [
            stream_event("assistant", %{
              "message" => %{"content" => [%{"type" => "text", "text" => "Here is the plan"}]}
            }),
            stream_event("assistant", %{
              "message" => %{
                "content" => [
                  %{
                    "type" => "tool_use",
                    "id" => "tu_1",
                    "name" => "ExitPlanMode",
                    "input" => %{"plan" => "1. do x"}
                  }
                ]
              }
            }),
            stream_event("result", Map.merge(%{"session_id" => "s"}, result))
          ]
        end

        name = start_claude_agent(stream_fn, permission_mode: :plan)

        assert {:ok, response} = GenAgent.ask(name, "plan it")
        assert response.text == "Here is the plan"
        assert Enum.map(response.events, & &1.kind) == [:text, :tool_use, :result]
      end
    end

    test "tool-only plan turn keeps empty text and exposes the plan on the tool event" do
      stream_fn = fn _prompt, _opts ->
        [
          stream_event("assistant", %{
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "tu_1",
                  "name" => "ExitPlanMode",
                  "input" => %{"plan" => "1. do x"}
                }
              ]
            }
          }),
          stream_event("result", %{"result" => "", "session_id" => "s"})
        ]
      end

      name = start_claude_agent(stream_fn, permission_mode: :plan)

      assert {:ok, response} = GenAgent.ask(name, "plan it")
      assert response.text == ""

      assert %{data: %{"input" => %{"plan" => "1. do x"}}} =
               Enum.find(response.events, &(&1.kind == :tool_use))
    end

    test "nonempty result text wins over assistant text" do
      stream_fn = fn _prompt, _opts ->
        [
          stream_event("assistant", %{"content" => [%{"type" => "text", "text" => "draft"}]}),
          stream_event("result", %{"result" => "final", "session_id" => "s"})
        ]
      end

      name = start_claude_agent(stream_fn)
      assert {:ok, %{text: "final"}} = GenAgent.ask(name, "q")
    end

    test "structured output and extended fields reach the terminal :result event" do
      stream_fn = fn _prompt, _opts ->
        [
          stream_event("result", %{
            "result" => "",
            "session_id" => "s",
            "structured_output" => %{"answer" => 42},
            "stop_reason" => "end_turn",
            "permission_denials" => [%{"tool_name" => "Bash"}]
          })
        ]
      end

      name = start_claude_agent(stream_fn, json_schema: ~s({"type":"object"}))

      assert {:ok, response} = GenAgent.ask(name, "q")
      result = Enum.find(response.events, &(&1.kind == :result))
      assert result.data.raw["structured_output"] == %{"answer" => 42}
      assert result.data.raw["stop_reason"] == "end_turn"
      assert result.data.raw["permission_denials"] == [%{"tool_name" => "Bash"}]
    end

    test "errors-array failure reaches ask callers and handle_error with a message" do
      failure =
        stream_event("result", %{
          "subtype" => "error_during_execution",
          "is_error" => true,
          "errors" => ["something broke"],
          "num_turns" => 2,
          "session_id" => "s"
        })

      name = start_claude_agent(fn _prompt, _opts -> [failure] end)

      assert {:error, reason} = GenAgent.ask(name, "q")
      assert reason.message == "something broke"

      assert %{errors: ["something broke"], num_turns: 2} =
               GenAgent.ClaudeErrors.raw(reason)

      assert [%{message: "something broke"}] = GenAgent.status(name).agent_state.errors
    end

    test "failed Claude result reaches handle_error for ask and poll" do
      failure =
        stream_event("result", %{
          "subtype" => "error_max_turns",
          "is_error" => true,
          "result" => "Turn limit reached",
          "session_id" => "s-failed",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 1}
        })

      name = start_claude_agent(fn _prompt, _opts -> [failure] end)

      assert {:error, reason} = GenAgent.ask(name, "first")

      assert %{subtype: "error_max_turns", session_id: "s-failed"} =
               GenAgent.ClaudeErrors.raw(reason)

      {:ok, ref} = GenAgent.tell(name, "second")

      result =
        Enum.reduce_while(1..100, nil, fn _, _ ->
          case GenAgent.poll(name, ref) do
            {:ok, :pending} ->
              Process.sleep(10)
              {:cont, nil}

            result ->
              {:halt, result}
          end
        end)

      assert {:error, reason} = result
      assert %{subtype: "error_max_turns"} = GenAgent.ClaudeErrors.raw(reason)

      state = GenAgent.status(name).agent_state
      assert length(state.errors) == 2
      assert state.responses == []
    end

    test "parsed partial text and MCP call/return reach stream callbacks once" do
      lines = [
        ~s({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Found it"}}}),
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Found it"},{"type":"tool_use","id":"call-1","name":"mcp__fixture__read","input":{"path":"README.md"}}]}}),
        ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"call-1","content":"contents","is_error":false}]}}),
        ~s({"type":"result","result":"Found it","session_id":"s-1"})
      ]

      stream_fn = fn _prompt, _opts ->
        Enum.map(lines, fn line ->
          {:ok, event} = StreamEvent.parse(line)
          event
        end)
      end

      name = start_claude_agent(stream_fn)
      assert {:ok, response} = GenAgent.ask(name, "read")
      assert response.text == "Found it"
      assert Enum.map(response.events, & &1.kind) == [:text, :tool_use, :tool_result, :result]

      assert Enum.map(GenAgent.status(name).agent_state.stream_events, & &1.kind) ==
               [:text, :tool_use, :tool_result, :result]
    end
  end
end
