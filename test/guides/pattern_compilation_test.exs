defmodule GenAgent.PatternCompilationTest do
  use ExUnit.Case, async: false

  test "every copyable pattern module compiles without diagnostics" do
    guides = Path.wildcard(Path.expand("../../guides/patterns/*.md", __DIR__))

    blocks =
      for guide <- guides,
          [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
          String.starts_with?(code, "defmodule "),
          do: {guide, code}

    # The supervisor example calls Fanout.Watcher.start/2 from its
    # coordinator; compile that sibling before checking the coordinator.
    blocks =
      blocks
      |> Enum.with_index()
      |> Enum.sort_by(fn {{guide, code}, index} ->
        priority =
          if Path.basename(guide) == "supervisor.md" and
               String.starts_with?(code, "defmodule Fanout.Watcher do"),
             do: 0,
             else: 1

        {guide, priority, index}
      end)
      |> Enum.map(&elem(&1, 0))

    assert length(blocks) >= 16

    original = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      for {guide, code} <- blocks do
        {_modules, diagnostics} =
          Code.with_diagnostics(fn -> Code.compile_string(code, guide) end)

        assert diagnostics == [],
               "#{Path.relative_to_cwd(guide)} emitted compiler diagnostics: #{inspect(diagnostics)}"
      end
    after
      Code.put_compiler_option(:ignore_module_conflict, original)
    end
  end
end
