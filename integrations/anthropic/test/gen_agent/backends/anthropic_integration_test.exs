defmodule GenAgent.Backends.AnthropicIntegrationTest do
  @moduledoc """
  End-to-end tests that drive a real `GenAgent` process with the
  Anthropic backend but with the HTTP call stubbed via an injected
  `http_fn`. This exercises the full state-machine path through an
  HTTP-shaped backend, not just the backend in isolation.
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  defmodule AnthropicAgent do
    use GenAgent

    defmodule State do
      defstruct responses: []
    end

    @impl true
    def init_agent(opts) do
      backend_opts =
        Keyword.take(opts, [:api_key, :model, :max_tokens, :system, :http_fn])

      {:ok, backend_opts, %State{}}
    end

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      {:noreply, %{state | responses: state.responses ++ [response]}}
    end
  end

  defp api_response(text, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "msg_01"),
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => text}],
      "model" => "claude-sonnet-4-5",
      "stop_reason" => "end_turn",
      "usage" => %{
        "input_tokens" => Keyword.get(opts, :input_tokens, 10),
        "output_tokens" => Keyword.get(opts, :output_tokens, 5)
      }
    }
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp start_anthropic_agent(http_fn, extra_opts \\ []) do
    name = unique_name("anthropic")

    {:ok, _pid} =
      GenAgent.start_agent(
        AnthropicAgent,
        [
          name: name,
          backend: GenAgent.Backends.Anthropic,
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

      name = start_anthropic_agent(http_fn)

      assert {:ok, response} = GenAgent.ask(name, "hi")
      assert response.text == "hello from the API"
      assert response.usage == %{input_tokens: 10, output_tokens: 5}
      assert is_binary(response.session_id)
      assert String.starts_with?(response.session_id, "anthropic-")
    end

    test "the state machine threads the updated backend session across turns" do
      # This is the critical test for the HTTP-backend pattern:
      # the user message is appended to the session inside prompt/2,
      # the assistant message is appended in update_session/2 when the
      # terminal :result event is delivered, and the NEXT prompt sees
      # both in the full history. If the state machine isn't correctly
      # rebinding backend_session from both callback returns, multi-turn
      # will drop messages.

      test_pid = self()
      ref = make_ref()

      http_fn = fn req ->
        send(test_pid, {ref, req.body.messages})
        # Echo back the last user message so we can verify history
        last_user =
          req.body.messages
          |> Enum.reverse()
          |> Enum.find(fn m -> m.role == "user" end)

        {:ok, api_response("you said: #{last_user.content}")}
      end

      name = start_anthropic_agent(http_fn)

      {:ok, r1} = GenAgent.ask(name, "one")
      {:ok, r2} = GenAgent.ask(name, "two")
      {:ok, r3} = GenAgent.ask(name, "three")

      assert r1.text == "you said: one"
      assert r2.text == "you said: two"
      assert r3.text == "you said: three"

      # The third call should have seen the full history.
      assert_receive {^ref, [%{role: "user", content: "one"}]}

      assert_receive {^ref,
                      [
                        %{role: "user", content: "one"},
                        %{role: "assistant", content: "you said: one"},
                        %{role: "user", content: "two"}
                      ]}

      assert_receive {^ref,
                      [
                        %{role: "user", content: "one"},
                        %{role: "assistant", content: "you said: one"},
                        %{role: "user", content: "two"},
                        %{role: "assistant", content: "you said: two"},
                        %{role: "user", content: "three"}
                      ]}
    end

    test "session_ids are stable across turns (client-generated)" do
      http_fn = fn _req -> {:ok, api_response("ok")} end
      name = start_anthropic_agent(http_fn)

      {:ok, r1} = GenAgent.ask(name, "turn 1")
      {:ok, r2} = GenAgent.ask(name, "turn 2")

      assert r1.session_id == r2.session_id
    end

    test "propagates HTTP errors" do
      http_fn = fn _req -> {:error, {:http_error, 401, %{"error" => "invalid api key"}}} end

      name = start_anthropic_agent(http_fn)

      assert {:error, {:http_error, 401, _}} = GenAgent.ask(name, "hi")
    end
  end
end
