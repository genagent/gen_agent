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
    # Issue #184: the recorded non-agent error item is currently filtered.
    [{:error, %{reason: data["error"], data: data}}]
  end

  def expected(name) do
    {input, cached, output} =
      case name do
        "success" -> {14_952, 12_160, 5}
        "command" -> {30_035, 27_008, 61}
        "resume-initial" -> {14_956, 12_160, 5}
        "resume-followup" -> {29_938, 24_320, 10}
      end

    # Issue #124: cache_write_input_tokens and reasoning_output_tokens are currently dropped.
    usage = %{input_tokens: input, cached_input_tokens: cached, output_tokens: output}

    messages(name) ++ [{:usage, usage}, {:result, %{session_id: thread_id(name)}}]
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
      {:tool_use, item},
      {:tool_result, item},
      {:text, %{text: "```text\ncodex-fixture\n```", message_boundary: true}}
    ]
  end

  defp messages(name), do: [{:text, %{text: text(name), message_boundary: true}}]

  def assert_events(events, name) do
    assert Enum.map(events, &{&1.kind, &1.data}) == expected(name)
  end
end
