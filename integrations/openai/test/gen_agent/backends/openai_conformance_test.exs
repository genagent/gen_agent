defmodule GenAgent.Backends.OpenAIConformanceTest do
  use GenAgent.Test.BackendConformance, async: true
  alias GenAgent.Test.BackendErrorAssertions, as: Errors

  defp conformance_setup(_context) do
    observer = self()

    http_fn = fn request ->
      send(observer, {:conformance_request, request.body})

      case List.last(request.body.input).content do
        "fail" -> {:error, {:http_error, 401, %{"error" => "fixture failure"}}}
        _prompt -> {:ok, api_response()}
      end
    end

    %{
      backend: GenAgent.Backends.OpenAI,
      agent_opts: [api_key: "test-key", http_fn: http_fn],
      first_prompt: "first",
      second_prompt: "second",
      error_prompt: "fail",
      assert_error: fn reason ->
        Errors.assert_error(reason, :openai, {:http_error, 401, %{"error" => "fixture failure"}})
      end,
      assert_threaded: fn _first, _second ->
        assert_receive {:conformance_request, first_body}
        refute Map.has_key?(first_body, :previous_response_id)

        assert_receive {:conformance_request,
                        %{
                          previous_response_id: "resp_conformance",
                          input: [%{role: "user", content: "second"}]
                        }}
      end
    }
  end

  defp api_response do
    %{
      "id" => "resp_conformance",
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => "fixture reply"}]
        }
      ]
    }
  end
end
