defmodule GenAgentEnsemble.Agents.Simple do
  @moduledoc """
  A reusable single-turn `GenAgent` callback module.

  The smallest useful agent: accepts a prompt, runs one backend turn,
  returns to idle ready for the next prompt. All options are forwarded
  to the backend as-is, so you can pass backend-specific keys like
  `:system_prompt` (Claude), `:system` (Anthropic), `:model`, etc.

  Intended for iex experimentation and as the default worker for
  example ensembles. For real projects you'll typically write your own
  callback module with richer state and prompt-engineered behaviour.

  ## Example (from iex)

      {:ok, _} =
        GenAgentEnsemble.start_link(
          name: "solo",
          strategy: GenAgentEnsemble.Strategies.Solo,
          opts: [
            agent: {"w", GenAgentEnsemble.Agents.Simple,
                    backend: GenAgent.Backends.Anthropic,
                    system: "You are a pragmatic Elixir reviewer."}
          ]
        )

      {:ok, r} = GenAgentEnsemble.ask("solo", "What's wrong with Enum.map(list, &(&1 + 1))?")
      IO.puts(r.text)
  """

  use GenAgent

  @impl true
  def init_agent(opts), do: {:ok, opts, %{}}

  @impl true
  def handle_response(_ref, _response, state), do: {:noreply, state}
end
