defmodule GenAgent.Backends.ClaudeLiveTest do
  @moduledoc """
  Live tests that invoke the real `claude` CLI. Tagged
  `:live` so they do not run in the default `mix test` suite.

  Run with:

      mix test --only live

  These tests burn real tokens. Keep them cheap (short prompts, no
  tools, no file operations).
  """

  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 120_000

  alias ClaudeWrapper.StreamEvent

  defmodule LiveAgent do
    use GenAgent

    defmodule State do
      defstruct responses: [], turn: 0
    end

    @impl true
    def init_agent(opts) do
      backend_opts =
        Keyword.take(opts, [
          :working_dir,
          :cwd,
          :model,
          :system_prompt,
          :permission_mode,
          :max_turns
        ])

      {:ok, backend_opts, %State{}}
    end

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      {:noreply, %{state | responses: state.responses ++ [response], turn: state.turn + 1}}
    end
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  # ---------------------------------------------------------------------------
  # Probe: dump what ClaudeWrapper.stream/2 actually emits
  # ---------------------------------------------------------------------------

  describe "raw ClaudeWrapper.stream/2 probe" do
    test "dumps raw StreamEvent shapes for a trivial prompt" do
      events =
        ClaudeWrapper.stream(
          "Respond with exactly the string 'pong' and nothing else.",
          max_turns: 1
        )
        |> Enum.to_list()

      IO.puts("\n=== Raw StreamEvent probe ===")
      IO.puts("Total events: #{length(events)}")

      Enum.with_index(events, 1)
      |> Enum.each(fn {%StreamEvent{type: type, data: data}, i} ->
        IO.puts("\n[#{i}] type=#{inspect(type)}")
        IO.puts("    data keys: #{inspect(Map.keys(data))}")
        IO.puts("    data: #{inspect(data, pretty: true, limit: :infinity)}")
      end)

      IO.puts("\n=== End probe ===\n")

      # Loose assertions -- we just want to know *something* came back.
      assert events != []
      assert Enum.any?(events, &StreamEvent.result?/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Full stack through GenAgent.ask/2
  # ---------------------------------------------------------------------------

  describe "full stack through GenAgent.ask/2" do
    test "round-trips a trivial prompt and captures session_id" do
      name = unique_name("claude-live")

      {:ok, _pid} =
        GenAgent.start_agent(LiveAgent,
          name: name,
          backend: GenAgent.Backends.Claude,
          max_turns: 1
        )

      on_exit(fn ->
        case GenAgent.whereis(name) do
          nil -> :ok
          _ -> GenAgent.stop(name)
        end
      end)

      {:ok, response} =
        GenAgent.ask(name, "Respond with exactly the string 'pong' and nothing else.")

      IO.puts("\n=== GenAgent.ask response ===")
      IO.puts("text: #{inspect(response.text)}")
      IO.puts("session_id: #{inspect(response.session_id)}")
      IO.puts("duration_ms: #{response.duration_ms}")
      IO.puts("usage: #{inspect(response.usage)}")
      IO.puts("event kinds: #{inspect(Enum.map(response.events, & &1.kind))}")
      IO.puts("=== End ===\n")

      assert is_binary(response.text)
      assert response.text != ""
      assert is_binary(response.session_id)
      assert response.duration_ms > 0
      assert Enum.any?(response.events, &(&1.kind == :result))

      assert %{input_tokens: input, output_tokens: output} = response.usage
      assert is_integer(input) and input > 0
      assert is_integer(output) and output > 0
    end

    test "second turn continues the same session via --resume" do
      name = unique_name("claude-live-multi")

      {:ok, _pid} =
        GenAgent.start_agent(LiveAgent,
          name: name,
          backend: GenAgent.Backends.Claude,
          max_turns: 1
        )

      on_exit(fn ->
        case GenAgent.whereis(name) do
          nil -> :ok
          _ -> GenAgent.stop(name)
        end
      end)

      {:ok, r1} =
        GenAgent.ask(
          name,
          "Remember the number 42. Respond with exactly 'ok' and nothing else."
        )

      {:ok, r2} =
        GenAgent.ask(
          name,
          "What number did I ask you to remember? Respond with just the number."
        )

      IO.puts("\n=== Multi-turn ===")
      IO.puts("r1.session_id: #{inspect(r1.session_id)}")
      IO.puts("r2.session_id: #{inspect(r2.session_id)}")
      IO.puts("r1.text: #{inspect(r1.text)}")
      IO.puts("r2.text: #{inspect(r2.text)}")
      IO.puts("=== End ===\n")

      assert is_binary(r1.session_id)
      assert is_binary(r2.session_id)
      assert r2.text =~ "42"
    end
  end
end
