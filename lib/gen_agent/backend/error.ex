defmodule GenAgent.Backend.Error do
  @moduledoc """
  A backend-independent failure returned by the bundled backend adapters.

  `:kind` is a coarse classifier suitable for application retry policies;
  `:retryable?` indicates that another attempt may succeed. A retry is never
  performed automatically. `:retry_after` preserves the HTTP `Retry-After`
  header value (seconds or an HTTP date) when the provider supplies one.
  `:raw` retains the original provider value for provider-specific handling.
  Neither `:message` nor `:raw` should be logged without considering secrets.
  """

  @enforce_keys [:provider, :kind, :retryable?]
  defstruct [:provider, :kind, :retryable?, :status, :retry_after, :message, :raw]

  @type t :: %__MODULE__{
          provider: :claude | :codex | :anthropic | :openai,
          kind: atom(),
          retryable?: boolean(),
          status: non_neg_integer() | nil,
          retry_after: String.t() | nil,
          message: String.t() | nil,
          raw: term()
        }

  @doc "Build an error from a non-2xx HTTP response."
  @spec http(atom(), non_neg_integer(), term(), map() | list(), term()) :: t()
  def http(provider, status, body, headers \\ %{}, raw \\ nil) do
    %__MODULE__{
      provider: provider,
      kind: http_kind(status),
      retryable?: status in [408, 409, 425, 429] or status >= 500,
      status: status,
      retry_after: retry_after(headers),
      message: provider_message(body),
      raw: raw || %{body: body, headers: headers}
    }
  end

  @doc "Build a non-HTTP provider or transport error without guessing retryability."
  @spec new(atom(), atom(), term(), keyword()) :: t()
  def new(provider, kind, raw, opts \\ []) do
    %__MODULE__{
      provider: provider,
      kind: kind,
      retryable?: Keyword.get(opts, :retryable?, false),
      status: Keyword.get(opts, :status),
      retry_after: Keyword.get(opts, :retry_after),
      message: Keyword.get(opts, :message, provider_message(raw)),
      raw: raw
    }
  end

  @doc "Normalize a provider failure while keeping its original value in `:raw`."
  @spec normalize(atom(), term()) :: t()
  def normalize(_provider, %__MODULE__{} = error), do: error

  def normalize(provider, {:http_error, status, body}) when is_integer(status),
    do: http(provider, status, body, %{}, {:http_error, status, body})

  def normalize(provider, %{__struct__: Req.TransportError} = raw) do
    retryable? = Map.get(raw, :reason) in [:timeout, :closed, :econnreset]
    new(provider, :transport, raw, retryable?: retryable?, message: Exception.message(raw))
  end

  def normalize(provider, {kind, value} = raw) when is_atom(kind),
    do: new(provider, kind, raw, message: provider_message(value))

  def normalize(provider, raw), do: new(provider, :provider_error, raw)

  defp http_kind(429), do: :rate_limited
  defp http_kind(status) when status in [401, 403], do: :authentication
  defp http_kind(status) when status in [400, 404, 422], do: :invalid_request
  defp http_kind(status) when status >= 500, do: :server_error
  defp http_kind(_status), do: :http_error

  defp retry_after(headers) do
    Enum.find_value(headers, &retry_after_value/1)
  end

  defp retry_after_value({name, value}) do
    if String.downcase(to_string(name)) == "retry-after", do: first_header_value(value)
  end

  defp first_header_value([first | _]) when is_binary(first), do: first
  defp first_header_value(value) when is_binary(value), do: value
  defp first_header_value(_), do: nil

  defp provider_message(%{"error" => %{"message" => message}}) when is_binary(message),
    do: message

  defp provider_message(%{"error" => message}) when is_binary(message), do: message
  defp provider_message(%{"message" => message}) when is_binary(message), do: message
  defp provider_message(%{message: message}) when is_binary(message), do: message
  defp provider_message(message) when is_binary(message), do: message
  defp provider_message(_), do: nil
end
