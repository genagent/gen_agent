defmodule GenAgent.Response do
  @moduledoc """
  The result of a completed prompt turn, delivered to `c:GenAgent.handle_response/3`.

  A `Response` is built by the state machine after a terminal event
  (`:result` or `:error`) arrives from the backend. It carries:

    * `:text` -- the full assembled assistant text for the turn.
    * `:events` -- the complete event log for the turn, in arrival order.
    * `:usage` -- token usage if the backend reported any, otherwise `nil`.
    * `:duration_ms` -- wall-clock time from prompt dispatch to terminal event.
    * `:session_id` -- the backend's session identifier, if any.
  """

  alias GenAgent.Event

  @type t :: %__MODULE__{
          text: String.t(),
          events: [Event.t()],
          usage: map() | nil,
          duration_ms: non_neg_integer(),
          session_id: String.t() | nil
        }

  defstruct text: "",
            events: [],
            usage: nil,
            duration_ms: 0,
            session_id: nil

  @doc """
  Build a `Response` from a completed turn's event list and wall-clock duration.

  The `events` list must include exactly one terminal event (`:result` or
  `:error`). Text is taken from the `:result` event's `:text` field if
  present, otherwise assembled from any `:text` deltas. Usage is taken from
  the most recent `:usage` event, if any.
  """
  @spec from_events([Event.t()], keyword()) :: t()
  def from_events(events, opts \\ []) when is_list(events) do
    %__MODULE__{
      text: assemble_text(events),
      events: events,
      usage: extract_usage(events),
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      session_id: Keyword.get(opts, :session_id)
    }
  end

  defp assemble_text(events) do
    case Enum.find(events, fn e -> e.kind == :result end) do
      %Event{data: %{text: text}} when is_binary(text) ->
        text

      _ ->
        events
        |> Enum.filter(&(&1.kind == :text))
        |> Enum.map_join("", fn %Event{data: data} -> Map.get(data, :text, "") end)
    end
  end

  defp extract_usage(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Event{kind: :usage, data: data} -> data
      _ -> nil
    end)
  end
end
