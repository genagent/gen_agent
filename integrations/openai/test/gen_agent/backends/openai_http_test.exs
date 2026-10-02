defmodule GenAgent.Backends.OpenAIHTTPTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.OpenAI

  defmodule Adapter do
    @moduledoc false

    def run(request) do
      send(self(), {:req_request, request})
      {request, Process.get({__MODULE__, :reply})}
    end
  end

  setup do
    previous_options = Req.default_options()
    Req.default_options(Keyword.put(previous_options, :adapter, Adapter))
    on_exit(fn -> Req.default_options(previous_options) end)
    :ok
  end

  test "default Req path posts JSON and decodes a successful response" do
    reply_json(200, %{
      id: "resp_test",
      model: "gpt-test",
      status: "completed",
      output: [%{type: "message", content: [%{type: "output_text", text: "hello"}]}],
      usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
    })

    {:ok, session} = OpenAI.start_session(api_key: "test-key", model: "gpt-test")
    assert {:ok, [usage, result], _session} = OpenAI.prompt(session, "ping")
    assert usage.kind == :usage
    assert usage.data == %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
    assert result.kind == :result
    assert result.data.text == "hello"
    assert result.data.response_id == "resp_test"

    assert_receive {:req_request, request}
    assert request.method == :post
    assert URI.to_string(request.url) == "https://api.openai.com/v1/responses"
    assert Req.Request.get_header(request, "authorization") == ["Bearer test-key"]

    assert Jason.decode!(request.body) == %{
             "model" => "gpt-test",
             "input" => [%{"role" => "user", "content" => "ping"}],
             "store" => true
           }

    assert request.options[:receive_timeout] == 60_000
    refute Map.has_key?(request.options, :connect_options)
    assert request.options[:retry] == false
  end

  test "non-200 responses preserve status and decoded body, with custom timeouts" do
    error_body = %{"error" => %{"type" => "rate_limit_exceeded"}}
    reply_json(429, error_body)

    {:ok, session} =
      OpenAI.start_session(
        api_key: "test-key",
        receive_timeout: 12_345,
        connect_timeout: 2_345
      )

    assert {:error, {:http_error, 429, ^error_body}} = OpenAI.prompt(session, "ping")
    assert_receive {:req_request, request}
    assert request.options[:receive_timeout] == 12_345
    assert request.options[:connect_options] == [timeout: 2_345]
  end

  test "transport errors pass through without retry" do
    error = %Req.TransportError{reason: :timeout}
    Process.put({Adapter, :reply}, error)

    {:ok, session} = OpenAI.start_session(api_key: "test-key")
    assert {:error, ^error} = OpenAI.prompt(session, "ping")
    assert_receive {:req_request, _request}
    refute_receive {:req_request, _request}
  end

  defp reply_json(status, body) do
    Process.put(
      {Adapter, :reply},
      Req.Response.new(
        status: status,
        headers: %{"content-type" => ["application/json"]},
        body: Jason.encode!(body)
      )
    )
  end
end
