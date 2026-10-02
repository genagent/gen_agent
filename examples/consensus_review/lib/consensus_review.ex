defmodule ConsensusReview do
  @moduledoc """
  A bounded proposal and Consensus review loop with owned agent lifetimes.

  `run/2` requires `:drafter` backend options and at least two named
  `:reviewers` as `{name, backend_options}` pairs. Backends default to
  `ConsensusReview.ScriptedBackend`. Optional settings are `:max_rounds`
  (3), `:consensus_rounds` (1), `:threshold` (`:majority`), and panel
  call `:timeout` (`:infinity`).

  Returns `{:ok, %{draft: text, history: entries, stopped: reason}}`, where
  reason is `:approved`, `:max_rounds`, or `:no_consensus`. Backend errors
  are returned as `{:error, reason}`. All owned agents are stopped on return.
  """

  alias GenAgentEnsemble.Agents.Simple

  @doc """
  Drafts and reviews a task until approval, divergence, or the round bound.

  Requires `:drafter` backend options and named `:reviewers`; see the module
  documentation for options and result fields. Reviewer backend errors include
  the reviewer name as `{:error, {name, reason}}`.

  The panel call `:timeout` defaults to `:infinity`. A finite value is in
  milliseconds and exits the caller on expiry, rather than returning an error.
  Owned agents are stopped during cleanup in either case.
  """
  @spec run(String.t(), keyword()) ::
          {:ok,
           %{
             draft: String.t(),
             history: [map()],
             stopped: :approved | :max_rounds | :no_consensus
           }}
          | {:error, term()}
  def run(task, opts) when is_binary(task) do
    max_rounds = positive!(opts, :max_rounds, 3)
    consensus_rounds = positive!(opts, :consensus_rounds, 1)
    timeout = Keyword.get(opts, :timeout, :infinity)
    prefix = "consensus-review-#{System.unique_integer([:positive, :monotonic])}"
    drafter = prefix <> "/drafter"
    panel = prefix <> "/panel"
    drafter_opts = backend_opts(Keyword.fetch!(opts, :drafter))

    reviewers =
      for {name, reviewer_opts} <- Keyword.fetch!(opts, :reviewers) do
        {name, Simple, backend_opts(reviewer_opts)}
      end

    panel_opts = [
      agents: reviewers,
      verdict_parser: &parse_verdict/1,
      threshold: Keyword.get(opts, :threshold, :majority),
      rounds: consensus_rounds,
      reply: {:synthesize, &encode_summary/1}
    ]

    with {:ok, _} <- GenAgent.start_agent(Simple, Keyword.put(drafter_opts, :name, drafter)) do
      try do
        with {:ok, _} <-
               GenAgentEnsemble.start_link(
                 name: panel,
                 strategy: GenAgentEnsemble.Strategies.Consensus,
                 opts: panel_opts
               ) do
          try do
            loop(task, drafter, panel, {max_rounds, timeout}, 1, nil, [])
          after
            GenAgentEnsemble.stop(panel)
          end
        end
      after
        GenAgent.stop(drafter)
      end
    end
  end

  @doc "Parses a final VERDICT: APPROVE or VERDICT: REVISE line."
  def parse_verdict(text) do
    case text |> String.trim() |> String.split("\n") |> Enum.reverse() do
      ["VERDICT: APPROVE" | rationale] -> {:ok, :approve, rationale_text(rationale)}
      ["VERDICT: REVISE" | rationale] -> {:ok, :revise, rationale_text(rationale)}
      _ -> :error
    end
  end

  defp rationale_text(lines), do: lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()

  defp loop(task, drafter, panel, {max_rounds, timeout} = limits, round, previous, history) do
    with {:ok, draft} <- GenAgent.ask(drafter, draft_prompt(task, previous)),
         {:ok, review} <-
           GenAgentEnsemble.ask(panel, review_prompt(task, draft.text), timeout: timeout) do
      # Only our local synthesis callback produces this envelope, never a backend.
      summary = review.text |> Base.decode64!() |> :erlang.binary_to_term([:safe])

      entry = %{
        round: round,
        verdict: summary.verdict,
        status: summary.status,
        consensus_rounds: summary.rounds,
        rationales:
          Enum.map(summary.responses, fn {agent, verdict, rationale, _raw} ->
            %{agent: agent, verdict: verdict, rationale: rationale}
          end)
      }

      history = history ++ [entry]

      stopped =
        cond do
          summary.status == :diverged -> :no_consensus
          summary.verdict == :approve -> :approved
          round >= max_rounds -> :max_rounds
          true -> nil
        end

      if stopped do
        {:ok, %{draft: draft.text, history: history, stopped: stopped}}
      else
        loop(task, drafter, panel, limits, round + 1, {draft.text, entry}, history)
      end
    end
  end

  defp draft_prompt(task, nil), do: "Produce a change proposal for this task:\n#{task}"

  defp draft_prompt(task, {draft, entry}) do
    rationales = Enum.map_join(entry.rationales, "\n", &"#{&1.agent}: #{&1.rationale}")

    """
    Revise the change proposal for this task:
    #{task}

    Previous draft:
    #{draft}

    Reviewer rationales:
    #{rationales}
    """
  end

  defp review_prompt(task, draft) do
    """
    Review this change proposal for the task: #{task}

    #{draft}

    Give your rationale, then end with exactly one line:
    VERDICT: APPROVE
    or
    VERDICT: REVISE
    """
  end

  defp encode_summary(summary), do: summary |> :erlang.term_to_binary() |> Base.encode64()

  defp backend_opts(opts), do: Keyword.put_new(opts, :backend, ConsensusReview.ScriptedBackend)

  defp positive!(opts, key, default) do
    value = Keyword.get(opts, key, default)

    unless is_integer(value) and value > 0 do
      raise ArgumentError, "#{key} must be a positive integer"
    end

    value
  end
end
