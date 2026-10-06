defmodule GenAgent.BackendErrorTest do
  use ExUnit.Case, async: true

  alias GenAgent.Backend.Error

  test "classifies throttling with retry metadata and retains the response" do
    body = %{"error" => %{"message" => "slow down"}}
    headers = %{"Retry-After" => ["12"]}
    raw = %{body: body, headers: headers}

    assert %Error{
             provider: :openai,
             kind: :rate_limited,
             retryable?: true,
             status: 429,
             retry_after: "12",
             message: "slow down",
             raw: ^raw
           } = Error.http(:openai, 429, body, headers, raw)
  end

  test "does not classify authorization and invalid request responses as retryable" do
    assert %Error{kind: :authentication, retryable?: false} =
             Error.http(:anthropic, 401, %{})

    assert %Error{kind: :invalid_request, retryable?: false} =
             Error.http(:openai, 400, %{})
  end

  test "normalizes provider reasons without losing raw evidence" do
    assert %Error{provider: :claude, kind: :provider_error, retryable?: false, raw: "denied"} =
             Error.normalize(:claude, "denied")

    assert %Error{provider: :codex, kind: :idle_timeout, raw: {:idle_timeout, 200}} =
             Error.normalize(:codex, {:idle_timeout, 200})
  end
end
