defmodule GenAgent.Backends.CodexProbeTest do
  @moduledoc """
  Live probe that dumps every `%CodexWrapper.JsonLineEvent{}` emitted
  by the real `codex` CLI for a trivial prompt. Used to design the
  event translator from observed data rather than guessed docs.

  Tagged `:live`; does not run in the default suite.
  """

  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 180_000

  alias CodexWrapper.JsonLineEvent

  test "dump Codex event shapes for a trivial prompt" do
    {:ok, events} =
      CodexWrapper.exec_json(
        "Respond with exactly the string 'pong' and nothing else.",
        skip_git_repo_check: true,
        sandbox: :read_only
      )

    IO.puts("\n=== Raw Codex JsonLineEvent probe ===")
    IO.puts("Total events: #{length(events)}")

    Enum.with_index(events, 1)
    |> Enum.each(fn {%JsonLineEvent{event_type: type, data: data}, i} ->
      IO.puts("\n[#{i}] event_type=#{inspect(type)}")
      IO.puts("    data keys: #{inspect(Map.keys(data))}")
      IO.puts("    data: #{inspect(data, pretty: true, limit: :infinity)}")
    end)

    IO.puts("\n=== End probe ===\n")

    assert events != []
  end
end
