defmodule GenAgent.Backends.OpenAIHTTPTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.OpenAI
  alias GenAgent.Test.BackendErrorAssertions, as: Errors

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
    assert request.options[:redirect] == false
  end

  test "default Req transport sends configured URL, headers, and fields" do
    reply_json(200, %{
      id: "resp_test",
      model: "gpt-test",
      status: "completed",
      output: [%{type: "message", content: [%{type: "output_text", text: "hello"}]}]
    })

    {:ok, session} =
      OpenAI.start_session(
        api_key: "test-key",
        base_url: "http://127.0.0.1:8080/proxy/v1/",
        headers: [{"X-Tenant", "team-a"}],
        request_fields: %{temperature: 0.3}
      )

    assert {:ok, _, _} = OpenAI.prompt(session, "ping")
    assert_receive {:req_request, request}
    assert URI.to_string(request.url) == "http://127.0.0.1:8080/proxy/v1/responses"
    assert Req.Request.get_header(request, "authorization") == ["Bearer test-key"]
    assert Req.Request.get_header(request, "x-tenant") == ["team-a"]
    assert Jason.decode!(request.body)["temperature"] == 0.3
    assert request.options[:redirect] == false
  end

  test "cross-host redirects never forward the API key or conversation" do
    {:ok, session} = OpenAI.start_session(api_key: "test-key")

    for status <- [302, 307, 308] do
      Process.put(
        {Adapter, :reply},
        Req.Response.new(
          status: status,
          headers: %{"location" => ["https://other.example/responses"]},
          body: "redirect"
        )
      )

      assert {:error, reason} = OpenAI.prompt(session, "private prompt")
      Errors.assert_http_response(reason, :openai, status, "redirect")

      assert_receive {:req_request, request}
      assert URI.to_string(request.url) == "https://api.openai.com/v1/responses"
      assert Req.Request.get_header(request, "authorization") == ["Bearer test-key"]

      assert Jason.decode!(request.body)["input"] == [
               %{"role" => "user", "content" => "private prompt"}
             ]

      assert request.options[:redirect] == false
      refute_receive {:req_request, _request}
    end
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

    assert {:error, reason} = OpenAI.prompt(session, "ping")
    Errors.assert_http_response(reason, :openai, 429, error_body)
    assert_receive {:req_request, request}
    assert request.options[:receive_timeout] == 12_345
    assert request.options[:connect_options] == [timeout: 2_345]
  end

  test "transport errors pass through without retry" do
    error = %Req.TransportError{reason: :timeout}
    Process.put({Adapter, :reply}, error)

    {:ok, session} = OpenAI.start_session(api_key: "test-key")

    assert {:error, reason} = OpenAI.prompt(session, "ping")
    Errors.assert_error(reason, :openai, error)

    assert_receive {:req_request, _request}
    refute_receive {:req_request, _request}
  end

  test "retains retry-after and response headers on a rate limit" do
    Process.put(
      {Adapter, :reply},
      Req.Response.new(
        status: 429,
        headers: %{"retry-after" => ["5"], "content-type" => ["application/json"]},
        body: Jason.encode!(%{"error" => %{"message" => "slow down"}})
      )
    )

    {:ok, session} = OpenAI.start_session(api_key: "test-key")

    assert {:error, reason} = OpenAI.prompt(session, "ping")
    Errors.assert_http_response(reason, :openai, 429, %{"error" => %{"message" => "slow down"}})

    if Code.ensure_loaded?(GenAgent.Backend.Error) do
      assert %{kind: :rate_limited, retryable?: true, retry_after: "5", message: "slow down"} =
               reason

      assert reason.raw.headers["retry-after"] == ["5"]
    end
  end

  test "a successful HTTP status with an invalid body is a parsing error" do
    Process.put(
      {Adapter, :reply},
      Req.Response.new(status: 200, headers: %{"content-type" => ["text/html"]}, body: "oops")
    )

    {:ok, session} = OpenAI.start_session(api_key: "test-key")

    assert {:error, reason} = OpenAI.prompt(session, "ping")
    Errors.assert_invalid_response(reason, :openai, "oops")
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
