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

  1. `prompt/2` includes the user's message in the API request. It returns
     that updated session only for a completed turn. A rejected terminal
     stop leaves the previous history intact.
  2. When the state machine delivers the terminal `:result` event,
     it calls `update_session/2` with the event's data, and this
     backend appends the assistant's message to `session.messages`.
     With extended thinking enabled, it replays the complete assistant
     content blocks on later turns while result events expose only answer text.
     If the response is empty, it removes the unanswered user message instead.
  3. The next `prompt/2` sends the updated history to the API.

  `end_turn` and `stop_sequence` produce a terminal `:result` event whose
  data includes `:text`, `:stop_reason`, `:stop_details` (when provided),
  `:model`, `:message_id`, and `:session_id`. `refusal` produces an `:error`
  with reason `{:refusal, stop_details}`. `max_tokens` and
  `model_context_window_exceeded` produce `:error` with reason
  `{:response_incomplete, %{stop_reason: reason, stop_details: details}}`.
  Other stop reasons are rejected as `{:unexpected_stop_reason, reason}`,
  because this text-only backend cannot complete tool or paused turns.

  This uses both sides of the `GenAgent.Backend` contract in a way
  the CLI backends don't: CLI backends leave `prompt/2`'s returned
  session unchanged and do all updates in `update_session/2`.

  ## Options

    * `:api_key` -- Anthropic API key. Defaults to `System.get_env("ANTHROPIC_API_KEY")`.
      `start_session/1` returns `{:error, :missing_api_key}` when neither
      provides a non-empty key, unless a one-arity `:http_fn` is supplied.
    * `:base_url` -- API prefix. Defaults to `"https://api.anthropic.com/v1"`;
      `/messages` is appended. HTTPS is required except for loopback HTTP.
      The configured host receives the API key and conversation content.
    * `:api_version` -- value of the `anthropic-version` header. Defaults to
      `"2023-06-01"` and must be an ISO date.
    * `:headers` -- map or list of `{name, value}` pairs with string keys and
      values. Auth, version, content type, and transport headers cannot be
      overridden; names are matched case-insensitively. Values must contain
      only printable ASCII or horizontal tabs.
    * `:request_fields` -- map of additional JSON request fields, such as
      `%{temperature: 0.2}`. For extended thinking, use a supported model with
      `max_output_tokens: 2048` and
      `request_fields: %{thinking: %{type: "enabled", budget_tokens: 1024}}`.
      Fields managed by the backend, including messages, model, token limit,
      caching, streaming, and tools, cannot be overridden.
    * `:model` -- model name. Defaults to `"claude-sonnet-4-5"`.
    * `:max_output_tokens` -- max tokens per turn. Defaults to `1024`.
      `:max_tokens` remains a deprecated alias.
    * `:system_prompt` -- system prompt (string). `:system` and
      `:instructions` remain deprecated aliases.
    * `:cache` -- opt in to automatic 5-minute prompt caching with
      top-level `cache_control: %{type: "ephemeral"}`. Defaults to `false`.
      Usage reports cache-write and cache-read tokens when present.
    * `:max_history_turns` -- retain at most this many completed user/assistant
      pairs in subsequent requests. Defaults to `:infinity`; `0` keeps no
      prior turns. Older pairs are dropped after each successful turn.
    * `:receive_timeout` -- HTTP receive timeout in milliseconds.
      Defaults to `60_000`. Long-context turns (big messages array,
      slow models) can blow through Req's 15s default, so the backend
      picks a safer default. Set higher for large debates or longer
      generations.
    * `:connect_timeout` -- HTTP connect timeout in milliseconds.
      Defaults to Req's default when unset. With a named Finch pool,
      configure this when starting Finch; the two session options cannot
      be combined.
    * `:finch` -- per-session Finch options: `:pool_timeout` (milliseconds or
      `:infinity`), `:size` and `:count` (positive integers for a dynamically
      started pool), or `:name` (an already started Finch pool). A named pool
      cannot also set `:size` or `:count`. Without this option, Req uses its
      default HTTP/1 pool of 50 connections per host with a 5-second checkout
      timeout. For example, `finch: [size: 100, pool_timeout: 20_000]` selects
      a larger pool and wait limit. Req shares dynamic pools with identical
      pool configuration across sessions; `:size` is per pool shard.
    * `:http_fn` -- a 1-arity function `(request_map) -> {:ok, response_map} | {:error, term}`
      that replaces the default `Req`-backed HTTP call. Intended for tests.

  Unknown option keys return `{:error, {:unknown_option, key}}`. Conflicting
  values for the shared name and an alias return `{:error, {:conflicting_options,
  keys}}`.
  """

  @behaviour GenAgent.Backend

  require Logger

  alias GenAgent.Backend.Error
  alias GenAgent.Event
  @compile {:no_warn_undefined, Error}

  @default_base_url "https://api.anthropic.com/v1"
  @default_api_version "2023-06-01"
  @default_model "claude-sonnet-4-5"
  @default_max_tokens 1024
  @default_receive_timeout 60_000
  @known_options [
    :api_key,
    :base_url,
    :api_version,
    :headers,
    :request_fields,
    :finch,
    :model,
    :max_tokens,
    :max_output_tokens,
    :system_prompt,
    :system,
    :instructions,
    :cache,
    :max_history_turns,
    :receive_timeout,
    :connect_timeout,
    :http_fn
  ]

  defstruct [
    :api_key,
    :base_url,
    :api_version,
    :headers,
    :request_fields,
    :finch,
    :pending_content,
    :model,
    :max_tokens,
    :system,
    :cache,
    :max_history_turns,
    :receive_timeout,
    :connect_timeout,
    :http_fn,
    :client_session_id,
    messages: []
  ]

  @type message :: %{role: String.t(), content: String.t() | [map()]}

  @type t :: %__MODULE__{
          api_key: String.t() | nil,
          base_url: String.t(),
          api_version: String.t(),
          headers: [{String.t(), String.t()}],
          request_fields: map(),
          finch: keyword() | nil,
          pending_content: [map()] | nil,
          model: String.t(),
          max_tokens: pos_integer(),
          system: String.t() | nil,
          cache: boolean(),
          max_history_turns: non_neg_integer() | :infinity,
          receive_timeout: timeout(),
          connect_timeout: timeout() | nil,
          http_fn: (map() -> {:ok, map()} | {:error, term()}),
          client_session_id: String.t(),
          messages: [message()]
        }

  @impl GenAgent.Backend
  def start_session(opts) do
    with :ok <- validate_opts(opts),
         :ok <- validate_cache(Keyword.get(opts, :cache, false)),
         :ok <- validate_max_history_turns(Keyword.get(opts, :max_history_turns, :infinity)),
         {:ok, base_url} <- normalize_base_url(Keyword.get(opts, :base_url, @default_base_url)),
         :ok <- validate_api_version(Keyword.get(opts, :api_version, @default_api_version)),
         {:ok, headers} <- normalize_headers(Keyword.get(opts, :headers, [])),
         {:ok, request_fields} <-
           normalize_request_fields(Keyword.get(opts, :request_fields, %{})),
         {:ok, finch} <- normalize_finch(Keyword.get(opts, :finch)),
         :ok <- validate_connect_timeout(Keyword.get(opts, :connect_timeout)),
         {:ok, finch} <- resolve_finch(finch, Keyword.get(opts, :connect_timeout)),
         {:ok, opts} <- normalize_opts(opts) do
      api_key =
        present(Keyword.get(opts, :api_key)) || present(System.get_env("ANTHROPIC_API_KEY"))

      # A caller-supplied :http_fn replaces the HTTP call (a stub or a proxy that
      # adds credentials), so only the default transport requires a key.
      if is_nil(api_key) and not is_function(Keyword.get(opts, :http_fn), 1) do
        {:error, :missing_api_key}
      else
        build_session(api_key, opts, base_url, headers, request_fields, finch)
      end
    end
  end

  defp validate_opts(opts) do
    if Keyword.keyword?(opts),
      do: validate_known_opts(opts),
      else: {:error, {:invalid_options, opts}}
  end

  defp validate_known_opts(opts) do
    case Enum.find(opts, fn {key, _} -> key not in @known_options end) do
      {key, _} -> {:error, {:unknown_option, key}}
      nil -> :ok
    end
  end

  defp validate_cache(value) when is_boolean(value), do: :ok
  defp validate_cache(value), do: {:error, {:invalid_option, :cache, value}}
  defp validate_max_history_turns(:infinity), do: :ok
  defp validate_max_history_turns(value) when is_integer(value) and value >= 0, do: :ok

  defp validate_max_history_turns(value),
    do: {:error, {:invalid_option, :max_history_turns, value}}

  defp normalize_base_url(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
      when scheme in ["https", "http"] and is_binary(host) and host != "" ->
        if not String.match?(value, ~r/\s/) and
             (scheme == "https" or String.downcase(host) in ["localhost", "127.0.0.1", "::1"]) do
          {:ok, String.trim_trailing(value, "/")}
        else
          {:error, {:invalid_option, :base_url, :invalid}}
        end

      _ ->
        {:error, {:invalid_option, :base_url, :invalid}}
    end
  end

  defp normalize_base_url(_value), do: {:error, {:invalid_option, :base_url, :invalid}}

  defp validate_api_version(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> :ok
      _ -> {:error, {:invalid_option, :api_version, value}}
    end
  end

  defp validate_api_version(value), do: {:error, {:invalid_option, :api_version, value}}

  @reserved_headers ~w(authorization x-api-key anthropic-version content-type host content-length transfer-encoding)
  defp normalize_headers(value) when is_map(value) or is_list(value) do
    pairs = if is_map(value), do: Map.to_list(value), else: value

    if Enum.all?(pairs, fn
         {name, header_value} when is_binary(name) and is_binary(header_value) ->
           String.match?(name, ~r/^[A-Za-z0-9-]+$/) and
             valid_header_value?(header_value) and
             String.downcase(name) not in @reserved_headers

         _ ->
           false
       end) and
         Enum.uniq_by(pairs, fn {name, _} -> String.downcase(name) end) == pairs do
      {:ok, Enum.map(pairs, fn {name, header_value} -> {String.downcase(name), header_value} end)}
    else
      {:error, {:invalid_option, :headers, :invalid}}
    end
  end

  defp normalize_headers(_value), do: {:error, {:invalid_option, :headers, :invalid}}

  defp valid_header_value?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 == 9 or &1 in 32..126))
  end

  @reserved_request_fields ~w(model max_tokens messages system cache_control stream tools tool_choice)
  defp normalize_request_fields(value) when is_map(value) do
    if valid_json_map?(value) and
         Enum.all?(Map.keys(value), &(json_key(&1) not in @reserved_request_fields)) do
      {:ok, Map.new(value, fn {key, field_value} -> {json_key(key), field_value} end)}
    else
      {:error, {:invalid_option, :request_fields, :invalid}}
    end
  end

  defp normalize_request_fields(_value),
    do: {:error, {:invalid_option, :request_fields, :invalid}}

  defp valid_json_map?(value) do
    keys = Map.keys(value)

    not is_struct(value) and Enum.all?(keys, &valid_json_key?/1) and
      length(Enum.uniq(Enum.map(keys, &json_key/1))) == length(keys) and
      Enum.all?(Map.values(value), &valid_json?/1)
  end

  defp valid_json?(value) when is_map(value), do: valid_json_map?(value)
  defp valid_json?(value) when is_list(value), do: Enum.all?(value, &valid_json?/1)

  defp valid_json?(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: true

  defp valid_json?(_value), do: false

  defp valid_json_key?(key) when is_binary(key), do: key != ""
  defp valid_json_key?(key) when is_atom(key), do: key not in [nil, true, false]
  defp valid_json_key?(_key), do: false

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key

  defp normalize_finch(nil), do: {:ok, nil}

  defp normalize_finch(options) when is_list(options) do
    valid? =
      Keyword.keyword?(options) and
        unique_finch_keys?(options) and
        Enum.all?(options, &valid_finch_option?/1) and
        not named_pool_config_conflict?(options)

    if valid?, do: {:ok, if(options == [], do: nil, else: options)}, else: invalid_finch()
  end

  defp normalize_finch(_value), do: invalid_finch()
  defp invalid_finch, do: {:error, {:invalid_option, :finch, :invalid}}

  defp unique_finch_keys?(options) do
    keys = Keyword.keys(options)
    length(keys) == length(Enum.uniq(keys))
  end

  defp valid_finch_option?({:name, name}), do: is_atom(name) and not is_nil(name)
  defp valid_finch_option?({:pool_timeout, timeout}), do: valid_timeout?(timeout)

  defp valid_finch_option?({key, size}) when key in [:size, :count],
    do: is_integer(size) and size > 0

  defp valid_finch_option?(_), do: false

  defp named_pool_config_conflict?(options) do
    Keyword.has_key?(options, :name) and
      (Keyword.has_key?(options, :size) or Keyword.has_key?(options, :count))
  end

  defp validate_connect_timeout(nil), do: :ok

  defp validate_connect_timeout(timeout) do
    if valid_timeout?(timeout),
      do: :ok,
      else: {:error, {:invalid_option, :connect_timeout, timeout}}
  end

  defp valid_timeout?(:infinity), do: true
  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout >= 0

  defp resolve_finch(nil, _timeout), do: {:ok, nil}
  defp resolve_finch(finch, nil), do: {:ok, finch}

  defp resolve_finch(finch, timeout) do
    if Keyword.has_key?(finch, :name) do
      {:error, {:conflicting_options, [:finch, :connect_timeout]}}
    else
      {:ok, Keyword.put(finch, :conn_opts, transport_opts: [timeout: timeout])}
    end
  end

  defp normalize_opts(opts) do
    case normalize_aliases(opts, :system_prompt, [:system, :instructions]) do
      {:ok, opts} -> normalize_aliases(opts, :max_output_tokens, [:max_tokens])
      error -> error
    end
  end

  defp normalize_aliases(opts, canonical, aliases) do
    present = Enum.filter([canonical | aliases], &Keyword.has_key?(opts, &1))

    case Enum.uniq(Enum.map(present, &Keyword.fetch!(opts, &1))) do
      [_first, _second | _] ->
        {:error, {:conflicting_options, present}}

      _ ->
        Enum.each(present -- [canonical], fn alias_key ->
          Logger.warning("#{inspect(alias_key)} is deprecated; use #{inspect(canonical)}")
        end)

        value = if present == [], do: nil, else: Keyword.fetch!(opts, hd(present))
        opts = Keyword.drop(opts, aliases)
        {:ok, if(present == [], do: opts, else: Keyword.put(opts, canonical, value))}
    end
  end

  defp build_session(api_key, opts, base_url, headers, request_fields, finch) do
    http_fn = Keyword.get(opts, :http_fn, &default_http/1)

    session = %__MODULE__{
      api_key: api_key,
      base_url: base_url,
      api_version: Keyword.get(opts, :api_version, @default_api_version),
      headers: headers,
      request_fields: request_fields,
      finch: finch,
      model: Keyword.get(opts, :model, @default_model),
      max_tokens: Keyword.get(opts, :max_output_tokens, @default_max_tokens),
      system: Keyword.get(opts, :system_prompt),
      cache: Keyword.get(opts, :cache, false),
      max_history_turns: Keyword.get(opts, :max_history_turns, :infinity),
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
      connect_timeout: Keyword.get(opts, :connect_timeout),
      http_fn: http_fn,
      client_session_id: generate_session_id()
    }

    {:ok, session}
  end

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_value), do: nil

  @impl GenAgent.Backend
  def prompt(%__MODULE__{} = session, prompt) when is_binary(prompt) do
    pending_session = session |> clear_pending_content() |> append_message("user", prompt)
    request = build_request(pending_session)

    case session.http_fn.(request) do
      {:ok, body} ->
        handle_http_body(body, session, pending_session)

      {:error, reason} ->
        {:error, backend_error(reason)}
    end
  rescue
    e -> {:error, backend_error({:http_fn_raised, Exception.message(e)})}
  end

  defp handle_http_body(body, session, pending_session) do
    with {:ok, events} <- parse_response(body, session.client_session_id) do
      next_session =
        if List.last(events).kind == :error do
          session
        else
          maybe_preserve_content(pending_session, body)
        end

      {:ok, events, next_session}
    end
  end

  defp maybe_preserve_content(%__MODULE__{request_fields: %{"thinking" => _}} = session, %{
         "content" => content
       })
       when is_list(content) do
    if Enum.all?(content, &is_map/1),
      do: %{session | pending_content: content},
      else: session
  end

  defp maybe_preserve_content(session, _body), do: session

  defp parse_response(body, client_session_id) when is_map(body) do
    {:ok, response_to_events(body, client_session_id)}
  rescue
    e -> {:error, invalid_response(body, Exception.message(e))}
  end

  defp parse_response(body, _client_session_id),
    do: {:error, invalid_response(body, "Expected a map response body")}

  defp invalid_response(body, message) do
    if Code.ensure_loaded?(Error),
      do: Error.new(:anthropic, :invalid_response, body, message: message),
      else: {:invalid_response, body}
  end

  defp backend_error(reason) do
    if Code.ensure_loaded?(Error),
      do: Error.normalize(:anthropic, reason),
      else: reason
  end

  @impl GenAgent.Backend
  # Text that is empty or only whitespace is not a usable assistant turn:
  # remove the unanswered user message so history keeps alternating.
  def update_session(%__MODULE__{} = session, %{text: text}) when is_binary(text) do
    if String.trim(text) == "",
      do: session |> drop_last_user_message() |> clear_pending_content(),
      else:
        session
        |> append_message("assistant", session.pending_content || text)
        |> clear_pending_content()
        |> trim_history()
  end

  def update_session(%__MODULE__{} = session, _data), do: clear_pending_content(session)

  if {:reset_session, 1} in GenAgent.Backend.behaviour_info(:callbacks),
    do: @impl(GenAgent.Backend)

  def reset_session(%__MODULE__{} = session),
    do: {:ok, %{session | messages: [], pending_content: nil}}

  @impl GenAgent.Backend
  def terminate_session(%__MODULE__{}), do: :ok

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp append_message(%__MODULE__{messages: messages} = session, role, content) do
    %{session | messages: messages ++ [%{role: role, content: content}]}
  end

  defp clear_pending_content(session), do: %{session | pending_content: nil}

  defp drop_last_user_message(%__MODULE__{messages: messages} = session) do
    case Enum.reverse(messages) do
      [%{role: "user"} | rest] -> %{session | messages: Enum.reverse(rest)}
      _ -> session
    end
  end

  defp trim_history(%__MODULE__{max_history_turns: :infinity} = session), do: session

  defp trim_history(%__MODULE__{max_history_turns: turns, messages: messages} = session) do
    %{session | messages: Enum.take(messages, -2 * turns)}
  end

  defp build_request(%__MODULE__{} = session) do
    body =
      %{
        model: session.model,
        max_tokens: session.max_tokens,
        messages: session.messages
      }
      |> maybe_put(:system, session.system)
      |> maybe_cache(session.cache)
      |> Map.merge(session.request_fields)

    %{
      url: session.base_url <> "/messages",
      headers:
        [
          {"x-api-key", session.api_key || ""},
          {"anthropic-version", session.api_version},
          {"content-type", "application/json"}
        ] ++ session.headers,
      body: body,
      receive_timeout: session.receive_timeout,
      connect_timeout: session.connect_timeout,
      finch: session.finch
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
        stop_details: body["stop_details"],
        model: body["model"],
        message_id: body["id"]
      }
      |> drop_nil_values()

    terminal_event =
      case stop_error(stop_reason, body["stop_details"]) do
        nil -> Event.new(:result, result_data)
        reason -> Event.new(:error, Map.put(result_data, :reason, backend_error(reason)))
      end

    usage_events ++ [terminal_event]
  end

  defp stop_error(reason, _details) when reason in ["end_turn", "stop_sequence"], do: nil
  defp stop_error("refusal", details), do: {:refusal, details}

  defp stop_error(reason, details)
       when reason in ["max_tokens", "model_context_window_exceeded"],
       do: {:response_incomplete, %{stop_reason: reason, stop_details: details}}

  defp stop_error(reason, _details), do: {:unexpected_stop_reason, reason}

  defp extract_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map_join("", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp extract_text(_), do: ""

  defp extract_usage(%{"usage" => %{} = usage}) do
    values =
      %{
        input_tokens: usage["input_tokens"],
        output_tokens: usage["output_tokens"],
        cache_creation_input_tokens: usage["cache_creation_input_tokens"],
        cache_read_input_tokens: usage["cache_read_input_tokens"]
      }
      |> drop_nil_values()

    if map_size(values) == 0, do: nil, else: values
  end

  defp extract_usage(_), do: nil

  defp maybe_cache(body, true), do: Map.put(body, :cache_control, %{type: "ephemeral"})
  defp maybe_cache(body, false), do: body

  defp default_http(%{url: url, headers: headers, body: body} = request) do
    req_opts =
      [headers: headers, json: body, retry: false, redirect: false]
      |> maybe_put_opt(:receive_timeout, request[:receive_timeout])
      |> maybe_put_opt(:finch, request[:finch])
      |> maybe_put_connect_timeout(request[:finch], request[:connect_timeout])

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body, headers: headers} = response} ->
        if Code.ensure_loaded?(Error) do
          {:error, Error.http(:anthropic, status, body, headers, response)}
        else
          {:error, {:http_error, status, body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_connect_timeout(opts, _finch, nil), do: opts
  defp maybe_put_connect_timeout(opts, finch, _timeout) when not is_nil(finch), do: opts

  defp maybe_put_connect_timeout(opts, nil, timeout) do
    opts |> Keyword.put(:finch, nil) |> Keyword.put(:connect_options, timeout: timeout)
  end

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

defimpl Inspect, for: GenAgent.Backends.Anthropic do
  import Inspect.Algebra

  def inspect(session, opts) do
    fields = [
      model: session.model,
      max_tokens: session.max_tokens,
      receive_timeout: session.receive_timeout,
      connect_timeout: session.connect_timeout,
      client_session_id: session.client_session_id,
      messages: if(is_list(session.messages), do: length(session.messages), else: :unknown)
    ]

    docs =
      Enum.map(fields, fn {key, value} ->
        concat([Atom.to_string(key), ": ", to_doc(value, opts)])
      end)

    concat(["#GenAgent.Backends.Anthropic<", concat(Enum.intersperse(docs, ", ")), ">"])
  end
end
