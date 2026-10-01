defmodule GenAgent.Backends.OpenAI do
  @moduledoc """
  `GenAgent.Backend` implementation backed by the OpenAI Responses API
  (`POST /v1/responses`).

  Unlike the CLI-backed backends (`GenAgent.Backends.Claude`,
  `GenAgent.Backends.Codex`), this backend talks directly to an HTTP
  API. Unlike `GenAgent.Backends.Anthropic`, it does **not** resend
  the full conversation history on every turn -- OpenAI holds
  conversation state server-side, and the backend threads one
  `previous_response_id` value across turns.

  This makes the OpenAI backend structurally simpler than the
  Anthropic one: there's no messages array to manage, and
  multi-turn just works as long as `update_session/2` runs after
  each terminal `:result` event.

  ## How the two halves of a turn land in the session

  1. `prompt/2` POSTs `{input: [{role: "user", content: prompt}],
     previous_response_id: session.previous_response_id, instructions,
     store: true}`, parses the response, and returns `{:ok, events,
     session}`. The session itself is **not** mutated here -- the
     request body is built from `session.previous_response_id` as it
     stood entering the turn.
  2. When the state machine delivers the terminal `:result` event,
     it calls `update_session/2` with the event's data. The event's
     `:response_id` becomes `session.previous_response_id` for the
     next turn.
  3. The next `prompt/2` uses the new `previous_response_id` and
     OpenAI replays all prior context on the server side.

  ## Instructions do not persist across previous_response_id chains

  OpenAI's documentation is explicit: "the instructions used on
  previous turns will not be present in the context." This backend
  therefore resends `:instructions` on **every** request when the
  option is set. The per-request token cost is tiny, but the
  invariant is load-bearing -- a future optimization that tries to
  "save tokens by only sending instructions once" would silently
  break system-prompt behavior on every turn after the first.

  ## Reasoning models

  For reasoning models (o1/o3/o4/gpt-5), the response body contains
  `output[]` items with `type: "reasoning"` alongside the
  `type: "message"` item. This backend ignores the reasoning items
  entirely when extracting text -- it walks `output[]` looking for
  the message item -- but surfaces `reasoning_tokens` (from
  `usage.output_tokens_details.reasoning_tokens`) in the `:usage`
  event when present, so patterns can reason about cost.

  Set `:reasoning_effort` to `:low`, `:medium`, or `:high` to
  request a specific effort level; leave it `nil` for the model
  default.

  ## Options

    * `:api_key` -- OpenAI API key. Defaults to `System.get_env("OPENAI_API_KEY")`.
    * `:model` -- model name. Defaults to `"gpt-5"`.
    * `:instructions` -- system prompt (string). Resent every turn; see note above.
    * `:reasoning_effort` -- one of `:low | :medium | :high | nil`.
      When set, adds `{"reasoning": {"effort": ...}}` to each request.
    * `:max_output_tokens` -- cap on output tokens per turn. Defaults to `nil` (model default).
    * `:receive_timeout` -- HTTP receive timeout in milliseconds. Defaults to
      `60_000`; increase it for long-context or slow reasoning turns.
    * `:connect_timeout` -- HTTP connect timeout in milliseconds. Defaults to
      Req's default when unset.
    * `:http_fn` -- a 1-arity function `(request_map) -> {:ok, response_map} | {:error, term}`
      that replaces the default `Req`-backed HTTP call. Intended for tests.
  """

  @behaviour GenAgent.Backend

  alias GenAgent.Event

  @endpoint "https://api.openai.com/v1/responses"
  @default_model "gpt-5"
  @default_receive_timeout 60_000

  defstruct [
    :api_key,
    :model,
    :instructions,
    :reasoning_effort,
    :max_output_tokens,
    :receive_timeout,
    :connect_timeout,
    :http_fn,
    :client_session_id,
    :previous_response_id
  ]

  @type reasoning_effort :: :low | :medium | :high | nil

  @type t :: %__MODULE__{
          api_key: String.t() | nil,
          model: String.t(),
          instructions: String.t() | nil,
          reasoning_effort: reasoning_effort(),
          max_output_tokens: pos_integer() | nil,
          receive_timeout: timeout(),
          connect_timeout: timeout() | nil,
          http_fn: (map() -> {:ok, map()} | {:error, term()}),
          client_session_id: String.t(),
          previous_response_id: String.t() | nil
        }

  @impl GenAgent.Backend
  def start_session(opts) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")
    http_fn = Keyword.get(opts, :http_fn, &default_http/1)

    session = %__MODULE__{
      api_key: api_key,
      model: Keyword.get(opts, :model, @default_model),
      instructions: Keyword.get(opts, :instructions),
      reasoning_effort: Keyword.get(opts, :reasoning_effort),
      max_output_tokens: Keyword.get(opts, :max_output_tokens),
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
      connect_timeout: Keyword.get(opts, :connect_timeout),
      http_fn: http_fn,
      client_session_id: generate_session_id(),
      previous_response_id: nil
    }

    {:ok, session}
  end

  @impl GenAgent.Backend
  def prompt(%__MODULE__{} = session, prompt) when is_binary(prompt) do
    request = build_request(session, prompt)

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
  def update_session(%__MODULE__{} = session, %{response_id: response_id})
      when is_binary(response_id) and response_id != "" do
    %{session | previous_response_id: response_id}
  end

  def update_session(%__MODULE__{} = session, _data), do: session

  @impl GenAgent.Backend
  def terminate_session(%__MODULE__{}), do: :ok

  # ---------------------------------------------------------------------------
  # Request building
  # ---------------------------------------------------------------------------

  defp build_request(%__MODULE__{} = session, prompt) do
    body =
      %{
        model: session.model,
        input: [%{role: "user", content: prompt}],
        store: true
      }
      |> maybe_put(:instructions, session.instructions)
      |> maybe_put(:previous_response_id, session.previous_response_id)
      |> maybe_put(:max_output_tokens, session.max_output_tokens)
      |> maybe_put_reasoning(session.reasoning_effort)

    %{
      url: @endpoint,
      headers: [
        {"authorization", "Bearer #{session.api_key || ""}"},
        {"content-type", "application/json"}
      ],
      body: body,
      receive_timeout: session.receive_timeout,
      connect_timeout: session.connect_timeout
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_reasoning(map, nil), do: map
  defp maybe_put_reasoning(map, effort), do: Map.put(map, :reasoning, %{effort: effort})

  # ---------------------------------------------------------------------------
  # Response parsing
  # ---------------------------------------------------------------------------

  defp response_to_events(body, client_session_id) when is_map(body) do
    text = extract_text(body)
    usage = extract_usage(body)
    response_id = body["id"]
    status = body["status"]

    usage_events =
      case usage do
        nil -> []
        u -> [Event.new(:usage, u)]
      end

    result_data =
      %{
        text: text,
        session_id: client_session_id,
        response_id: response_id,
        stop_reason: status,
        model: body["model"]
      }
      |> drop_nil_values()

    usage_events ++ [Event.new(:result, result_data)]
  end

  defp extract_text(%{"output" => output}) when is_list(output) do
    output
    |> Enum.filter(&match?(%{"type" => "message"}, &1))
    |> Enum.flat_map(fn message -> Map.get(message, "content", []) end)
    |> Enum.map_join("", fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp extract_text(_), do: ""

  defp extract_usage(%{"usage" => %{} = usage}) do
    input = usage["input_tokens"]
    output = usage["output_tokens"]
    total = usage["total_tokens"]
    reasoning = get_in(usage, ["output_tokens_details", "reasoning_tokens"])

    case {input, output, total, reasoning} do
      {nil, nil, nil, nil} ->
        nil

      _ ->
        %{
          input_tokens: input,
          output_tokens: output,
          total_tokens: total,
          reasoning_tokens: reasoning
        }
        |> drop_nil_values()
    end
  end

  defp extract_usage(_), do: nil

  # ---------------------------------------------------------------------------
  # HTTP + helpers
  # ---------------------------------------------------------------------------

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
    "openai-" <>
      (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
