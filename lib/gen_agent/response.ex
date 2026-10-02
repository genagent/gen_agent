defmodule GenAgent.Response do
  @moduledoc """
  The result of a completed prompt turn, delivered to `c:GenAgent.handle_response/3`.

  A `Response` is built by the state machine after a terminal event
  (`:result` or `:error`) arrives from the backend. It carries:

    * `:text` -- the full assembled assistant text for the turn.
    * `:events` -- retained normalized events in arrival order. Check
      `:event_coverage` before treating this as a complete log.
    * `:terminal` -- the original terminal result event, even if compact
      retention omitted it from `:events`.
    * `:event_coverage` -- counts and the first omission reason for the
      retained log. `mode: :exact` means no event was omitted.
    * `:usage` -- token usage if the backend reported any, otherwise `nil`.
    * `:duration_ms` -- wall-clock time from prompt dispatch to terminal event.
    * `:session_id` -- the backend's session identifier, if any.
  """

  alias GenAgent.Event

  @type t :: %__MODULE__{
          text: String.t(),
          events: [Event.t()],
          terminal: Event.t() | nil,
          event_coverage: map(),
          usage: map() | nil,
          duration_ms: non_neg_integer(),
          session_id: String.t() | nil
        }

  defstruct text: "",
            events: [],
            terminal: nil,
            event_coverage: %{},
            usage: nil,
            duration_ms: 0,
            session_id: nil

  @doc """
  Build a `Response` from a completed turn's event list and wall-clock duration.

  The `events` list must include exactly one terminal event (`:result` or
  `:error`). Text is taken from the `:result` event's `:text` field if
  present, otherwise assembled from any `:text` deltas. Deltas concatenate
  directly; a text event with `message_boundary: true` starts a separate
  assistant message after a blank line. Usage is taken from the most recent
  `:usage` event, if any.
  """
  @spec from_events([Event.t()], keyword()) :: t()
  def from_events(events, opts \\ []) when is_list(events) do
    terminal = Enum.find(events, &Event.terminal?/1)
    usage = latest_usage(events)
    text_acc = Enum.reduce(events, {[], false}, &append_text/2)

    coverage = %{
      mode: :exact,
      observed_events: length(events),
      retained_events: length(events),
      omitted_events: 0,
      retained_bytes: Enum.reduce(events, 0, &(:erlang.external_size(&1) + &2)),
      first_omission: nil
    }

    from_capture(
      events,
      terminal,
      usage,
      text_acc,
      Keyword.put_new(opts, :event_coverage, coverage)
    )
  end

  @doc false
  def from_capture(events, terminal, usage, text_acc, opts) when is_list(events) do
    %__MODULE__{
      text: text_from_capture(terminal, text_acc),
      events: events,
      terminal: terminal,
      event_coverage: Keyword.fetch!(opts, :event_coverage),
      usage: usage,
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      session_id: Keyword.get(opts, :session_id)
    }
  end

  @doc false
  def text_from_capture(%Event{kind: :result, data: %{text: text}}, _acc)
      when is_binary(text),
      do: text

  def text_from_capture(_terminal, {reversed_chunks, _seen_text?}),
    do: reversed_chunks |> Enum.reverse() |> IO.iodata_to_binary()

  @doc false
  def append_text(%Event{kind: :text, data: data}, {chunks, seen_text?}) do
    text = Map.get(data, :text, "")

    chunks =
      if Map.get(data, :message_boundary, false) and seen_text? and text != "" do
        [text, "\n\n" | chunks]
      else
        [text | chunks]
      end

    {chunks, seen_text? or text != ""}
  end

  def append_text(_event, acc), do: acc

  defp latest_usage(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Event{kind: :usage, data: data} -> data
      _ -> nil
    end)
  end
end
