defmodule GenAgent.Backends.AnthropicHTTPTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Anthropic
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
      id: "msg_test",
      model: "claude-test",
      stop_reason: "end_turn",
      content: [%{type: "text", text: "hello"}],
      usage: %{input_tokens: 3, output_tokens: 2}
    })

    {:ok, session} = Anthropic.start_session(api_key: "test-key", model: "claude-test")
    assert {:ok, [usage, result], _session} = Anthropic.prompt(session, "ping")
    assert usage.kind == :usage
    assert usage.data == %{input_tokens: 3, output_tokens: 2}
    assert result.kind == :result
    assert result.data.text == "hello"

    assert_receive {:req_request, request}
    assert request.method == :post
    assert URI.to_string(request.url) == "https://api.anthropic.com/v1/messages"
    assert Req.Request.get_header(request, "x-api-key") == ["test-key"]
    assert Req.Request.get_header(request, "anthropic-version") == ["2023-06-01"]

    assert Jason.decode!(request.body) == %{
             "model" => "claude-test",
             "max_tokens" => 1024,
             "messages" => [%{"role" => "user", "content" => "ping"}]
           }

    assert request.options[:receive_timeout] == 60_000
    refute Map.has_key?(request.options, :connect_options)
    refute Map.has_key?(request.options, :finch)
    assert request.options[:retry] == false
    assert request.options[:redirect] == false
  end

  test "default Req transport sends configured URL, headers, version, and fields" do
    reply_json(200, %{
      id: "msg_test",
      model: "claude-test",
      stop_reason: "end_turn",
      content: [%{type: "text", text: "hello"}]
    })

    {:ok, session} =
      Anthropic.start_session(
        api_key: "test-key",
        base_url: "http://localhost:8080/proxy/v1/",
        api_version: "2023-01-01",
        headers: [{"Anthropic-Beta", "test-feature"}],
        request_fields: %{temperature: 0.3}
      )

    assert {:ok, _, _} = Anthropic.prompt(session, "ping")
    assert_receive {:req_request, request}
    assert URI.to_string(request.url) == "http://localhost:8080/proxy/v1/messages"
    assert Req.Request.get_header(request, "x-api-key") == ["test-key"]
    assert Req.Request.get_header(request, "anthropic-version") == ["2023-01-01"]
    assert Req.Request.get_header(request, "anthropic-beta") == ["test-feature"]
    assert Jason.decode!(request.body)["temperature"] == 0.3
    assert request.options[:redirect] == false
  end

  test "passes per-session Finch pool options without conflicting connect options" do
    reply_json(200, %{
      id: "msg_test",
      stop_reason: "end_turn",
      content: [%{type: "text", text: "hello"}]
    })

    {:ok, dynamic} =
      Anthropic.start_session(
        api_key: "test-key",
        finch: [size: 100, count: 2, pool_timeout: 20_000],
        connect_timeout: 2_000
      )

    assert {:ok, _, _} = Anthropic.prompt(dynamic, "ping")
    assert_receive {:req_request, request}

    assert Map.new(request.options[:finch]) == %{
             size: 100,
             count: 2,
             pool_timeout: 20_000,
             conn_opts: [transport_opts: [timeout: 2_000]]
           }

    refute Map.has_key?(request.options, :connect_options)

    {:ok, named} =
      Anthropic.start_session(api_key: "test-key", finch: [name: MyFinch, pool_timeout: 20_000])

    assert {:ok, _, _} = Anthropic.prompt(named, "ping")
    assert_receive {:req_request, request}
    assert request.options[:finch] == [name: MyFinch, pool_timeout: 20_000]
    refute Map.has_key?(request.options, :connect_options)
  end

  test "connect timeout overrides a VM-global named Finch setting" do
    reply_json(200, %{
      id: "msg_test",
      stop_reason: "end_turn",
      content: [%{type: "text", text: "hello"}]
    })

    Req.default_options(Keyword.put(Req.default_options(), :finch, name: GlobalFinch))
    {:ok, session} = Anthropic.start_session(api_key: "test-key", connect_timeout: 2_000)

    assert {:ok, _, _} = Anthropic.prompt(session, "ping")
    assert_receive {:req_request, request}
    assert Map.has_key?(request.options, :finch)
    assert request.options[:finch] == nil
    assert request.options[:connect_options] == [timeout: 2_000]
  end

  test "cross-host redirects never forward the API key or conversation" do
    {:ok, session} = Anthropic.start_session(api_key: "test-key")

    for status <- [302, 307, 308] do
      Process.put(
        {Adapter, :reply},
        Req.Response.new(
          status: status,
          headers: %{"location" => ["https://other.example/messages"]},
          body: "redirect"
        )
      )

      assert {:error, reason} = Anthropic.prompt(session, "private prompt")
      Errors.assert_http_response(reason, :anthropic, status, "redirect")

      assert_receive {:req_request, request}
      assert URI.to_string(request.url) == "https://api.anthropic.com/v1/messages"
      assert Req.Request.get_header(request, "x-api-key") == ["test-key"]

      assert Jason.decode!(request.body)["messages"] == [
               %{"role" => "user", "content" => "private prompt"}
             ]

      assert request.options[:redirect] == false
      refute_receive {:req_request, _request}
    end
  end

  test "non-200 responses preserve status and decoded body, with custom timeouts" do
    error_body = %{"type" => "error", "error" => %{"type" => "overloaded_error"}}
    reply_json(529, error_body)

    {:ok, session} =
      Anthropic.start_session(
        api_key: "test-key",
        receive_timeout: 12_345,
        connect_timeout: 2_345
      )

    assert {:error, reason} = Anthropic.prompt(session, "ping")
    Errors.assert_http_response(reason, :anthropic, 529, error_body)
    assert_receive {:req_request, request}
    assert request.options[:receive_timeout] == 12_345
    assert request.options[:connect_options] == [timeout: 2_345]
  end

  test "transport errors pass through without retry" do
    error = %Req.TransportError{reason: :timeout}
    Process.put({Adapter, :reply}, error)

    {:ok, session} = Anthropic.start_session(api_key: "test-key")

    assert {:error, reason} = Anthropic.prompt(session, "ping")
    Errors.assert_error(reason, :anthropic, error)

    assert_receive {:req_request, _request}
    refute_receive {:req_request, _request}
  end

  test "retains retry-after and response headers on a rate limit" do
    Process.put(
      {Adapter, :reply},
      Req.Response.new(
        status: 429,
        headers: %{"retry-after" => ["7"], "content-type" => ["application/json"]},
        body: Jason.encode!(%{"error" => %{"message" => "slow down"}})
      )
    )

    {:ok, session} = Anthropic.start_session(api_key: "test-key")

    assert {:error, reason} = Anthropic.prompt(session, "ping")

    Errors.assert_http_response(reason, :anthropic, 429, %{"error" => %{"message" => "slow down"}})

    if Code.ensure_loaded?(GenAgent.Backend.Error) do
      assert %{kind: :rate_limited, retryable?: true, retry_after: "7", message: "slow down"} =
               reason

      assert reason.raw.headers["retry-after"] == ["7"]
    end
  end

  test "a successful HTTP status with an invalid body is a parsing error" do
    Process.put(
      {Adapter, :reply},
      Req.Response.new(status: 200, headers: %{"content-type" => ["text/html"]}, body: "oops")
    )

    {:ok, session} = Anthropic.start_session(api_key: "test-key")

    assert {:error, reason} = Anthropic.prompt(session, "ping")
    Errors.assert_invalid_response(reason, :anthropic, "oops")
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
