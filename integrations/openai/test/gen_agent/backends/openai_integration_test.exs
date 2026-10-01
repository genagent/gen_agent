defmodule GenAgent.Backends.OpenAIIntegrationTest do
  @moduledoc """
  End-to-end tests that drive a real `GenAgent` process with the
  OpenAI backend but with the HTTP call stubbed via an injected
  `http_fn`. This exercises the full state-machine path through an
  HTTP-shaped backend, not just the backend in isolation.

  The critical invariant under test: the server-side
  `previous_response_id` thread survives across turns, specifically
  that `update_session/2` is called with the terminal `:result`
  event's `response_id` and the next `prompt/2` reads it back.
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  defmodule OpenAIAgent do
    use GenAgent

    defmodule State do
      defstruct responses: []
    end

    @impl true
    def init_agent(opts) do
      backend_opts =
        Keyword.take(opts, [
          :api_key,
          :model,
          :instructions,
          :max_output_tokens,
          :reasoning_effort,
          :http_fn
        ])

      {:ok, backend_opts, %State{}}
    end

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      {:noreply, %{state | responses: state.responses ++ [response]}}
    end
  end

  defp api_response(text, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "resp_01"),
      "object" => "response",
      "model" => "gpt-5",
      "status" => "completed",
      "store" => true,
      "output" => [
        %{
          "id" => "msg_01",
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ],
      "usage" => %{
        "input_tokens" => Keyword.get(opts, :input_tokens, 10),
        "output_tokens" => Keyword.get(opts, :output_tokens, 5),
        "total_tokens" =>
          Keyword.get(opts, :input_tokens, 10) + Keyword.get(opts, :output_tokens, 5)
      }
    }
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp start_openai_agent(http_fn, extra_opts \\ []) do
    name = unique_name("openai")

    {:ok, _pid} =
      GenAgent.start_agent(
        OpenAIAgent,
        [
          name: name,
          backend: GenAgent.Backends.OpenAI,
          api_key: "sk-test",
          http_fn: http_fn
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
    test "assembles a Response from the faked API call" do
      http_fn = fn _req -> {:ok, api_response("hello from the API")} end
      name = start_openai_agent(http_fn)

      assert {:ok, response} = GenAgent.ask(name, "hi")
      assert response.text == "hello from the API"
      assert response.usage.input_tokens == 10
      assert response.usage.output_tokens == 5
      assert response.usage.total_tokens == 15
      assert is_binary(response.session_id)
      assert String.starts_with?(response.session_id, "openai-")
    end

    test "the state machine threads previous_response_id across turns" do
      # The critical test for the OpenAI backend shape: on turn 1
      # the request has no previous_response_id; on turn 2 it carries
      # the id returned in turn 1's terminal :result event. If
      # update_session/2 doesn't run, or the state machine doesn't
      # rebind the backend session after it, turn 2 would come in
      # as a fresh context and server-side state would be lost.

      test_pid = self()
      ref = make_ref()

      # Script three turns with distinct response ids.
      turn_ids = ["resp_001", "resp_002", "resp_003"]
      {:ok, agent_pid} = Agent.start_link(fn -> turn_ids end)

      http_fn = fn req ->
        send(test_pid, {ref, req.body})

        id =
          Agent.get_and_update(agent_pid, fn
            [next | rest] -> {next, rest}
            [] -> {"resp_extra", []}
          end)

        {:ok, api_response("id was #{id}", id: id)}
      end

      name = start_openai_agent(http_fn)

      {:ok, r1} = GenAgent.ask(name, "one")
      {:ok, r2} = GenAgent.ask(name, "two")
      {:ok, r3} = GenAgent.ask(name, "three")

      assert r1.text == "id was resp_001"
      assert r2.text == "id was resp_002"
      assert r3.text == "id was resp_003"

      # Turn 1: no previous_response_id.
      assert_receive {^ref, %{input: [%{content: "one"}]} = body1}
      refute Map.has_key?(body1, :previous_response_id)

      # Turn 2: previous_response_id == "resp_001" (from turn 1).
      assert_receive {^ref, %{input: [%{content: "two"}], previous_response_id: "resp_001"}}

      # Turn 3: previous_response_id == "resp_002" (from turn 2).
      assert_receive {^ref, %{input: [%{content: "three"}], previous_response_id: "resp_002"}}
    end

    test "session_ids (client-generated) are stable across turns" do
      http_fn = fn _req -> {:ok, api_response("ok")} end
      name = start_openai_agent(http_fn)

      {:ok, r1} = GenAgent.ask(name, "turn 1")
      {:ok, r2} = GenAgent.ask(name, "turn 2")

      assert r1.session_id == r2.session_id
    end

    test "propagates HTTP errors" do
      http_fn = fn _req -> {:error, {:http_error, 401, %{"error" => "invalid api key"}}} end
      name = start_openai_agent(http_fn)

      assert {:error, {:http_error, 401, _}} = GenAgent.ask(name, "hi")
    end

    test "failed responses leave the previous successful response id intact" do
      failed =
        api_response("", id: "resp_failed")
        |> Map.merge(%{
          "status" => "failed",
          "error" => %{"code" => "server_error", "message" => "generation failed"}
        })

      assert_rejected_turn_preserves_response_id(
        failed,
        {:response_failed, failed["error"]}
      )
    end

    test "incomplete responses leave the previous successful response id intact" do
      incomplete =
        api_response("partial answer", id: "resp_incomplete")
        |> Map.merge(%{
          "status" => "incomplete",
          "incomplete_details" => %{"reason" => "max_output_tokens"}
        })

      assert_rejected_turn_preserves_response_id(
        incomplete,
        {:response_incomplete, incomplete["incomplete_details"]}
      )
    end

    test "refusals leave the previous successful response id intact" do
      refused =
        api_response("", id: "resp_refused")
        |> Map.put("output", [
          %{
            "type" => "message",
            "content" => [%{"type" => "refusal", "refusal" => "I cannot help."}]
          }
        ])

      assert_rejected_turn_preserves_response_id(refused, {:refusal, "I cannot help."})
    end

    test "instructions are forwarded to the backend and resent each turn" do
      test_pid = self()
      ref = make_ref()

      http_fn = fn req ->
        send(test_pid, {ref, req.body[:instructions]})
        {:ok, api_response("ok")}
      end

      name =
        start_openai_agent(http_fn, instructions: "Respond with one word only.")

      {:ok, _r1} = GenAgent.ask(name, "hello")
      {:ok, _r2} = GenAgent.ask(name, "again")

      assert_receive {^ref, "Respond with one word only."}
      assert_receive {^ref, "Respond with one word only."}
    end
  end

  defp assert_rejected_turn_preserves_response_id(rejected_body, expected_reason) do
    test_pid = self()
    ref = make_ref()
    responses = [api_response("first", id: "resp_first"), rejected_body, api_response("third")]
    {:ok, responses_pid} = Agent.start_link(fn -> responses end)

    http_fn = fn req ->
      send(test_pid, {ref, req.body})

      Agent.get_and_update(responses_pid, fn
        [next | rest] -> {{:ok, next}, rest}
        [] -> {{:error, :out_of_responses}, []}
      end)
    end

    name = start_openai_agent(http_fn)

    assert {:ok, %{text: "first"}} = GenAgent.ask(name, "first")
    assert {:error, ^expected_reason} = GenAgent.ask(name, "rejected")
    assert {:ok, %{text: "third"}} = GenAgent.ask(name, "third")

    assert_receive {^ref, first_request}
    refute Map.has_key?(first_request, :previous_response_id)
    assert_receive {^ref, %{previous_response_id: "resp_first"}}
    assert_receive {^ref, %{previous_response_id: "resp_first"}}
  end
end
