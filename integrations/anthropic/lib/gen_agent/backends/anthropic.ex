defmodule GenAgent.Backends.Anthropic do
  @moduledoc """
  `GenAgent.Backend` implementation backed by the Anthropic Messages API.

  Unlike the CLI-backed backends (`GenAgent.Backends.Claude`,
  `GenAgent.Backends.Codex`), this backend talks directly to an HTTP
  API. The **conversation history lives in the session struct**,
  because the API is stateless -- every request carries the full
  messages array.

  This backend exists primarily as a **validation spike** for the
  `GenAgent.Backend` contract. The CLI backends share a lot of DNA
  with each other (subprocess + NDJSON + server-side session ids); an
  HTTP backend inverts most of that. Getting both to fit the same
  contract without changes is the real test of whether the
  abstraction is right.

  ## How the two halves of a turn land in the session

  1. `prompt/2` appends the user's message to `session.messages`
     **before** making the API call, and returns the updated session
     along with the event list. The state machine stores that updated
     session.
  2. When the state machine delivers the terminal `:result` event,
     it calls `update_session/2` with the event's data, and this
     backend appends the assistant's message to `session.messages`.
  3. The next `prompt/2` sees both messages in the session and sends
     the full history to the API.

  This uses both sides of the `GenAgent.Backend` contract in a way
  the CLI backends don't: CLI backends leave `prompt/2`'s returned
  session unchanged and do all updates in `update_session/2`.

  ## Options

    * `:api_key` -- Anthropic API key. Defaults to `System.get_env("ANTHROPIC_API_KEY")`.
    * `:model` -- model name. Defaults to `"claude-sonnet-4-5"`.
    * `:max_tokens` -- max tokens per turn. Defaults to `1024`.
    * `:system` -- system prompt (string).
    * `:receive_timeout` -- HTTP receive timeout in milliseconds.
      Defaults to `60_000`. Long-context turns (big messages array,
      slow models) can blow through Req's 15s default, so the backend
      picks a safer default. Set higher for large debates or longer
      generations.
    * `:connect_timeout` -- HTTP connect timeout in milliseconds.
      Defaults to Req's default when unset.
    * `:http_fn` -- a 1-arity function `(request_map) -> {:ok, response_map} | {:error, term}`
      that replaces the default `Req`-backed HTTP call. Intended for tests.
  """

  @behaviour GenAgent.Backend

  alias GenAgent.Event

  @endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @default_model "claude-sonnet-4-5"
  @default_max_tokens 1024
  @default_receive_timeout 60_000

  defstruct [
    :api_key,
    :model,
    :max_tokens,
    :system,
    :receive_timeout,
    :connect_timeout,
    :http_fn,
    :client_session_id,
    messages: []
  ]

  @type message :: %{role: String.t(), content: String.t()}

  @type t :: %__MODULE__{
          api_key: String.t() | nil,
          model: String.t(),
          max_tokens: pos_integer(),
          system: String.t() | nil,
          receive_timeout: timeout(),
          connect_timeout: timeout() | nil,
          http_fn: (map() -> {:ok, map()} | {:error, term()}),
          client_session_id: String.t(),
          messages: [message()]
        }

  @impl GenAgent.Backend
  def start_session(opts) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")
    http_fn = Keyword.get(opts, :http_fn, &default_http/1)

    session = %__MODULE__{
      api_key: api_key,
      model: Keyword.get(opts, :model, @default_model),
      max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
      system: Keyword.get(opts, :system),
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
      connect_timeout: Keyword.get(opts, :connect_timeout),
      http_fn: http_fn,
      client_session_id: generate_session_id()
    }

    {:ok, session}
  end

  @impl GenAgent.Backend
  def prompt(%__MODULE__{} = session, prompt) when is_binary(prompt) do
    session = append_message(session, "user", prompt)

    request = build_request(session)

    case session.http_fn.(request) do
      {:ok, body} ->
        events = response_to_events(body, session.client_session_id)
        {:ok, events, session}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:http_fn_raised, Exception.message(e)}}
  end

  @impl GenAgent.Backend
  def update_session(%__MODULE__{} = session, %{text: text})
      when is_binary(text) and text != "" do
    append_message(session, "assistant", text)
  end

  def update_session(%__MODULE__{} = session, _data), do: session

  @impl GenAgent.Backend
  def terminate_session(%__MODULE__{}), do: :ok

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp append_message(%__MODULE__{messages: messages} = session, role, content) do
    %{session | messages: messages ++ [%{role: role, content: content}]}
  end

  defp build_request(%__MODULE__{} = session) do
    body =
      %{
        model: session.model,
        max_tokens: session.max_tokens,
        messages: session.messages
      }
      |> maybe_put(:system, session.system)

    %{
      url: @endpoint,
      headers: [
        {"x-api-key", session.api_key || ""},
        {"anthropic-version", @anthropic_version},
        {"content-type", "application/json"}
      ],
      body: body,
      receive_timeout: session.receive_timeout,
      connect_timeout: session.connect_timeout
    }
  end

  defp response_to_events(body, client_session_id) when is_map(body) do
    text = extract_text(body)
    usage = extract_usage(body)
    stop_reason = body["stop_reason"]

    usage_events =
      case usage do
        nil -> []
        u -> [Event.new(:usage, u)]
      end

    result_data =
      %{
        text: text,
        session_id: client_session_id,
        stop_reason: stop_reason,
        model: body["model"],
        message_id: body["id"]
      }
      |> drop_nil_values()

    usage_events ++ [Event.new(:result, result_data)]
  end

  defp extract_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map_join("", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp extract_text(_), do: ""

  defp extract_usage(%{"usage" => %{} = usage}) do
    input = usage["input_tokens"]
    output = usage["output_tokens"]

    case {input, output} do
      {nil, nil} ->
        nil

      _ ->
        %{input_tokens: input, output_tokens: output}
        |> drop_nil_values()
    end
  end

  defp extract_usage(_), do: nil

  defp default_http(%{url: url, headers: headers, body: body} = request) do
    req_opts =
      [headers: headers, json: body, retry: false]
      |> maybe_put_opt(:receive_timeout, request[:receive_timeout])
      |> maybe_put_opt(:connect_options, connect_options(request[:connect_timeout]))

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp connect_options(nil), do: nil
  defp connect_options(timeout), do: [timeout: timeout]

  defp generate_session_id do
    "anthropic-" <>
      (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
