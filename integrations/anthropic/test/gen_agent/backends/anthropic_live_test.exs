defmodule GenAgent.Backends.AnthropicLiveTest do
  @moduledoc """
  Integration tests that call the real Anthropic Messages API.

  Tagged `:integration` so they do not run in the default suite.
  Requires `ANTHROPIC_API_KEY` to be set in the environment.

  Run with:

      mix test --only integration
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  defmodule LiveAnthropicAgent do
    use GenAgent

    defmodule State do
      defstruct responses: []
    end

    @impl true
    def init_agent(opts) do
      backend_opts = Keyword.take(opts, [:api_key, :model, :max_tokens, :system])
      {:ok, backend_opts, %State{}}
    end

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      {:noreply, %{state | responses: state.responses ++ [response]}}
    end
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp require_api_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> flunk("ANTHROPIC_API_KEY not set -- skipping live Anthropic tests")
      "" -> flunk("ANTHROPIC_API_KEY is empty -- skipping live Anthropic tests")
      _key -> :ok
    end
  end

  describe "full stack through GenAgent.ask/2" do
    test "round-trips a trivial prompt via the real Anthropic API" do
      require_api_key()
      name = unique_name("anthropic-live")

      {:ok, _pid} =
        GenAgent.start_agent(LiveAnthropicAgent,
          name: name,
          backend: GenAgent.Backends.Anthropic,
          max_tokens: 64,
          system: "You are a terse assistant. Respond with the minimum required."
        )

      on_exit(fn ->
        case GenAgent.whereis(name) do
          nil -> :ok
          _ -> GenAgent.stop(name)
        end
      end)

      {:ok, response} =
        GenAgent.ask(name, "Respond with exactly the word 'pong' and nothing else.")

      IO.puts("\n=== Anthropic live response ===")
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

    test "second turn sends the full conversation history" do
      require_api_key()
      name = unique_name("anthropic-live-multi")

      {:ok, _pid} =
        GenAgent.start_agent(LiveAnthropicAgent,
          name: name,
          backend: GenAgent.Backends.Anthropic,
          max_tokens: 64,
          system: "You are a terse assistant. Respond with the minimum required."
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

      IO.puts("\n=== Anthropic multi-turn ===")
      IO.puts("r1.text: #{inspect(r1.text)}")
      IO.puts("r2.text: #{inspect(r2.text)}")
      IO.puts("r1.session_id: #{inspect(r1.session_id)}")
      IO.puts("r2.session_id: #{inspect(r2.session_id)}")
      IO.puts("=== End ===\n")

      # Client-generated session_id should match because the agent is
      # the same Anthropic backend session across turns.
      assert r1.session_id == r2.session_id

      # The second response should contain "42" -- proving the full
      # conversation history was sent to the API, not just the latest
      # user message.
      assert r2.text =~ "42"
    end
  end
end
