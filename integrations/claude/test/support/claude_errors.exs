defmodule GenAgent.ClaudeErrors do
  @moduledoc false

  alias GenAgent.Backend.Error
  @compile {:no_warn_undefined, Error}

  def expected(raw) do
    if Code.ensure_loaded?(Error),
      do: Error.normalize(:claude, raw),
      else: raw
  end

  def raw(%{__struct__: Error, raw: raw}), do: raw
  def raw(raw), do: raw
end
