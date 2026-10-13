defmodule GenAgentEnsemble.Strategies.SessionCarryoverTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble.Strategies.{Consensus, Debate}

  defmodule ObserverAgent do
    @moduledoc false
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, Keyword.take(opts, [:observer, :tag]), %{}}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  defmodule ObserverBackend do
    @moduledoc false
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts) do
      {:ok,
       %{
         observer: Keyword.fetch!(opts, :observer),
         tag: Keyword.fetch!(opts, :tag),
         id: make_ref(),
         history: []
       }}
    end

    @impl true
    def prompt(session, prompt) do
      updated = %{session | history: session.history ++ [{session.tag, prompt}]}
      gate = make_ref()
      send(session.observer, {:session_prompt, session.tag, session, updated, self(), gate})

      receive do
        {:release, ^gate} ->
          text = "#{session.tag}: approve"
          {:ok, [GenAgent.Event.new(:result, %{text: text})], updated}
      after
        5_000 -> {:error, :fixture_timeout}
      end
    end

    @impl true
    def terminate_session(_session), do: :ok
  end

  test "Consensus retains each agent's returned backend session across successful runs" do
    parser = fn
      text when text in ["alice: approve", "bob: approve"] -> {:ok, :approve, text}
      _text -> :error
    end

    name = start_ensemble(Consensus, rounds: 1, threshold: :unanimous, verdict_parser: parser)

    assert {:ok, first} = GenAgentEnsemble.tell(name, "first question")
    alice = release_prompt("alice", nil, "first question")
    bob = release_prompt("bob", nil, "first question")
    refute alice.id == bob.id
    assert {:ok, response} = GenAgentEnsemble.await(name, first, 5_000)
    assert response.text =~ "CONSENSUS: :approve (2 of 2 agreed via unanimous, round 1)"

    assert {:ok, second} = GenAgentEnsemble.tell(name, "second question")
    alice = release_prompt("alice", alice, "second question")
    bob = release_prompt("bob", bob, "second question")
    assert alice.history == [{"alice", "first question"}, {"alice", "second question"}]
    assert bob.history == [{"bob", "first question"}, {"bob", "second question"}]
    assert {:ok, response} = GenAgentEnsemble.await(name, second, 5_000)
    assert response.text =~ "CONSENSUS: :approve (2 of 2 agreed via unanimous, round 1)"
  end

  test "Debate retains independent backend histories across successful runs" do
    name = start_ensemble(Debate, rounds: 2)

    assert {:ok, first} = GenAgentEnsemble.tell(name, "first topic")
    alice = release_prompt("alice", nil, "first topic")
    bob = release_prompt("bob", nil, "first topic\n\nalice:\nalice: approve")
    refute alice.id == bob.id
    assert {:ok, response} = GenAgentEnsemble.await(name, first, 5_000)
    assert response.text == "alice:\nalice: approve\n\nbob:\nbob: approve"

    assert {:ok, second} = GenAgentEnsemble.tell(name, "second topic")
    alice = release_prompt("alice", alice, "second topic")
    bob = release_prompt("bob", bob, "second topic\n\nalice:\nalice: approve")
    assert alice.history == [{"alice", "first topic"}, {"alice", "second topic"}]

    assert bob.history == [
             {"bob", "first topic\n\nalice:\nalice: approve"},
             {"bob", "second topic\n\nalice:\nalice: approve"}
           ]

    assert {:ok, response} = GenAgentEnsemble.await(name, second, 5_000)
    assert response.text == "alice:\nalice: approve\n\nbob:\nbob: approve"
  end

  defp start_ensemble(strategy, opts) do
    name = "session-carryover-#{System.unique_integer([:positive])}"

    agents =
      for tag <- ["alice", "bob"] do
        {tag, ObserverAgent, [backend: ObserverBackend, observer: self(), tag: tag]}
      end

    start_supervised!(%{
      id: name,
      start:
        {GenAgentEnsemble, :start_link,
         [[name: name, strategy: strategy, opts: Keyword.put(opts, :agents, agents)]]},
      restart: :temporary,
      shutdown: :infinity
    })

    name
  end

  defp release_prompt(tag, previous, prompt) do
    assert_receive {:session_prompt, ^tag, session, updated, pid, gate}, 2_000

    # Compare the actual input session with the preceding prompt's returned
    # session; a counter outside the backend session cannot satisfy this check.
    if previous do
      assert session == previous
    else
      assert session.history == []
      assert is_reference(session.id)
    end

    assert session.tag == tag
    assert updated == %{session | history: session.history ++ [{tag, prompt}]}
    send(pid, {:release, gate})
    updated
  end
end
