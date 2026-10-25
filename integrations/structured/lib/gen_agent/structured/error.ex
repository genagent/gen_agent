defmodule GenAgent.Structured.Error do
  @moduledoc """
  A failure at a structured request boundary.

  `stage` identifies the boundary; `reason` carries diagnostic data. A provider
  turn may already have happened when output validation fails, so callers may
  receive its original `GenAgent.Response` in `response`. The exception message
  deliberately excludes payloads, provider errors, and schema values.
  """

  defexception [:stage, :reason, :request_id, :response, :profile]

  @type t :: %__MODULE__{
          stage: atom(),
          reason: term(),
          request_id: String.t() | nil,
          response: GenAgent.Response.t() | nil,
          profile: %{name: String.t(), revision: String.t()} | nil
        }

  @impl true
  def message(%__MODULE__{stage: stage}) when is_atom(stage),
    do: "Structured request failed at #{stage} stage"

  def message(_), do: "Structured request failed"
end
