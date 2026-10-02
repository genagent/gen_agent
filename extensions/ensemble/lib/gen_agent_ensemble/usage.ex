defmodule GenAgentEnsemble.Usage do
  @moduledoc false

  @type t :: %{optional(String.t()) => map()}

  @spec new() :: t()
  def new, do: %{}

  @spec add(t(), String.t(), term()) :: t()
  def add(acc, agent, usage) when is_map(usage) do
    numeric = Map.filter(usage, fn {key, value} -> key != :by_agent and is_number(value) end)
    Map.update(acc, agent, numeric, &sum(&1, numeric))
  end

  def add(acc, _agent, _usage), do: acc

  @spec to_usage(t()) :: map() | nil
  def to_usage(acc) when map_size(acc) == 0, do: nil

  def to_usage(acc) do
    acc
    |> Map.values()
    |> Enum.reduce(%{}, &sum/2)
    |> Map.put(:by_agent, acc)
  end

  defp sum(left, right), do: Map.merge(left, right, fn _key, a, b -> a + b end)
end
