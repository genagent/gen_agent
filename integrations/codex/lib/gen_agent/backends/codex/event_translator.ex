defmodule GenAgent.Backends.Codex.EventTranslator do
  @moduledoc """
  Translates `CodexWrapper.JsonLineEvent` values from one Codex turn
  into `GenAgent.Event` values. `translate_stream/1` preserves arrival
  order and remembers the `thread_id` reported by `thread.started`,
  adding it to the terminal `:result` as `session_id`.

  ## Event mapping

    * `thread.started` -- captured for `thread_id` and model if present;
      no GenAgent event emitted directly. The captured id is threaded
      into the final `:result` event as `session_id`.
    * `turn.started` -- captures model if present; otherwise filtered.
    * `item.completed` with `item.type == "agent_message"` -- emits a
      `:text` event with the item's text content and a message boundary.
    * `item.started` for an action emits a small `:tool_use` marker with
      its ID and type (plus MCP/collab tool names when present).
      `item.completed` emits one `:tool_result` containing the full item.
      File changes may have only a completion event. Updates to actions
      are ignored so accumulated output is captured once.
    * Completed `reasoning`, `todo_list`, and non-fatal `error` items emit
      `:tool_result` activity records with their item type in `:data`.
      They do not become assistant response text or terminal errors.
    * `turn.completed` -- emits a `:usage` event (if token counts are
      present) followed by a terminal `:result` event carrying the
      captured `thread_id` as `session_id` and the raw completed usage as
      `usage_total`. The model is reported when present in JSONL, otherwise
      falls back to an explicitly requested model with `model_source:
      :requested`. With `response_text: :final_message` the `:result`
      also carries the last completed `agent_message` text as `:text`
      (see below).
    * `error` -- remembers the latest notification without ending the turn.
      If the stream ends before a turn outcome, emits a terminal `:error`.
    * `turn.failed` -- emits a terminal `:error` event, using the latest
      notification as a fallback when the failure has no reason.
    * `CodexWrapper.StreamError` -- emits a terminal `:error` with the
      typed `{:idle_timeout, ms}` or `{:timeout, ms}` reason.
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

  ## Response text

  The `:response_text` option selects what the terminal `:result` says
  about the turn's text. `GenAgent.Response` uses a binary `:text` on
  the `:result` event as `Response.text`; without it, it joins the turn's
  `:text` events.

    * `:all_messages` (default) -- the `:result` carries no `:text`, so
      `Response.text` joins every completed `agent_message` with a blank
      line.
    * `:final_message` -- the `:result` carries the text of the last
      completed `agent_message` seen in this invocation as `:text`.
      An empty last message gives `""`, and so does a turn with no
      `agent_message`. The `:text` events are emitted either way, so
      streaming callers still see every message.

  The last message is tracked per `translate_stream/2` invocation, which
  is one turn. `turn.failed` and error terminals never carry `:text`.
  """

  alias CodexWrapper.JsonLineEvent
  alias GenAgent.Backend.Error
  alias GenAgent.Event
  @compile {:no_warn_undefined, Error}

  @usage_fields [
    :input_tokens,
    :output_tokens,
    :cached_input_tokens,
    :cache_write_input_tokens,
    :reasoning_output_tokens
  ]

  # Codex exec JSONL's ThreadItemDetails action variants. The wrapper parses
  # raw JSON maps and does not impose its own item schema.
  @action_item_types [
    "command_execution",
    "file_change",
    "mcp_tool_call",
    "collab_tool_call",
    "web_search"
  ]

  @activity_item_types ["reasoning", "todo_list", "error"]

  @typedoc "Raw completed usage totals keyed by counter name; absent keys are unknown."
  @type usage_total :: %{optional(atom()) => non_neg_integer()}

  @typedoc "What the terminal `:result` reports as the turn's text."
  @type response_text :: :all_messages | :final_message

  @doc "Baseline for the first turn of a new thread: every counter is zero."
  @spec zero_usage_total() :: usage_total()
  def zero_usage_total, do: Map.new(@usage_fields, &{&1, 0})

  @doc """
  Translate a full turn's worth of events.
  """
  @spec translate([JsonLineEvent.t() | CodexWrapper.StreamError.t()], keyword()) :: [Event.t()]
  def translate(events, opts \\ []) when is_list(events) do
    events |> translate_stream(opts) |> Enum.to_list()
  end

  @doc """
  Translate events as they arrive while retaining the thread ID and latest error notification.

  Options:

    * `:usage_baseline` -- the previous completed `t:usage_total/0`
      (default: all zeros).
    * `:response_text` -- `t:response_text/0` (default: `:all_messages`).
    * `:requested_model` -- model passed to the CLI; used only when JSONL
      does not report a model.
  """
  @spec translate_stream(Enumerable.t(), keyword()) :: Enumerable.t()
  def translate_stream(events, opts \\ []) do
    baseline = Keyword.get(opts, :usage_baseline, zero_usage_total())
    response_text = Keyword.get(opts, :response_text, :all_messages)
    requested_model = Keyword.get(opts, :requested_model)

    Stream.transform(
      events,
      fn ->
        %{
          thread_id: nil,
          last_error: nil,
          terminal?: false,
          baseline: baseline,
          response_text: response_text,
          last_message: nil,
          model: nil,
          requested_model: requested_model
        }
      end,
      &translate_event/2,
      fn
        %{terminal?: false, last_error: %{reason: reason, data: data}} = state ->
          {[Event.new(:error, %{reason: backend_error(reason), data: data})], state}

        state ->
          {[], state}
      end,
      fn _ -> :ok end
    )
  end

  defp translate_event(
         %JsonLineEvent{event_type: "thread.started", data: %{"thread_id" => id} = data},
         state
       ) do
    {[], %{state | thread_id: id, model: reported_model(data) || state.model}}
  end

  defp translate_event(%JsonLineEvent{event_type: "turn.started", data: data}, state) do
    {[], %{state | model: reported_model(data) || state.model}}
  end

  defp translate_event(%JsonLineEvent{event_type: "error", data: data}, state) do
    {[], %{state | last_error: %{reason: notification_reason(data), data: data}}}
  end

  defp translate_event(%JsonLineEvent{event_type: "turn.failed", data: data}, state) do
    fallback = if state.last_error, do: state.last_error.reason, else: :unknown
    reason = failure_reason(data, fallback)

    {[Event.new(:error, %{reason: backend_error(reason), data: data})],
     %{state | terminal?: true}}
  end

  defp translate_event(%JsonLineEvent{event_type: "turn.completed"} = event, state) do
    {translate_one(event, state), %{state | terminal?: true}}
  end

  defp translate_event(%CodexWrapper.StreamError{reason: reason}, state) do
    {[Event.new(:error, %{reason: backend_error(reason)})], %{state | terminal?: true}}
  end

  defp translate_event(
         %JsonLineEvent{
           event_type: "item.completed",
           data: %{"item" => %{"type" => "agent_message", "text" => text} = item}
         },
         state
       )
       when is_binary(text) do
    {translate_item(item), %{state | last_message: text}}
  end

  defp translate_event(event, state), do: {translate_one(event, state), state}

  # ---------------------------------------------------------------------------
  # Per-event translation
  # ---------------------------------------------------------------------------

  defp translate_one(%JsonLineEvent{event_type: "thread.started"}, _state), do: []
  defp translate_one(%JsonLineEvent{event_type: "turn.started"}, _state), do: []

  defp translate_one(
         %JsonLineEvent{event_type: "item.started", data: %{"item" => %{"type" => type} = item}},
         _state
       )
       when type in @action_item_types do
    [Event.new(:tool_use, Map.take(item, ["id", "type", "server", "tool"]))]
  end

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

    # Codex's terminal event carries no assembled text -- the agent's
    # response arrives as earlier `item.completed` -> `:text` events.
    # By default :text is omitted and `GenAgent.Response.from_events`
    # assembles the :text events, each carrying a boundary marker so
    # distinct messages remain readable. Under :final_message the last
    # tracked agent_message is reported as :text instead.
    result_data =
      %{
        session_id: state.thread_id,
        usage_total: total,
        model: reported_model(data) || state.model || state.requested_model,
        model_source:
          cond do
            reported_model(data) || state.model -> :reported
            state.requested_model -> :requested
            true -> nil
          end
      }
      |> put_response_text(state)
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

  defp translate_item(%{"type" => type} = item)
       when type in @action_item_types or type in @activity_item_types do
    [Event.new(:tool_result, item)]
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

  defp backend_error(reason) do
    if Code.ensure_loaded?(Error),
      do: Error.normalize(:codex, reason),
      else: reason
  end

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

  defp put_response_text(data, %{response_text: :final_message, last_message: last}),
    do: Map.put(data, :text, last || "")

  defp put_response_text(data, _state), do: data

  defp reported_model(%{"model" => model}) when is_binary(model) and model != "", do: model
  defp reported_model(_), do: nil

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
