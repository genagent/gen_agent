defmodule GenAgent.Backends.CodexLiveTest do
  @moduledoc """
  Live tests that invoke the real `codex` CLI. Tagged
  `:live` so they do not run in the default `mix test` suite.

  Run with:

      mix test --only live

  These tests burn real tokens. Keep them cheap (short prompts, no
  tool calls beyond what Codex auto-does on startup).
  """

  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 240_000

  defmodule LiveCodexAgent do
    use GenAgent

    defmodule State do
      defstruct responses: [], turn: 0
    end

    @impl true
    def init_agent(opts) do
      backend_opts =
        Keyword.take(opts, [
          :model,
          :sandbox,
          :skip_git_repo_check,
          :cwd,
          :working_dir
        ])

      {:ok, backend_opts, %State{}}
    end

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      {:noreply, %{state | responses: state.responses ++ [response], turn: state.turn + 1}}
    end
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "full stack through GenAgent.ask/2" do
    test "round-trips a trivial prompt and captures thread_id as session_id" do
      name = unique_name("codex-live")

      {:ok, _pid} =
        GenAgent.start_agent(LiveCodexAgent,
          name: name,
          backend: GenAgent.Backends.Codex,
          sandbox: :read_only,
          skip_git_repo_check: true
        )

      on_exit(fn ->
        case GenAgent.whereis(name) do
          nil -> :ok
          _ -> GenAgent.stop(name)
        end
      end)

      {:ok, response} =
        GenAgent.ask(name, "Respond with exactly the string 'pong' and nothing else.")

      IO.puts("\n=== Codex live response ===")
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

      assert %{input_tokens: input, output_tokens: output} = response.usage
      assert is_integer(input) and input > 0
      assert is_integer(output) and output > 0
    end

    test "second turn continues the same thread via ExecResume" do
      name = unique_name("codex-live-multi")

      {:ok, _pid} =
        GenAgent.start_agent(LiveCodexAgent,
          name: name,
          backend: GenAgent.Backends.Codex,
          sandbox: :read_only,
          skip_git_repo_check: true
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

      IO.puts("\n=== Codex multi-turn ===")
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
