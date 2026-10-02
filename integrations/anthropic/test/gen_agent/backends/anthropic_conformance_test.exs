defmodule GenAgent.Backends.AnthropicConformanceTest do
  use GenAgent.Test.BackendConformance, async: true

  defp conformance_setup(_context) do
    observer = self()

    http_fn = fn request ->
      send(observer, {:conformance_request, request.body})

      case List.last(request.body.messages).content do
        "fail" -> {:error, {:http_error, 401, %{"error" => "fixture failure"}}}
        _prompt -> {:ok, api_response()}
      end
    end

    %{
      backend: GenAgent.Backends.Anthropic,
      agent_opts: [api_key: "test-key", http_fn: http_fn],
      first_prompt: "first",
      second_prompt: "second",
      error_prompt: "fail",
      assert_error: fn reason ->
        assert reason == {:http_error, 401, %{"error" => "fixture failure"}}
      end,
      assert_threaded: fn _first, _second ->
        assert_receive {:conformance_request, %{messages: [%{role: "user", content: "first"}]}}

        assert_receive {:conformance_request,
                        %{
                          messages: [
                            %{role: "user", content: "first"},
                            %{role: "assistant", content: "fixture reply"},
                            %{role: "user", content: "second"}
                          ]
                        }}
      end
    }
  end

  defp api_response do
    %{
      "id" => "msg_conformance",
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => "fixture reply"}]
    }
  end
end
