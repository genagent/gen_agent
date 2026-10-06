defmodule GenAgent.Test.BackendErrorAssertions do
  @moduledoc false
  import ExUnit.Assertions

  alias GenAgent.Backend.Error
  @compile {:no_warn_undefined, Error}

  def expected(provider, raw) do
    if Code.ensure_loaded?(Error), do: Error.normalize(provider, raw), else: raw
  end

  def assert_error(actual, provider, raw) do
    assert actual == expected(provider, raw)
    actual
  end

  def assert_http_response(actual, provider, status, body) do
    if Code.ensure_loaded?(Error) do
      assert %{
               __struct__: Error,
               provider: ^provider,
               status: ^status,
               raw: %{__struct__: Req.Response, body: ^body}
             } = actual
    else
      assert actual == {:http_error, status, body}
    end

    actual
  end

  def assert_invalid_response(actual, provider, body) do
    if Code.ensure_loaded?(Error) do
      assert %{__struct__: Error, provider: ^provider, kind: :invalid_response, raw: ^body} =
               actual
    else
      assert actual == {:invalid_response, body}
    end

    actual
  end
end
