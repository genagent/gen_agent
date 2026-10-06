defmodule ConsensusReviewTest do
  use ExUnit.Case, async: false

  setup do
    agents = live_pids(GenAgent.Registry)
    panels = live_pids(GenAgentEnsemble.Registry)

    on_exit(fn ->
      assert live_pids(GenAgent.Registry) == agents
      assert live_pids(GenAgentEnsemble.Registry) == panels
    end)

    :ok
  end

  test "approval on the first round returns the first draft" do
    assert {:ok, result} =
             run(["Initial proposal"], [approve("Looks correct")], max_rounds: 1)

    assert result.draft == "Initial proposal"
    assert result.stopped == :approved
    assert [%{round: 1, verdict: :approve, consensus_rounds: 1}] = result.history

    assert Enum.map(hd(result.history).rationales, & &1.rationale) ==
             ["Looks correct", "Looks correct"]
  end

  test "revision receives the task, previous draft, and both reviewer rationales" do
    caller = self()

    revision = fn prompt ->
      send(caller, {:revision_prompt, prompt})
      "Proposal with tests and docs"
    end

    assert {:ok, result} =
             ConsensusReview.run("Add a feature",
               drafter: [script: ["Initial proposal", revision]],
               reviewers: [
                 {"correctness", script: [revise("Add tests"), approve("Tests cover it")]},
                 {"usability", script: [revise("Add docs"), approve("Docs explain it")]}
               ],
               threshold: :unanimous
             )

    assert_received {:revision_prompt, prompt}
    assert prompt =~ "Add a feature"
    assert prompt =~ "Initial proposal"
    assert prompt =~ "correctness: Add tests"
    assert prompt =~ "usability: Add docs"
    assert Enum.map(hd(result.history).rationales, & &1.agent) == ["correctness", "usability"]
    assert result.draft == "Proposal with tests and docs"
    assert result.stopped == :approved
    assert Enum.map(result.history, &{&1.round, &1.verdict}) == [{1, :revise}, {2, :approve}]
  end

  test "repeated revision stops at the bound with the last draft" do
    assert {:ok, result} =
             run(["Draft 1", "Draft 2", "Draft 3"], List.duplicate(revise("Add tests"), 3))

    assert result.draft == "Draft 3"
    assert result.stopped == :max_rounds

    assert Enum.map(result.history, &{&1.round, &1.verdict}) ==
             [{1, :revise}, {2, :revise}, {3, :revise}]
  end

  test "divergence stops after the independent Consensus round cap" do
    assert {:ok, result} =
             ConsensusReview.run("Add a feature",
               drafter: [script: ["Initial proposal"]],
               reviewers: [
                 {"one", script: List.duplicate(approve("Ready"), 2)},
                 {"two", script: List.duplicate(revise("Missing tests"), 2)}
               ],
               consensus_rounds: 2
             )

    assert result.stopped == :no_consensus
    assert result.draft == "Initial proposal"
    assert [%{round: 1, verdict: nil, status: :diverged, consensus_rounds: 2}] = result.history
  end

  test "an unparseable response abstains and prevents unanimity" do
    assert {:ok, result} =
             ConsensusReview.run("Add a feature",
               drafter: [script: ["Initial proposal"]],
               reviewers: [
                 {"one", script: [approve("Ready")]},
                 {"two", script: ["Unsure"]}
               ],
               threshold: :unanimous
             )

    assert result.stopped == :no_consensus

    assert [%{verdict: :approve}, %{verdict: nil, rationale: "Unsure"}] =
             hd(result.history).rationales
  end

  test "drafter script exhaustion returns an error and cleans up the agents" do
    assert {:error, :script_exhausted} = run([], [approve("Ready")])
  end

  test "reviewer script exhaustion identifies the reviewer and cleans up the agents" do
    assert {:error, {"correctness", :script_exhausted}} =
             ConsensusReview.run("Add a feature",
               drafter: [script: ["Initial proposal"]],
               reviewers: [
                 {"correctness", script: []},
                 {"usability", script: [approve("Ready")]}
               ]
             )
  end

  test "only a final supported verdict line is parsed" do
    assert {:ok, :approve, "Ready"} = ConsensusReview.parse_verdict("Ready\nVERDICT: APPROVE\n")
    assert {:ok, :revise, "Add tests"} = ConsensusReview.parse_verdict(revise("Add tests"))
    assert :error = ConsensusReview.parse_verdict("VERDICT: APPROVE\nMore text")
    assert :error = ConsensusReview.parse_verdict("VERDICT: REJECT")
    assert :error = ConsensusReview.parse_verdict("Looks good")
  end

  test "round bounds must be positive integers" do
    for key <- [:max_rounds, :consensus_rounds], value <- [0, -1, 1.5] do
      assert_raise ArgumentError, fn -> run([], [], [{key, value}]) end
    end
  end

  defp run(drafts, reviews, opts \\ []) do
    ConsensusReview.run(
      "Add a feature",
      Keyword.merge(
        [
          drafter: [script: drafts],
          reviewers: [{"one", script: reviews}, {"two", script: reviews}]
        ],
        opts
      )
    )
  end

  defp approve(rationale), do: rationale <> "\nVERDICT: APPROVE"
  defp revise(rationale), do: rationale <> "\nVERDICT: REVISE"

  defp live_pids(registry) do
    # Registry removes dead entries asynchronously after synchronous agent shutdown.
    registry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.filter(&Process.alive?/1)
    |> Enum.sort()
  end
end
