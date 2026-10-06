defmodule GenAgent.Backends.Claude.EventTranslator do
  @moduledoc """
  Translates `ClaudeWrapper.StreamEvent` values into `GenAgent.Event` values.

  The Claude CLI's `stream-json` output surfaces a variety of event types
  ("system", "assistant", "content_block_delta", "tool_use", "tool_result",
  "result", "error", etc). The GenAgent state machine only cares about a
  small normalized set (`:session`, `:text`, `:tool_use`, `:tool_result`, `:usage`,
  `:result`, `:error`).

  `translate/1` maps a single raw event. `translate_stream/1` additionally
  carries the model reported by session init through to the terminal event
  and deduplicates streamed text and tool calls.

  When an envelope has a `parent_tool_use_id`, normalized text and tool
  events carry it as `:parent_tool_use_id` in their data. This lets callers
  attribute interleaved subagent output to the tool invocation that started it.

  ## Translation rules

    * `"system"` init -- emits `:session` with model, permission mode, and tools.
      Other system subtypes are filtered out.
    * `"assistant"` -- ordered text and tool-use content blocks become
      `:text` and `:tool_use` events. Adjacent text blocks are joined.
    * `"user"` -- tool-result content blocks become `:tool_result` events.
    * `"stream_event"` -- wrapped text deltas become immediate `:text`
      events. A later completed assistant message contributes only text
      that was not already streamed.
    * `"content_block_delta"` -- emits a `:text` event with the delta's text.
    * `"tool_use"` -- emits a `:tool_use` event carrying the raw data map.
    * `"tool_result"` -- emits a `:tool_result` event carrying the raw data map.
    * `"result"` -- emits `:usage` when token counts are present, then
      terminal `:result` on success or `:error` when `is_error` or an
      error subtype is reported. Failure reason keeps subtype, message,
      session ID, cost and usage. Claude reports cost as
      `total_cost_usd`; we normalize it to `:cost_usd`.
      Success `:result` data also carries the raw result map under `:raw`
      (`structured_output`, `stop_reason`, `permission_denials`, ...). An
      empty or absent result omits `:text`, so `GenAgent.Response` assembles
      the turn's emitted assistant text. Failure `:message` is the non-empty
      `result`, else joined `errors`, else `error`; `:errors` and `:num_turns`
      are kept on the reason.
    * `"error"` -- emits a terminal `:error` event with `:reason` extracted
      from `data["error"]` or `data["message"]`.
    * Unknown types -- filtered out.
  """

  alias ClaudeWrapper.StreamEvent
  alias GenAgent.Event

  @doc """
  Translate a single `StreamEvent` into zero or more `GenAgent.Event` values.
  """
  @spec translate(StreamEvent.t()) :: [Event.t()]
  def translate(%StreamEvent{type: "system", data: %{"subtype" => "init"} = data}) do
    session =
      %{
        model: nonempty_string(data["model"]),
        permission_mode: data["permissionMode"],
        tools: data["tools"]
      }
      |> drop_nil_values()

    [Event.new(:session, session)]
  end

  def translate(%StreamEvent{type: "system"}), do: []

  def translate(%StreamEvent{type: "assistant", data: data}) do
    data |> content_events() |> with_parent(data)
  end

  def translate(%StreamEvent{type: "user", data: data}) do
    data |> content_events() |> Enum.filter(&(&1.kind == :tool_result)) |> with_parent(data)
  end

  def translate(%StreamEvent{type: "stream_event", data: data} = event) do
    case StreamEvent.partial_message(event) do
      {:block_delta, _index, {:text, text}} ->
        with_parent([Event.new(:text, %{text: text})], data)

      _ ->
        []
    end
  end

  def translate(%StreamEvent{
        type: "content_block_delta",
        data: %{"delta" => %{"text" => text}} = data
      })
      when is_binary(text) do
    with_parent([Event.new(:text, %{text: text})], data)
  end

  def translate(%StreamEvent{type: "content_block_delta"}), do: []

  def translate(%StreamEvent{type: "tool_use", data: data}) do
    with_parent([Event.new(:tool_use, data)], data)
  end

  def translate(%StreamEvent{type: "tool_result", data: data}) do
    with_parent([Event.new(:tool_result, data)], data)
  end

  def translate(%StreamEvent{type: "result", data: data}), do: result_events(data)

  def translate(%StreamEvent{type: "error", data: data}) do
    reason = data["error"] || data["message"] || :unknown
    [Event.new(:error, %{reason: reason, data: data})]
  end

  def translate(%StreamEvent{}), do: []

  defp result_events(data) do
    usage_event =
      case extract_usage(data) do
        nil -> []
        usage -> [Event.new(:usage, usage)]
      end

    terminal =
      if failed_result?(data), do: error_result_event(data), else: success_result_event(data)

    usage_event ++ [terminal]
  end

  defp success_result_event(data) do
    event_data = %{
      text: nonempty_string(data["result"]),
      session_id: data["session_id"],
      cost_usd: data["total_cost_usd"] || data["cost_usd"],
      duration_ms: data["duration_ms"],
      num_turns: data["num_turns"],
      is_error: data["is_error"] || false,
      raw: data
    }

    Event.new(:result, drop_nil_values(event_data))
  end

  defp error_result_event(data) do
    reason = %{
      provider: :claude,
      subtype: data["subtype"],
      message: error_message(data),
      errors: nonempty_list(data["errors"]),
      num_turns: data["num_turns"],
      session_id: data["session_id"],
      cost_usd: data["total_cost_usd"] || data["cost_usd"],
      usage: extract_usage(data)
    }

    Event.new(:error, %{reason: drop_nil_values(reason), data: data})
  end

  @doc """
  Translate an enumerable of `StreamEvent` values into an enumerable of
  `GenAgent.Event` values, flattening empty translations.
  """
  @spec translate_stream(Enumerable.t()) :: Enumerable.t()
  def translate_stream(stream) do
    initial = %{partial_text_by_parent: %{}, seen_calls: MapSet.new(), model: nil}

    Stream.transform(stream, initial, fn raw, state ->
      model = model_for(raw, state.model)
      events = translate_with_model(raw, model)

      parent = parent_tool_use_id(raw.data)
      partial_text = Map.get(state.partial_text_by_parent, parent, "")

      events =
        if raw.type == "assistant" and partial_text != "" do
          drop_streamed_text(events, partial_text)
        else
          events
        end

      {events, seen_calls} = dedupe_calls(events, state.seen_calls)

      partial_text_by_parent =
        case StreamEvent.partial_message(raw) do
          {:block_delta, _index, {:text, text}} ->
            Map.put(state.partial_text_by_parent, parent, partial_text <> text)

          _ when raw.type == "assistant" ->
            Map.delete(state.partial_text_by_parent, parent)

          _ ->
            state.partial_text_by_parent
        end

      {events,
       %{partial_text_by_parent: partial_text_by_parent, seen_calls: seen_calls, model: model}}
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp model_for(%StreamEvent{type: "system", data: %{"subtype" => "init"} = data}, previous),
    do: nonempty_string(data["model"]) || previous

  defp model_for(_raw, previous), do: previous

  defp translate_with_model(%StreamEvent{type: "result"} = raw, model) when is_binary(model),
    do: Enum.map(translate(raw), &put_terminal_model(&1, model))

  defp translate_with_model(raw, _model), do: translate(raw)

  defp put_terminal_model(%Event{kind: kind} = event, model) when kind in [:result, :error],
    do: %{event | data: Map.put(event.data, :model, model)}

  defp put_terminal_model(event, _model), do: event

  defp content_events(%{"message" => %{} = message}), do: content_events(message)

  defp content_events(%{"content" => content}) when is_list(content) do
    {events, text} =
      Enum.reduce(content, {[], ""}, fn
        %{"type" => "tool_use"} = block, {events, text} ->
          {events ++ text_event(text) ++ [Event.new(:tool_use, block)], ""}

        %{"type" => "tool_result"} = block, {events, text} ->
          {events ++ text_event(text) ++ [Event.new(:tool_result, block)], ""}

        %{"text" => part}, {events, text} when is_binary(part) ->
          {events, text <> part}

        _block, acc ->
          acc
      end)

    events ++ text_event(text)
  end

  defp content_events(%{"content" => content}) when is_binary(content),
    do: [Event.new(:text, %{text: content})]

  defp content_events(_), do: []

  defp text_event(""), do: []
  defp text_event(text), do: [Event.new(:text, %{text: text})]

  defp with_parent(events, data) do
    case parent_tool_use_id(data) do
      nil -> events
      parent -> Enum.map(events, &%{&1 | data: Map.put(&1.data, :parent_tool_use_id, parent)})
    end
  end

  defp parent_tool_use_id(%{"parent_tool_use_id" => parent})
       when is_binary(parent) and parent != "",
       do: parent

  defp parent_tool_use_id(_), do: nil

  defp error_message(data) do
    nonempty_string(data["result"]) ||
      errors_message(data["errors"]) ||
      nonempty_string(data["error"]) ||
      :unknown
  end

  defp errors_message(errors) do
    case nonempty_list(errors) do
      nil -> nil
      list -> Enum.map_join(list, "; ", &error_text/1)
    end
  end

  defp error_text(error) when is_binary(error), do: error
  defp error_text(%{"message" => message}) when is_binary(message), do: message
  defp error_text(error), do: inspect(error)

  defp nonempty_list([_ | _] = list), do: list
  defp nonempty_list(_), do: nil

  defp nonempty_string(value) when is_binary(value) and value != "", do: value
  defp nonempty_string(_), do: nil

  defp failed_result?(data) do
    subtype = data["subtype"]

    data["is_error"] == true or
      (is_binary(subtype) and (subtype == "error" or String.starts_with?(subtype, "error_")))
  end

  defp drop_streamed_text(events, partial_text) do
    {kept, _remaining} =
      Enum.reduce(events, {[], partial_text}, fn
        %Event{kind: :text, data: %{text: text}} = event, {kept, remaining}
        when remaining != "" ->
          cond do
            String.starts_with?(remaining, text) ->
              {kept, String.replace_prefix(remaining, text, "")}

            String.starts_with?(text, remaining) ->
              rest = String.replace_prefix(text, remaining, "")
              {kept ++ text_suffix_event(event, rest), ""}

            true ->
              {kept ++ [event], ""}
          end

        event, {kept, remaining} ->
          {kept ++ [event], remaining}
      end)

    kept
  end

  defp text_suffix_event(_event, ""), do: []
  defp text_suffix_event(event, text), do: [%{event | data: %{event.data | text: text}}]

  defp dedupe_calls(events, seen_calls) do
    Enum.reduce(events, {[], seen_calls}, fn event, {kept, seen} ->
      id = event.data["id"] || event.data["tool_use_id"]
      key = {event.kind, event.data[:parent_tool_use_id], id}

      if event.kind in [:tool_use, :tool_result] and is_binary(id) and MapSet.member?(seen, key) do
        {kept, seen}
      else
        {[event | kept], if(is_binary(id), do: MapSet.put(seen, key), else: seen)}
      end
    end)
    |> then(fn {kept, seen} -> {Enum.reverse(kept), seen} end)
  end

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

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
end
