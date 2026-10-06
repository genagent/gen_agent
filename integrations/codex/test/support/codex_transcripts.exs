defmodule GenAgent.CodexTranscripts do
  @moduledoc false
  import ExUnit.Assertions

  @directory Path.expand("../fixtures/codex/0.157.1", __DIR__)

  def directory, do: @directory
  def manifest, do: @directory |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
  def names, do: manifest()["scenarios"] |> Map.keys() |> Enum.sort()

  def load(name) do
    metadata = Map.fetch!(manifest()["scenarios"], name)
    lines = @directory |> Path.join("#{name}.jsonl") |> File.stream!() |> Enum.to_list()
    assert length(lines) == metadata["lines"]

    Enum.map(lines, fn line ->
      assert {:ok, event} = CodexWrapper.JsonLineEvent.parse(line)
      event
    end)
  end

  def thread_id(name), do: hd(load(name)).data["thread_id"]
  def failure, do: List.last(load("failure")).data["error"]

  def text("success"), do: "pong"
  def text("resume-initial"), do: "ok"
  def text("resume-followup"), do: "42"

  def text("command"),
    do: "I’ll run the command and report its output.\n\n```text\ncodex-fixture\n```"

  def expected("failure") do
    data = List.last(load("failure")).data
    item = Enum.at(load("failure"), 1).data["item"]
    [{:tool_result, item}, {:error, %{reason: data["error"], data: data}}]
  end

  def expected(name) do
    {input, cached, output} =
      case name do
        "success" -> {14_952, 12_160, 5}
        "command" -> {30_035, 27_008, 61}
        "resume-initial" -> {14_956, 12_160, 5}
        "resume-followup" -> {29_938, 24_320, 10}
      end

    # Raw recorded totals, reported as-is for a fresh session.
    usage = %{
      input_tokens: input,
      cached_input_tokens: cached,
      cache_write_input_tokens: 0,
      output_tokens: output,
      reasoning_output_tokens: 0
    }

    messages(name) ++
      [{:usage, usage}, {:result, %{session_id: thread_id(name), usage_total: usage}}]
  end

  defp messages("command") do
    item = %{
      "id" => "item_1",
      "type" => "command_execution",
      "command" => "/bin/zsh -lc 'printf codex-fixture'",
      "aggregated_output" => "codex-fixture",
      "exit_code" => 0,
      "status" => "completed"
    }

    [
      {:text, %{text: "I’ll run the command and report its output.", message_boundary: true}},
      {:tool_use, Map.take(item, ["id", "type"])},
      {:tool_result, item},
      {:text, %{text: "```text\ncodex-fixture\n```", message_boundary: true}}
    ]
  end

  defp messages(name), do: [{:text, %{text: text(name), message_boundary: true}}]

  def assert_events(events, name, expected_usage \\ nil) do
    expected =
      case expected_usage do
        nil -> expected(name)
        usage -> List.keyreplace(expected(name), :usage, 0, {:usage, usage})
      end

    assert Enum.map(events, &{&1.kind, &1.data}) == expected
  end
end
