defmodule GenAgent.Event do
  @moduledoc """
  A normalized event emitted by a backend during a prompt turn.

  Backends translate their native event streams into `GenAgent.Event` values
  so the state machine and user callbacks see a consistent shape regardless
  of which LLM is on the other end.

  ## Event kinds

    * `:text` -- an assistant text chunk (delta). `data` carries `%{text: String.t()}`.
    * `:tool_use` -- the agent invoked a tool. `data` is backend-specific.
    * `:tool_result` -- a tool returned. `data` is backend-specific.
    * `:usage` -- token usage info. `data` typically carries
      `%{input_tokens: integer(), output_tokens: integer()}`.
    * `:result` -- terminal event for a successful turn. `data` carries at
      minimum `%{text: String.t()}` with the full assembled assistant text.
    * `:error` -- terminal event for a failed turn. `data` carries
      `%{reason: term()}`.

  Exactly one terminal event (`:result` or `:error`) is emitted per turn.
  """

  @type kind ::
          :text
          | :tool_use
          | :tool_result
          | :usage
          | :result
          | :error

  @type t :: %__MODULE__{
          kind: kind(),
          data: map(),
          timestamp: integer()
        }

  defstruct [:kind, :data, :timestamp]

  @doc """
  Build an event of the given `kind` with `data`.

  The timestamp is stamped from `System.monotonic_time/1` in milliseconds,
  so event timestamps are suitable for computing durations within a single
  turn but are not wall-clock values.
  """
  @spec new(kind(), map()) :: t()
  def new(kind, data \\ %{}) when is_atom(kind) and is_map(data) do
    %__MODULE__{
      kind: kind,
      data: data,
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  True if the event is a terminal event (`:result` or `:error`).

  Terminal events mark the end of a turn. The stream from
  `c:GenAgent.Backend.prompt/2` should emit exactly one terminal event.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{kind: kind}), do: kind in [:result, :error]
end
