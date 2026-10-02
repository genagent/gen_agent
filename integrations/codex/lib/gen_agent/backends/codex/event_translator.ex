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
      captured `thread_id` as `session_id` and the raw completed usage as
      `usage_total`.
    * `error` -- remembers the latest notification without ending the turn.
      If the stream ends before a turn outcome, emits a terminal `:error`.
    * `turn.failed` -- emits a terminal `:error` event, using the latest
      notification as a fallback when the failure has no reason.
    * Unknown event types -- filtered.

  If a turn's event list contains no `turn.completed`, `turn.failed`, or
  error notification, the translator emits nothing terminal. The state machine's
  `no_terminal_event` guard will then deliver `{:error, :no_terminal_event}`
  to the caller.

  ## Usage

  Codex fills `turn.completed.usage` from the thread's running total, so
  a resumed turn reports the whole thread so far. The translator takes
  the previous completed total as the `:usage_baseline` option and emits
  the per-field increase as `:usage`. The raw total of the completed turn
  is returned in the `:result` data as `usage_total` so the backend can
  use it as the next baseline.

  The five counters are `input_tokens`, `output_tokens`,
  `cached_input_tokens`, `cache_write_input_tokens` and
  `reasoning_output_tokens`. A delta is omitted for a counter when:

    * the baseline has no value for it (for example an externally
      resumed thread whose earlier total is unknown, or a previous turn
      that did not report it), or
    * the counter decreased, which means the thread total was reset and
      the difference is not this turn's usage.

  Omitted deltas are never replaced with zeros or with the raw total.
  When no delta remains, no `:usage` event is emitted. The default
  baseline is all zeros, which treats the stream as the first turn of a
  thread.
  """

  alias CodexWrapper.JsonLineEvent
  alias GenAgent.Event

  @usage_fields [
    :input_tokens,
    :output_tokens,
    :cached_input_tokens,
    :cache_write_input_tokens,
    :reasoning_output_tokens
  ]

  @typedoc "Raw completed usage totals keyed by counter name; absent keys are unknown."
  @type usage_total :: %{optional(atom()) => non_neg_integer()}

  @doc "Baseline for the first turn of a new thread: every counter is zero."
  @spec zero_usage_total() :: usage_total()
  def zero_usage_total, do: Map.new(@usage_fields, &{&1, 0})

  @doc """
  Translate a full turn's worth of events.
  """
  @spec translate([JsonLineEvent.t()], keyword()) :: [Event.t()]
  def translate(events, opts \\ []) when is_list(events) do
    events |> translate_stream(opts) |> Enum.to_list()
  end

  @doc """
  Translate events as they arrive while retaining the thread ID and latest error notification.

  Options: `:usage_baseline` -- the previous completed `t:usage_total/0`
  (default: all zeros).
  """
  @spec translate_stream(Enumerable.t(), keyword()) :: Enumerable.t()
  def translate_stream(events, opts \\ []) do
    baseline = Keyword.get(opts, :usage_baseline, zero_usage_total())

    Stream.transform(
      events,
      fn -> %{thread_id: nil, last_error: nil, terminal?: false, baseline: baseline} end,
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
    {translate_one(event, state), %{state | terminal?: true}}
  end

  defp translate_event(event, state), do: {translate_one(event, state), state}

  # ---------------------------------------------------------------------------
  # Per-event translation
  # ---------------------------------------------------------------------------

  defp translate_one(%JsonLineEvent{event_type: "thread.started"}, _state), do: []
  defp translate_one(%JsonLineEvent{event_type: "turn.started"}, _state), do: []

  defp translate_one(
         %JsonLineEvent{event_type: "item.completed", data: %{"item" => item}},
         _state
       )
       when is_map(item) do
    translate_item(item)
  end

  defp translate_one(
         %JsonLineEvent{event_type: "turn.completed", data: data},
         state
       ) do
    total = extract_total(data)

    usage_events =
      case usage_delta(total, state.baseline) do
        delta when map_size(delta) == 0 -> []
        delta -> [Event.new(:usage, delta)]
      end

    # Intentionally omit :text. Codex's terminal event carries no
    # assembled text -- the agent's response arrives as earlier
    # `item.completed` -> `:text` events. `GenAgent.Response.from_events`
    # assembles :text events when the :result event has no :text key.
    # Distinct completed messages carry a boundary marker so their text
    # remains readable without changing streaming-delta semantics.
    result_data =
      %{session_id: state.thread_id, usage_total: total}
      |> drop_nil_values()

    usage_events ++ [Event.new(:result, result_data)]
  end

  defp translate_one(%JsonLineEvent{}, _state), do: []

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

  # Raw completed total: only well-formed non-negative integer counters.
  defp extract_total(%{"usage" => %{} = usage}) do
    for field <- @usage_fields,
        value = usage[Atom.to_string(field)],
        is_integer(value) and value >= 0,
        into: %{},
        do: {field, value}
  end

  defp extract_total(_), do: %{}

  defp usage_delta(total, baseline) do
    for {field, value} <- total,
        prev = Map.get(baseline, field),
        is_integer(prev) and value >= prev,
        into: %{},
        do: {field, value - prev}
  end

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
