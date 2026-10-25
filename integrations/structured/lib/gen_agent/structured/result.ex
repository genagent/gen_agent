defmodule GenAgent.Structured.Result do
  @moduledoc """
  Validated request output together with the original provider response.

  `output` is a JSON value. `response` retains text, usage, session identifiers,
  and terminal evidence; it is not itself a JSON-safe public projection.
  `profile` records the selected name and revision, or is `nil` for a raw contract.
  """

  defstruct [:request_id, :output, :response, :profile]

  @type t :: %__MODULE__{
          request_id: String.t() | nil,
          output: term(),
          response: GenAgent.Response.t() | nil,
          profile: %{name: String.t(), revision: String.t()} | nil
        }
end
