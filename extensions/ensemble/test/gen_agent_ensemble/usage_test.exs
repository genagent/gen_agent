defmodule GenAgentEnsemble.UsageTest do
  use ExUnit.Case, async: true

  alias GenAgentEnsemble.Usage

  test "sums numeric fields by original key and agent, ignoring provider metadata" do
    usage =
      Usage.new()
      |> Usage.add("a", %{input_tokens: 10, output_tokens: 2, model: "mock", details: %{x: 1}})
      |> Usage.add("b", %{"input_tokens" => 3, :output_tokens => 5, :cost => 0.25})
      |> Usage.add("a", %{input_tokens: 4, output_tokens: nil, by_agent: 100, cached: 0})
      |> Usage.add("missing", nil)
      |> Usage.add("invalid", "unknown")
      |> Usage.to_usage()

    assert usage == %{
             :input_tokens => 14,
             "input_tokens" => 3,
             :output_tokens => 7,
             :cost => 0.25,
             :cached => 0,
             :by_agent => %{
               "a" => %{input_tokens: 14, output_tokens: 2, cached: 0},
               "b" => %{"input_tokens" => 3, :output_tokens => 5, :cost => 0.25}
             }
           }

    totals =
      Enum.reduce(usage.by_agent, %{}, fn {_, counts}, acc ->
        Map.merge(acc, counts, fn _, a, b -> a + b end)
      end)

    assert Map.delete(usage, :by_agent) == totals
  end

  test "absent usage stays nil, while a reported empty map retains attribution" do
    assert Usage.new() |> Usage.add("a", nil) |> Usage.add("b", nil) |> Usage.to_usage() == nil
    assert Usage.new() |> Usage.add("a", %{}) |> Usage.to_usage() == %{by_agent: %{"a" => %{}}}

    assert Usage.new() |> Usage.add("a", %{model: "mock"}) |> Usage.to_usage() ==
             %{by_agent: %{"a" => %{}}}
  end
end
