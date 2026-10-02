defmodule GenAgent.Backends.OpenAITest do
  use ExUnit.Case, async: true

  alias GenAgent.Backends.OpenAI
  alias GenAgent.Event

  defp ok_response(text, opts \\ []) do
    fn _req ->
      {:ok,
       %{
         "id" => Keyword.get(opts, :id, "resp_01abc"),
         "object" => "response",
         "model" => Keyword.get(opts, :model, "gpt-5"),
         "status" => Keyword.get(opts, :status, "completed"),
         "store" => true,
         "output" => Keyword.get(opts, :output, default_output(text)),
         "usage" => Keyword.get(opts, :usage, default_usage(opts))
       }}
    end
  end

  defp default_output(text) do
    [
      %{
        "id" => "msg_01",
        "type" => "message",
        "role" => "assistant",
        "status" => "completed",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    ]
  end

  defp default_usage(opts) do
    input = Keyword.get(opts, :input_tokens, 10)
    output = Keyword.get(opts, :output_tokens, 5)

    base = %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => input + output
    }

    case Keyword.get(opts, :reasoning_tokens) do
      nil -> base
      rt -> Map.put(base, "output_tokens_details", %{"reasoning_tokens" => rt})
    end
  end

  defp recording_fn(ref, response) do
    test_pid = self()

    fn req ->
      send(test_pid, {ref, req})
      response.(req)
    end
  end

  describe "start_session/1" do
    test "Inspect shows session metadata without credentials or conversation content" do
      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test-SECRET-123",
          instructions: "SYSTEM-SENTINEL",
          model: "gpt-test-model",
          http_fn: ok_response("REPLY-SENTINEL")
        )

      {:ok, _events, session} = OpenAI.prompt(session, "PROMPT-SENTINEL")
      session = OpenAI.update_session(session, %{response_id: "RESPONSE-ID-SENTINEL"})

      for rendered <- [
            inspect(session),
            inspect(session, limit: :infinity),
            inspect(session, pretty: true),
            "#{inspect(session)}"
          ] do
        assert rendered =~ "#GenAgent.Backends.OpenAI<"
        assert rendered =~ "model: \"gpt-test-model\""
        refute rendered =~ "sk-test-SECRET-123"
        refute rendered =~ "SYSTEM-SENTINEL"
        refute rendered =~ "PROMPT-SENTINEL"
        refute rendered =~ "REPLY-SENTINEL"
        refute rendered =~ "RESPONSE-ID-SENTINEL"
        refute rendered =~ "http_fn"
        refute rendered =~ "api_key"
      end

      assert session.api_key == "sk-test-SECRET-123"
    end

    test "reads api_key from opts" do
      {:ok, session} =
        OpenAI.start_session(api_key: "sk-test", http_fn: ok_response("hi"))

      assert session.api_key == "sk-test"
    end

    test "fails without a key when the default transport is used" do
      previous = System.get_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_API_KEY")

      try do
        assert {:error, :missing_api_key} = OpenAI.start_session([])
        assert {:error, :missing_api_key} = OpenAI.start_session(api_key: "")
        assert {:error, :missing_api_key} = OpenAI.start_session(api_key: "   ")

        System.put_env("OPENAI_API_KEY", "")
        assert {:error, :missing_api_key} = OpenAI.start_session([])
      after
        if previous,
          do: System.put_env("OPENAI_API_KEY", previous),
          else: System.delete_env("OPENAI_API_KEY")
      end
    end

    test "starts without a key when :http_fn replaces the transport" do
      previous = System.get_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_API_KEY")

      try do
        assert {:ok, session} = OpenAI.start_session(http_fn: ok_response("hi"))
        assert session.api_key == nil
      after
        if previous, do: System.put_env("OPENAI_API_KEY", previous)
      end
    end

    test "falls back to OPENAI_API_KEY env var" do
      System.put_env("OPENAI_API_KEY", "env-key")
      {:ok, session} = OpenAI.start_session(http_fn: ok_response("hi"))
      assert session.api_key == "env-key"
    after
      System.delete_env("OPENAI_API_KEY")
    end

    test "starts with nil previous_response_id and a generated client_session_id" do
      {:ok, session} = OpenAI.start_session(http_fn: ok_response("hi"))
      assert session.previous_response_id == nil
      assert is_binary(session.client_session_id)
      assert String.starts_with?(session.client_session_id, "openai-")
    end

    test "uses default model" do
      {:ok, session} = OpenAI.start_session(http_fn: ok_response("hi"))
      assert session.model == "gpt-5"
    end

    test "receive_timeout defaults to 60_000 and connect_timeout uses Req's default" do
      {:ok, session} = OpenAI.start_session(http_fn: ok_response("hi"))
      assert session.receive_timeout == 60_000
      assert session.connect_timeout == nil
    end

    test "accepts explicit receive and connect timeouts" do
      {:ok, session} =
        OpenAI.start_session(
          receive_timeout: 180_000,
          connect_timeout: 5_000,
          http_fn: ok_response("hi")
        )

      assert session.receive_timeout == 180_000
      assert session.connect_timeout == 5_000
    end

    test "accepts all options" do
      {:ok, session} =
        OpenAI.start_session(
          http_fn: ok_response("hi"),
          instructions: "Be terse.",
          model: "gpt-5-mini",
          max_output_tokens: 256,
          reasoning_effort: :medium
        )

      assert session.instructions == "Be terse."
      assert session.model == "gpt-5-mini"
      assert session.max_output_tokens == 256
      assert session.reasoning_effort == :medium
    end
  end

  describe "prompt/2 request shape" do
    test "passes explicit timeouts to custom HTTP functions" do
      ref = make_ref()

      {:ok, session} =
        OpenAI.start_session(
          receive_timeout: 120_000,
          connect_timeout: 5_000,
          http_fn: recording_fn(ref, ok_response("pong"))
        )

      {:ok, _events, _session} = OpenAI.prompt(session, "ping")

      assert_receive {^ref, request}
      assert request.receive_timeout == 120_000
      assert request.connect_timeout == 5_000
    end

    test "passes default timeout values to custom HTTP functions" do
      ref = make_ref()

      {:ok, session} =
        OpenAI.start_session(http_fn: recording_fn(ref, ok_response("pong")))

      {:ok, _events, _session} = OpenAI.prompt(session, "ping")

      assert_receive {^ref, request}
      assert request.receive_timeout == 60_000
      assert request.connect_timeout == nil
    end

    test "sends input as a single-element array of {role, content}" do
      ref = make_ref()

      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          http_fn: recording_fn(ref, ok_response("pong"))
        )

      {:ok, _events, _session} = OpenAI.prompt(session, "ping")

      assert_receive {^ref, request}
      assert request.body.input == [%{role: "user", content: "ping"}]
    end

    test "sends Bearer auth header" do
      ref = make_ref()

      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test-xyz",
          http_fn: recording_fn(ref, ok_response("x"))
        )

      {:ok, _events, _session} = OpenAI.prompt(session, "hi")

      assert_receive {^ref, request}
      headers = Map.new(request.headers)
      assert headers["authorization"] == "Bearer sk-test-xyz"
      assert headers["content-type"] == "application/json"
    end

    test "includes instructions when set" do
      ref = make_ref()

      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          instructions: "Be brief.",
          http_fn: recording_fn(ref, ok_response("k"))
        )

      {:ok, _events, _session} = OpenAI.prompt(session, "hello")

      assert_receive {^ref, request}
      assert request.body.instructions == "Be brief."
    end

    test "omits instructions when not set" do
      ref = make_ref()

      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          http_fn: recording_fn(ref, ok_response("k"))
        )

      {:ok, _events, _session} = OpenAI.prompt(session, "hello")

      assert_receive {^ref, request}
      refute Map.has_key?(request.body, :instructions)
    end

    test "omits previous_response_id on the first turn" do
      ref = make_ref()

      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          http_fn: recording_fn(ref, ok_response("k"))
        )

      {:ok, _events, _session} = OpenAI.prompt(session, "hello")

      assert_receive {^ref, request}
      refute Map.has_key?(request.body, :previous_response_id)
    end

    test "always sends store: true" do
      ref = make_ref()

      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          http_fn: recording_fn(ref, ok_response("k"))
        )

      {:ok, _events, _session} = OpenAI.prompt(session, "hi")

      assert_receive {^ref, request}
      assert request.body.store == true
    end

    test "includes reasoning effort when set" do
      ref = make_ref()

      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          reasoning_effort: :high,
          http_fn: recording_fn(ref, ok_response("k"))
        )

      {:ok, _events, _session} = OpenAI.prompt(session, "hi")

      assert_receive {^ref, request}
      assert request.body.reasoning == %{effort: :high}
    end

    test "passes any reasoning effort value through unchanged" do
      for effort <- [:minimal, "xhigh"] do
        ref = make_ref()

        {:ok, session} =
          OpenAI.start_session(
            api_key: "sk-test",
            reasoning_effort: effort,
            http_fn: recording_fn(ref, ok_response("k"))
          )

        {:ok, _events, _session} = OpenAI.prompt(session, "hi")

        assert_receive {^ref, request}
        assert request.body.reasoning == %{effort: effort}
      end
    end

    test "includes max_output_tokens when set" do
      ref = make_ref()

      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          max_output_tokens: 128,
          http_fn: recording_fn(ref, ok_response("k"))
        )

      {:ok, _events, _session} = OpenAI.prompt(session, "hi")

      assert_receive {^ref, request}
      assert request.body.max_output_tokens == 128
    end
  end

  describe "prompt/2 response parsing" do
    test "extracts text from the message item in output[]" do
      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          http_fn: ok_response("hello world")
        )

      {:ok, events, _} = OpenAI.prompt(session, "hi")

      [_usage, %Event{kind: :result, data: data}] = Enum.to_list(events)
      assert data.text == "hello world"
    end

    test "ignores reasoning items when extracting text" do
      output = [
        %{
          "id" => "rs_01",
          "type" => "reasoning",
          "summary" => [],
          "encrypted_content" => "opaque"
        },
        %{
          "id" => "msg_01",
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [%{"type" => "output_text", "text" => "the answer"}]
        }
      ]

      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          http_fn: ok_response("unused", output: output)
        )

      {:ok, events, _} = OpenAI.prompt(session, "hi")

      [_usage, %Event{kind: :result, data: data}] = Enum.to_list(events)
      assert data.text == "the answer"
    end

    test "concatenates multiple output_text parts within one message" do
      output = [
        %{
          "id" => "msg_01",
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{"type" => "output_text", "text" => "part one "},
            %{"type" => "output_text", "text" => "part two"}
          ]
        }
      ]

      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          http_fn: ok_response("unused", output: output)
        )

      {:ok, events, _} = OpenAI.prompt(session, "hi")

      [_usage, %Event{kind: :result, data: data}] = Enum.to_list(events)
      assert data.text == "part one part two"
    end

    test "emits :usage and :result events in that order" do
      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          http_fn: ok_response("pong", input_tokens: 12, output_tokens: 3)
        )

      {:ok, events, _} = OpenAI.prompt(session, "ping")
      events_list = Enum.to_list(events)

      assert [
               %Event{kind: :usage, data: usage},
               %Event{kind: :result, data: result}
             ] = events_list

      assert usage.input_tokens == 12
      assert usage.output_tokens == 3
      assert usage.total_tokens == 15
      assert result.text == "pong"
      assert result.stop_reason == "completed"
      assert result.response_id == "resp_01abc"
      assert is_binary(result.session_id)
    end

    test "surfaces reasoning_tokens in the :usage event when present" do
      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          http_fn:
            ok_response("pong", input_tokens: 10, output_tokens: 148, reasoning_tokens: 128)
        )

      {:ok, events, _} = OpenAI.prompt(session, "hi")
      [usage_event, _] = Enum.to_list(events)

      assert usage_event.data.reasoning_tokens == 128
      assert usage_event.data.output_tokens == 148
    end

    test "omits reasoning_tokens when the field is absent" do
      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          http_fn: ok_response("pong")
        )

      {:ok, events, _} = OpenAI.prompt(session, "hi")
      [usage_event, _] = Enum.to_list(events)

      refute Map.has_key?(usage_event.data, :reasoning_tokens)
    end

    test "failed responses emit a terminal error with the API error" do
      api_error = %{"code" => "server_error", "message" => "generation failed"}

      http_fn = fn _req ->
        {:ok,
         ok_response("", id: "resp_failed").(nil)
         |> elem(1)
         |> Map.merge(%{"status" => "failed", "error" => api_error})}
      end

      {:ok, session} = OpenAI.start_session(http_fn: http_fn)
      {:ok, events, _} = OpenAI.prompt(session, "hi")

      assert [%Event{kind: :usage}, %Event{kind: :error, data: data}] = events
      assert data.reason == {:response_failed, api_error}
      assert data.response_id == "resp_failed"
      assert data.status == "failed"
    end

    test "incomplete responses emit a terminal error even when partial text exists" do
      details = %{"reason" => "max_output_tokens"}

      http_fn = fn _req ->
        {:ok,
         ok_response("partial answer", id: "resp_incomplete").(nil)
         |> elem(1)
         |> Map.merge(%{"status" => "incomplete", "incomplete_details" => details})}
      end

      {:ok, session} = OpenAI.start_session(http_fn: http_fn)
      {:ok, events, _} = OpenAI.prompt(session, "hi")

      assert [%Event{kind: :usage}, %Event{kind: :error, data: data}] = events
      assert data.reason == {:response_incomplete, details}
      assert data.status == "incomplete"
    end

    test "refusal content emits a terminal error instead of an empty result" do
      output = [
        %{
          "type" => "message",
          "content" => [%{"type" => "refusal", "refusal" => "I cannot help with that."}]
        }
      ]

      {:ok, session} = OpenAI.start_session(http_fn: ok_response("", output: output))
      {:ok, events, _} = OpenAI.prompt(session, "hi")

      assert [%Event{kind: :usage}, %Event{kind: :error, data: data}] = events
      assert data.reason == {:refusal, "I cannot help with that."}
      assert data.status == "completed"
    end

    test "nonterminal response statuses cannot become successful turns" do
      {:ok, session} = OpenAI.start_session(http_fn: ok_response("", status: "queued"))
      {:ok, events, _} = OpenAI.prompt(session, "hi")

      assert [%Event{kind: :usage}, %Event{kind: :error, data: data}] = events
      assert data.reason == {:unexpected_response_status, "queued"}
    end

    test "propagates HTTP errors" do
      failing = fn _req -> {:error, {:http_error, 429, %{"error" => "rate_limit"}}} end
      {:ok, session} = OpenAI.start_session(api_key: "sk-test", http_fn: failing)

      assert {:error, {:http_error, 429, _}} = OpenAI.prompt(session, "hi")
    end

    test "wraps a raising http_fn" do
      raising = fn _req -> raise "boom" end
      {:ok, session} = OpenAI.start_session(api_key: "sk-test", http_fn: raising)

      assert {:error, {:http_fn_raised, _}} = OpenAI.prompt(session, "hi")
    end
  end

  describe "update_session/2" do
    test "stores response_id as previous_response_id" do
      {:ok, session} = OpenAI.start_session(api_key: "sk-test", http_fn: ok_response("x"))

      session = OpenAI.update_session(session, %{response_id: "resp_42"})
      assert session.previous_response_id == "resp_42"
    end

    test "ignores data without response_id" do
      {:ok, session} = OpenAI.start_session(api_key: "sk-test", http_fn: ok_response("x"))
      session = %{session | previous_response_id: "resp_prev"}

      session = OpenAI.update_session(session, %{text: "hello"})
      assert session.previous_response_id == "resp_prev"
    end

    test "ignores empty response_id" do
      {:ok, session} = OpenAI.start_session(api_key: "sk-test", http_fn: ok_response("x"))

      session = OpenAI.update_session(session, %{response_id: ""})
      assert session.previous_response_id == nil
    end
  end

  describe "terminate_session/1" do
    test "is a no-op" do
      {:ok, session} = OpenAI.start_session(api_key: "sk-test", http_fn: ok_response("x"))
      assert :ok = OpenAI.terminate_session(session)
    end
  end

  describe "end-to-end through prompt -> update_session -> prompt" do
    test "the second turn sends previous_response_id from the first terminal event" do
      ref = make_ref()

      turns = [
        ok_response("reply 1", id: "resp_001").(nil),
        ok_response("reply 2", id: "resp_002").(nil)
      ]

      {:ok, agent_pid} = Agent.start_link(fn -> turns end)

      http_fn = fn req ->
        test_pid = self()
        send(test_pid, {ref, req})

        Agent.get_and_update(agent_pid, fn
          [next | rest] -> {next, rest}
          [] -> {{:error, :out_of_turns}, []}
        end)
      end

      {:ok, session} = OpenAI.start_session(api_key: "sk-test", http_fn: http_fn)

      # Turn 1
      {:ok, events1, session} = OpenAI.prompt(session, "first")
      %{data: data1} = Enum.find(events1, &(&1.kind == :result))
      session = OpenAI.update_session(session, data1)

      assert session.previous_response_id == "resp_001"
      assert data1.text == "reply 1"

      # Turn 2
      {:ok, events2, session} = OpenAI.prompt(session, "second")
      %{data: data2} = Enum.find(events2, &(&1.kind == :result))
      session = OpenAI.update_session(session, data2)

      assert session.previous_response_id == "resp_002"
      assert data2.text == "reply 2"

      # Verify the second request carried previous_response_id: "resp_001"
      assert_receive {^ref, %{body: %{input: [%{content: "first"}]} = body1}}
      refute Map.has_key?(body1, :previous_response_id)

      assert_receive {^ref, %{body: %{input: [%{content: "second"}]} = body2}}
      assert body2.previous_response_id == "resp_001"
    end

    test "instructions are resent on every turn" do
      ref = make_ref()

      turns = [
        ok_response("r1", id: "resp_001").(nil),
        ok_response("r2", id: "resp_002").(nil)
      ]

      {:ok, agent_pid} = Agent.start_link(fn -> turns end)
      test_pid = self()

      http_fn = fn req ->
        send(test_pid, {ref, req})

        Agent.get_and_update(agent_pid, fn
          [next | rest] -> {next, rest}
          [] -> {{:error, :out_of_turns}, []}
        end)
      end

      {:ok, session} =
        OpenAI.start_session(
          api_key: "sk-test",
          instructions: "Always be terse.",
          http_fn: http_fn
        )

      {:ok, events1, session} = OpenAI.prompt(session, "first")
      %{data: data1} = Enum.find(events1, &(&1.kind == :result))
      session = OpenAI.update_session(session, data1)

      {:ok, _events2, _session} = OpenAI.prompt(session, "second")

      assert_receive {^ref, %{body: %{instructions: "Always be terse."}}}
      assert_receive {^ref, %{body: %{instructions: "Always be terse."}}}
    end
  end
end
