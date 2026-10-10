defmodule GenAgent.Response do
  @moduledoc """
  The result of a completed prompt turn, delivered to `c:GenAgent.handle_response/3`.

  During an agent turn, a `Response` is built after the backend's terminal
  `:result` event and delivered to `c:GenAgent.handle_response/3`. A terminal
  `:error` event or a synchronous backend error instead dispatches its reason
  to `c:GenAgent.handle_error/3`; no `Response` is delivered on that path.
  `from_events/2` can also build a response outside the agent lifecycle,
  including from an event list containing an `:error` event. It carries:

    * `:prompt` -- the prompt actually sent to the backend after `pre_turn/2`
      rewriting. It is `nil` for responses built outside an agent turn.
    * `:text` -- the full assembled assistant text for the turn.
    * `:final_message` -- the terminal text when provided, otherwise the
      last boundary-marked assistant message (or all text if no boundary
      was marked). This remains available when compact retention omits
      the text events. Manually constructed responses leave it `nil`.
    * `:events` -- retained normalized events in arrival order. Check
      `:event_coverage` before treating this as a complete log.
    * `:terminal` -- the original terminal result event, even if compact
      retention omitted it from `:events`.
    * `:event_coverage` -- counts and the first omission reason for the
      retained log. `mode: :exact` means no event was omitted.
    * `:usage` -- token usage if the backend reported any, otherwise `nil`.
    * `:duration_ms` -- wall-clock time from prompt dispatch to terminal event.
    * `:metadata` -- additive application or orchestration results, defaulting to `%{}`.
    * `:session_id` -- the backend's session identifier, if any.
    * `:model` -- the model reported on the terminal event, if known.
  """

  alias GenAgent.Event

  @type t :: %__MODULE__{
          prompt: String.t() | nil,
          text: String.t(),
          final_message: String.t() | nil,
          events: [Event.t()],
          terminal: Event.t() | nil,
          event_coverage: map(),
          usage: map() | nil,
          duration_ms: non_neg_integer(),
          metadata: map(),
          session_id: String.t() | nil,
          model: String.t() | nil
        }

  defstruct prompt: nil,
            text: "",
            final_message: nil,
            events: [],
            terminal: nil,
            event_coverage: %{},
            usage: nil,
            duration_ms: 0,
            metadata: %{},
            session_id: nil,
            model: nil

  @doc """
  Build a `Response` from a completed turn's event list and wall-clock duration.

  The `events` list must include exactly one terminal event (`:result` or
  `:error`). Text is taken from the `:result` event's `:text` field if
  present, otherwise assembled from any `:text` deltas. Deltas concatenate
  directly; a text event with `message_boundary: true` starts a separate
  assistant message after a blank line. `:final_message` selects the terminal
  text when present, otherwise the last boundary-marked message. Usage is
  taken from the most recent `:usage` event, if any.

  ## Examples

      iex> events = [
      ...>   GenAgent.Event.new(:text, %{text: "hello"}),
      ...>   GenAgent.Event.new(:result, %{text: "hello"})
      ...> ]
      iex> response = GenAgent.Response.from_events(events)
      iex> {response.text, response.final_message, response.event_coverage.mode}
      {"hello", "hello", :exact}
  """
  @spec from_events([Event.t()], keyword()) :: t()
  def from_events(events, opts \\ []) when is_list(events) do
    terminal = Enum.find(events, &Event.terminal?/1)
    usage = latest_usage(events)
    text_acc = Enum.reduce(events, new_text_acc(), &append_text/2)

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
    text = text_from_capture(terminal, text_acc)

    %__MODULE__{
      text: text,
      final_message: final_message_from_capture(terminal, text_acc, text),
      events: events,
      terminal: terminal,
      event_coverage: Keyword.fetch!(opts, :event_coverage),
      usage: usage,
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      session_id: Keyword.get(opts, :session_id),
      model: if(terminal, do: Map.get(terminal.data, :model))
    }
  end

  @doc false
  def text_from_capture(%Event{kind: :result, data: %{text: text}}, _acc)
      when is_binary(text),
      do: text

  def text_from_capture(_terminal, %{chunks: chunks}),
    do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  @doc false
  def final_message_from_capture(%Event{kind: :result, data: %{text: text}}, _acc, _assembled)
      when is_binary(text),
      do: text

  def final_message_from_capture(_terminal, %{saw_boundary?: false}, assembled), do: assembled

  def final_message_from_capture(_terminal, %{final_chunks: chunks}, _assembled),
    do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  @doc false
  def new_text_acc,
    do: %{chunks: [], seen_text?: false, final_chunks: [], saw_boundary?: false}

  @doc false
  def append_text(%Event{kind: :text, data: data}, acc) do
    text = Map.get(data, :text, "")
    boundary? = Map.get(data, :message_boundary, false)

    chunks =
      if boundary? and acc.seen_text? and text != "" do
        [text, "\n\n" | acc.chunks]
      else
        [text | acc.chunks]
      end

    final_chunks = if boundary?, do: [text], else: [text | acc.final_chunks]

    %{
      acc
      | chunks: chunks,
        seen_text?: acc.seen_text? or text != "",
        final_chunks: final_chunks,
        saw_boundary?: acc.saw_boundary? or boundary?
    }
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
