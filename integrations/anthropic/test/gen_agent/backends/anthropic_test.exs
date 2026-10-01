defmodule GenAgent.Backends.AnthropicTest do
  use ExUnit.Case, async: true

  alias GenAgent.Backends.Anthropic
  alias GenAgent.Event

  defp ok_response(text, opts \\ []) do
    fn _req ->
      {:ok,
       %{
         "id" => Keyword.get(opts, :id, "msg_01abc"),
         "type" => "message",
         "role" => "assistant",
         "content" => [%{"type" => "text", "text" => text}],
         "model" => Keyword.get(opts, :model, "claude-sonnet-4-5"),
         "stop_reason" => Keyword.get(opts, :stop_reason, "end_turn"),
         "usage" => %{
           "input_tokens" => Keyword.get(opts, :input_tokens, 10),
           "output_tokens" => Keyword.get(opts, :output_tokens, 5)
         }
       }}
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
    test "reads api_key from opts" do
      {:ok, session} =
        Anthropic.start_session(api_key: "sk-test", http_fn: ok_response("hi"))

      assert session.api_key == "sk-test"
    end

    test "falls back to ANTHROPIC_API_KEY env var" do
      System.put_env("ANTHROPIC_API_KEY", "env-key")
      {:ok, session} = Anthropic.start_session(http_fn: ok_response("hi"))
      assert session.api_key == "env-key"
    after
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "starts with empty messages and a generated client_session_id" do
      {:ok, session} = Anthropic.start_session(http_fn: ok_response("hi"))
      assert session.messages == []
      assert is_binary(session.client_session_id)
      assert String.starts_with?(session.client_session_id, "anthropic-")
    end

    test "uses defaults for model and max_tokens" do
      {:ok, session} = Anthropic.start_session(http_fn: ok_response("hi"))
      assert session.model == "claude-sonnet-4-5"
      assert session.max_tokens == 1024
    end

    test "accepts :system prompt and overrides" do
      {:ok, session} =
        Anthropic.start_session(
          http_fn: ok_response("hi"),
          system: "You are terse.",
          model: "claude-opus-4-6",
          max_tokens: 4096
        )

      assert session.system == "You are terse."
      assert session.model == "claude-opus-4-6"
      assert session.max_tokens == 4096
    end

    test "receive_timeout defaults to 60_000" do
      {:ok, session} = Anthropic.start_session(http_fn: ok_response("hi"))
      assert session.receive_timeout == 60_000
    end

    test "accepts explicit :receive_timeout and :connect_timeout" do
      {:ok, session} =
        Anthropic.start_session(
          http_fn: ok_response("hi"),
          receive_timeout: 180_000,
          connect_timeout: 5_000
        )

      assert session.receive_timeout == 180_000
      assert session.connect_timeout == 5_000
    end
  end

  describe "prompt/2" do
    test "appends the user message to session before the call" do
      ref = make_ref()

      {:ok, session} =
        Anthropic.start_session(
          api_key: "sk-test",
          http_fn: recording_fn(ref, ok_response("pong"))
        )

      {:ok, _events, session} = Anthropic.prompt(session, "ping")

      assert_receive {^ref, request}
      assert request.body.messages == [%{role: "user", content: "ping"}]
      assert session.messages == [%{role: "user", content: "ping"}]
    end

    test "includes full history on the second turn" do
      ref = make_ref()

      {:ok, session} =
        Anthropic.start_session(
          api_key: "sk-test",
          http_fn: recording_fn(ref, ok_response("response"))
        )

      {:ok, _events, session} = Anthropic.prompt(session, "first")
      # simulate what the state machine does on :result
      session = Anthropic.update_session(session, %{text: "assistant reply 1"})

      {:ok, _events, session} = Anthropic.prompt(session, "second")

      assert session.messages == [
               %{role: "user", content: "first"},
               %{role: "assistant", content: "assistant reply 1"},
               %{role: "user", content: "second"}
             ]

      # Inspect the most recent request body
      assert_receive {^ref, _first_req}
      assert_receive {^ref, second_req}

      assert second_req.body.messages == [
               %{role: "user", content: "first"},
               %{role: "assistant", content: "assistant reply 1"},
               %{role: "user", content: "second"}
             ]
    end

    test "builds headers with api key and anthropic version" do
      ref = make_ref()

      {:ok, session} =
        Anthropic.start_session(
          api_key: "sk-test-xyz",
          http_fn: recording_fn(ref, ok_response("x"))
        )

      {:ok, _events, _session} = Anthropic.prompt(session, "hi")

      assert_receive {^ref, request}
      headers = Map.new(request.headers)
      assert headers["x-api-key"] == "sk-test-xyz"
      assert headers["anthropic-version"] == "2023-06-01"
      assert headers["content-type"] == "application/json"
    end

    test "request includes receive_timeout and connect_timeout for http_fn" do
      ref = make_ref()

      {:ok, session} =
        Anthropic.start_session(
          api_key: "sk-test",
          receive_timeout: 120_000,
          connect_timeout: 5_000,
          http_fn: recording_fn(ref, ok_response("x"))
        )

      {:ok, _events, _session} = Anthropic.prompt(session, "hi")

      assert_receive {^ref, request}
      assert request.receive_timeout == 120_000
      assert request.connect_timeout == 5_000
    end

    test "request uses default receive_timeout when not overridden" do
      ref = make_ref()

      {:ok, session} =
        Anthropic.start_session(
          api_key: "sk-test",
          http_fn: recording_fn(ref, ok_response("x"))
        )

      {:ok, _events, _session} = Anthropic.prompt(session, "hi")

      assert_receive {^ref, request}
      assert request.receive_timeout == 60_000
      assert request.connect_timeout == nil
    end

    test "includes system prompt in the body when set" do
      ref = make_ref()

      {:ok, session} =
        Anthropic.start_session(
          api_key: "sk-test",
          system: "Be brief.",
          http_fn: recording_fn(ref, ok_response("k"))
        )

      {:ok, _events, _session} = Anthropic.prompt(session, "hello")

      assert_receive {^ref, request}
      assert request.body.system == "Be brief."
    end

    test "translates response into :usage + :result events" do
      {:ok, session} =
        Anthropic.start_session(
          api_key: "sk-test",
          http_fn: ok_response("pong", input_tokens: 12, output_tokens: 3)
        )

      {:ok, events, _} = Anthropic.prompt(session, "ping")
      events_list = Enum.to_list(events)

      assert [
               %Event{kind: :usage, data: %{input_tokens: 12, output_tokens: 3}},
               %Event{kind: :result, data: data}
             ] = events_list

      assert data.text == "pong"
      assert data.stop_reason == "end_turn"
      assert is_binary(data.session_id)
    end

    test "propagates HTTP errors" do
      failing = fn _req -> {:error, {:http_error, 429, %{"type" => "rate_limit"}}} end

      {:ok, session} = Anthropic.start_session(api_key: "sk-test", http_fn: failing)

      assert {:error, {:http_error, 429, _}} = Anthropic.prompt(session, "hi")
    end

    test "wraps a raising http_fn" do
      raising = fn _req -> raise "boom" end

      {:ok, session} = Anthropic.start_session(api_key: "sk-test", http_fn: raising)

      assert {:error, {:http_fn_raised, _}} = Anthropic.prompt(session, "hi")
    end
  end

  describe "update_session/2" do
    test "appends an assistant message when :text is present" do
      {:ok, session} = Anthropic.start_session(api_key: "sk-test", http_fn: ok_response("x"))
      session = %{session | messages: [%{role: "user", content: "hi"}]}

      session = Anthropic.update_session(session, %{text: "hello back"})

      assert session.messages == [
               %{role: "user", content: "hi"},
               %{role: "assistant", content: "hello back"}
             ]
    end

    test "ignores data without text" do
      {:ok, session} = Anthropic.start_session(api_key: "sk-test", http_fn: ok_response("x"))
      initial = session.messages

      session = Anthropic.update_session(session, %{other: "field"})
      assert session.messages == initial
    end

    test "ignores empty text" do
      {:ok, session} = Anthropic.start_session(api_key: "sk-test", http_fn: ok_response("x"))
      initial = session.messages

      session = Anthropic.update_session(session, %{text: ""})
      assert session.messages == initial
    end
  end

  describe "terminate_session/1" do
    test "is a no-op" do
      {:ok, session} = Anthropic.start_session(api_key: "sk-test", http_fn: ok_response("x"))
      assert :ok = Anthropic.terminate_session(session)
    end
  end

  describe "end-to-end through prompt → update_session → prompt" do
    test "the full round-trip session update pattern accumulates history" do
      ref = make_ref()

      turns = [
        ok_response("reply 1").(nil),
        ok_response("reply 2").(nil),
        ok_response("reply 3").(nil)
      ]

      turn_agent = Agent.start_link(fn -> turns end)
      {:ok, agent_pid} = turn_agent

      http_fn = fn req ->
        send(self(), {ref, req})

        Agent.get_and_update(agent_pid, fn
          [next | rest] -> {next, rest}
          [] -> {{:error, :out_of_turns}, []}
        end)
      end

      {:ok, session} = Anthropic.start_session(api_key: "sk-test", http_fn: http_fn)

      # Simulate what the state machine does: prompt → consume events → update_session
      {session, responses} =
        Enum.reduce(["q1", "q2", "q3"], {session, []}, fn question, {session, responses} ->
          {:ok, events, session} = Anthropic.prompt(session, question)

          result_data =
            events
            |> Enum.find(&(&1.kind == :result))
            |> Map.fetch!(:data)

          session = Anthropic.update_session(session, result_data)
          {session, responses ++ [result_data.text]}
        end)

      assert responses == ["reply 1", "reply 2", "reply 3"]

      assert session.messages == [
               %{role: "user", content: "q1"},
               %{role: "assistant", content: "reply 1"},
               %{role: "user", content: "q2"},
               %{role: "assistant", content: "reply 2"},
               %{role: "user", content: "q3"},
               %{role: "assistant", content: "reply 3"}
             ]
    end
  end
end
