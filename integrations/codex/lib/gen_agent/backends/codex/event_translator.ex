defmodule GenAgent.Backends.Codex.EventTranslator do
  @moduledoc """
  Translates `CodexWrapper.JsonLineEvent` values from one Codex turn
  into `GenAgent.Event` values. `translate_stream/1` preserves arrival
  order and remembers the `thread_id` reported by `thread.started`,
  adding it to the terminal `:result` as `session_id`.

  ## Event mapping

    * `thread.started` -- captured for `thread_id`, no GenAgent event
      emitted directly. The captured id is threaded into the final
      `:result` event as `session_id`.
    * `turn.started` -- filtered.
    * `item.completed` with `item.type == "agent_message"` -- emits a
      `:text` event with the item's text content and a message boundary.
    * `item.completed` with `item.type == "tool_call"` or similar --
      emits a `:tool_use` event. (Exact shape depends on what Codex
      surfaces; we pass the raw item through in `:data`.)
    * `item.completed` with `mcp_tool_call`, `command_execution`, or
      `file_change` emits `:tool_use` and `:tool_result` with the full
      item in both events. This retains IDs, arguments, outputs and
      completion status. `item.started`/`item.updated` are ignored so
      each action is counted once.
    * `turn.completed` -- emits a `:usage` event (if token counts are
      present) followed by a terminal `:result` event carrying the
      captured `thread_id` as `session_id`.
    * `error` -- remembers the latest notification without ending the turn.
      If the stream ends before a turn outcome, emits a terminal `:error`.
    * `turn.failed` -- emits a terminal `:error` event, using the latest
      notification as a fallback when the failure has no reason.
    * Unknown event types -- filtered.

  If a turn's event list contains no `turn.completed`, `turn.failed`, or
  error notification, the translator emits nothing terminal. The state machine's
  `no_terminal_event` guard will then deliver `{:error, :no_terminal_event}`
  to the caller.
  """

  alias CodexWrapper.JsonLineEvent
  alias GenAgent.Event

  @doc """
  Translate a full turn's worth of events.
  """
  @spec translate([JsonLineEvent.t()]) :: [Event.t()]
  def translate(events) when is_list(events) do
    events |> translate_stream() |> Enum.to_list()
  end

  @doc "Translate events as they arrive while retaining the thread ID and latest error notification."
  @spec translate_stream(Enumerable.t()) :: Enumerable.t()
  def translate_stream(events) do
    Stream.transform(
      events,
      fn -> %{thread_id: nil, last_error: nil, terminal?: false} end,
      &translate_event/2,
      fn
        %{terminal?: false, last_error: %{reason: reason, data: data}} = state ->
          {[Event.new(:error, %{reason: reason, data: data})], state}

        state ->
          {[], state}
      end,
      fn _ -> :ok end
    )
  end

  defp translate_event(
         %JsonLineEvent{event_type: "thread.started", data: %{"thread_id" => id}},
         state
       ) do
    {[], %{state | thread_id: id}}
  end

  defp translate_event(%JsonLineEvent{event_type: "error", data: data}, state) do
    {[], %{state | last_error: %{reason: notification_reason(data), data: data}}}
  end

  defp translate_event(%JsonLineEvent{event_type: "turn.failed", data: data}, state) do
    fallback = if state.last_error, do: state.last_error.reason, else: :unknown
    reason = failure_reason(data, fallback)
    {[Event.new(:error, %{reason: reason, data: data})], %{state | terminal?: true}}
  end

  defp translate_event(%JsonLineEvent{event_type: "turn.completed"} = event, state) do
    {translate_one(event, state.thread_id), %{state | terminal?: true}}
  end

  defp translate_event(event, state), do: {translate_one(event, state.thread_id), state}

  # ---------------------------------------------------------------------------
  # Per-event translation
  # ---------------------------------------------------------------------------

  defp translate_one(%JsonLineEvent{event_type: "thread.started"}, _thread_id), do: []
  defp translate_one(%JsonLineEvent{event_type: "turn.started"}, _thread_id), do: []

  defp translate_one(
         %JsonLineEvent{event_type: "item.completed", data: %{"item" => item}},
         _thread_id
       )
       when is_map(item) do
    translate_item(item)
  end

  defp translate_one(
         %JsonLineEvent{event_type: "turn.completed", data: data},
         thread_id
       ) do
    usage_events =
      case extract_usage(data) do
        nil -> []
        usage -> [Event.new(:usage, usage)]
      end

    # Intentionally omit :text. Codex's terminal event carries no
    # assembled text -- the agent's response arrives as earlier
    # `item.completed` -> `:text` events. `GenAgent.Response.from_events`
    # assembles :text events when the :result event has no :text key.
    # Distinct completed messages carry a boundary marker so their text
    # remains readable without changing streaming-delta semantics.
    result_data =
      %{session_id: thread_id}
      |> drop_nil_values()

    usage_events ++ [Event.new(:result, result_data)]
  end

  defp translate_one(%JsonLineEvent{}, _thread_id), do: []

  # ---------------------------------------------------------------------------
  # item.completed -- per item.type
  # ---------------------------------------------------------------------------

  defp translate_item(%{"type" => "agent_message", "text" => text}) when is_binary(text) do
    [Event.new(:text, %{text: text, message_boundary: true})]
  end

  defp translate_item(%{"type" => "tool_call"} = item) do
    [Event.new(:tool_use, item)]
  end

  defp translate_item(%{"type" => "tool_result"} = item) do
    [Event.new(:tool_result, item)]
  end

  defp translate_item(%{"type" => type} = item)
       when type in ["mcp_tool_call", "command_execution", "file_change"] do
    [Event.new(:tool_use, item), Event.new(:tool_result, item)]
  end

  defp translate_item(_), do: []

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp notification_reason(data) do
    case failure_reason(data) do
      %{"message" => message} when is_binary(message) and message != "" -> message
      reason -> reason
    end
  end

  defp failure_reason(data, fallback \\ :unknown)

  defp failure_reason(%{"error" => error} = data, fallback)
       when is_map(error) and map_size(error) == 0,
       do: data["message"] || fallback

  defp failure_reason(data, fallback), do: data["error"] || data["message"] || fallback

  defp extract_usage(%{"usage" => %{} = usage}) do
    input = usage["input_tokens"]
    output = usage["output_tokens"]
    cached = usage["cached_input_tokens"]

    case {input, output} do
      {nil, nil} ->
        nil

      _ ->
        %{
          input_tokens: input,
          output_tokens: output,
          cached_input_tokens: cached
        }
        |> drop_nil_values()
    end
  end

  defp extract_usage(_), do: nil

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
