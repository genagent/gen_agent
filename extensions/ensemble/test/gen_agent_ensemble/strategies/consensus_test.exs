defmodule GenAgentEnsemble.Strategies.ConsensusTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.Strategies.Consensus
  alias GenAgentEnsemble.TestAgent

  setup do
    name = "consensus-#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(name) end)
    %{name: name}
  end

  defp safe_stop(name) do
    GenAgentEnsemble.stop(name)
  catch
    :exit, _ -> :ok
  end

  # Simple verdict parser: looks for "VERDICT: X" in text.
  defp parser do
    fn text ->
      case Regex.run(~r/VERDICT:\s*(\w+)/i, text) do
        [_, verdict_str] ->
          atom = verdict_str |> String.downcase() |> String.to_atom()
          rationale = Regex.replace(~r/VERDICT:\s*\w+/i, text, "") |> String.trim()
          {:ok, atom, rationale}

        _ ->
          :error
      end
    end
  end

  defp say(verdict_and_text) do
    fn _prompt -> [Event.new(:result, %{text: verdict_and_text})] end
  end

  defp start_consensus(name, agent_scripts, extra_opts \\ []) do
    agents =
      for {sub_name, scripts} <- agent_scripts do
        {sub_name, TestAgent, [backend: Mock, scripts: scripts]}
      end

    opts =
      extra_opts
      |> Keyword.put(:agents, agents)
      |> Keyword.put_new(:verdict_parser, parser())

    GenAgentEnsemble.start_link(name: name, strategy: Consensus, opts: opts)
  end

  defp await_completion(name, token, retries \\ 100) do
    case GenAgentEnsemble.poll(name, token) do
      {:ok, :completed, response} ->
        response

      {:ok, :pending} when retries > 0 ->
        Process.sleep(20)
        await_completion(name, token, retries - 1)

      other ->
        flunk("expected completion, got: #{inspect(other)}")
    end
  end

  test "unanimous convergence on round 1", %{name: name} do
    {:ok, _} =
      start_consensus(
        name,
        [
          {"a", [say("all good.\nVERDICT: APPROVE")]},
          {"b", [say("looks fine.\nVERDICT: APPROVE")]},
          {"c", [say("i am on board.\nVERDICT: APPROVE")]}
        ],
        threshold: :unanimous,
        rounds: 3
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "merge it?", timeout: 5_000)

    assert resp.text =~ "CONSENSUS: :approve"
    assert resp.text =~ "unanimous"
    assert resp.text =~ "round 1"
    assert resp.text =~ "a [APPROVE]"
    assert resp.text =~ "all good."
  end

  test "convergence on round 2 after re-prompt", %{name: name} do
    {:ok, _} =
      start_consensus(
        name,
        [
          {"a", [say("hmm.\nVERDICT: REVISE"), say("fine fine.\nVERDICT: APPROVE")]},
          {"b", [say("looks good.\nVERDICT: APPROVE"), say("still approve.\nVERDICT: APPROVE")]}
        ],
        threshold: :unanimous,
        rounds: 3
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "merge it?", timeout: 5_000)

    assert resp.text =~ "CONSENSUS: :approve"
    assert resp.text =~ "round 2"
  end

  test "diverges at round cap", %{name: name} do
    {:ok, _} =
      start_consensus(
        name,
        [
          {"a",
           [
             say("nope.\nVERDICT: REJECT"),
             say("still nope.\nVERDICT: REJECT")
           ]},
          {"b",
           [
             say("ship it.\nVERDICT: APPROVE"),
             say("ship it twice.\nVERDICT: APPROVE")
           ]}
        ],
        threshold: :unanimous,
        rounds: 2
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "merge it?", timeout: 5_000)

    assert resp.text =~ "DIVERGED AFTER 2 ROUNDS"
    assert resp.text =~ "a [REJECT]"
    assert resp.text =~ "b [APPROVE]"
  end

  test "majority threshold (2 of 3)", %{name: name} do
    {:ok, _} =
      start_consensus(
        name,
        [
          {"a", [say("yes.\nVERDICT: APPROVE")]},
          {"b", [say("yes.\nVERDICT: APPROVE")]},
          {"c", [say("no way.\nVERDICT: REJECT")]}
        ],
        threshold: :majority,
        rounds: 2
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "merge it?", timeout: 5_000)

    assert resp.text =~ "CONSENSUS: :approve"
    assert resp.text =~ "2 of 3 agreed via majority"
  end

  test "{:at_least, n} threshold", %{name: name} do
    {:ok, _} =
      start_consensus(
        name,
        [
          {"a", [say("yes.\nVERDICT: APPROVE")]},
          {"b", [say("yes.\nVERDICT: APPROVE")]},
          {"c", [say("no.\nVERDICT: REJECT")]},
          {"d", [say("maybe.\nVERDICT: REVISE")]}
        ],
        threshold: {:at_least, 2},
        rounds: 2
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "merge it?", timeout: 5_000)

    assert resp.text =~ "CONSENSUS: :approve"
    assert resp.text =~ "at_least 2"
  end

  test "unparseable response is counted as abstain", %{name: name} do
    {:ok, _} =
      start_consensus(
        name,
        [
          {"a", [say("yes.\nVERDICT: APPROVE")]},
          {"b", [say("yes.\nVERDICT: APPROVE")]},
          # 'c' responds without a parseable verdict -- abstains
          {"c", [say("i dunno lol")]}
        ],
        threshold: :majority,
        rounds: 2
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "merge it?", timeout: 5_000)

    assert resp.text =~ "CONSENSUS: :approve"
    assert resp.text =~ "c [abstain]"
  end

  test "all abstain blocks convergence (unanimous)", %{name: name} do
    {:ok, _} =
      start_consensus(
        name,
        [
          {"a", [say("huh."), say("huh."), say("huh.")]},
          {"b", [say("what."), say("what."), say("what.")]}
        ],
        threshold: :unanimous,
        rounds: 3
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "merge it?", timeout: 5_000)

    assert resp.text =~ "DIVERGED AFTER 3 ROUNDS"
    assert resp.text =~ "a [abstain]"
    assert resp.text =~ "b [abstain]"
  end

  test "custom synthesizer receives structured data", %{name: name} do
    synth = fn summary ->
      "status=#{summary.status};verdict=#{inspect(summary.verdict)};" <>
        "rounds=#{summary.rounds};n=#{length(summary.responses)}"
    end

    {:ok, _} =
      start_consensus(
        name,
        [
          {"a", [say("yes.\nVERDICT: APPROVE")]},
          {"b", [say("yes.\nVERDICT: APPROVE")]}
        ],
        threshold: :unanimous,
        rounds: 2,
        reply: {:synthesize, synth}
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)

    assert resp.text == "status=converged;verdict=:approve;rounds=1;n=2"
  end

  test "second ask queues behind the first", %{name: name} do
    {:ok, _} =
      start_consensus(
        name,
        [
          {"a",
           [
             say("first.\nVERDICT: APPROVE"),
             say("second.\nVERDICT: APPROVE")
           ]},
          {"b",
           [
             say("first.\nVERDICT: APPROVE"),
             say("second.\nVERDICT: APPROVE")
           ]}
        ],
        threshold: :unanimous,
        rounds: 2
      )

    {:ok, t1} = GenAgentEnsemble.tell(name, "one")
    {:ok, t2} = GenAgentEnsemble.tell(name, "two")

    r1 = await_completion(name, t1)
    r2 = await_completion(name, t2)

    assert r1.text =~ "first."
    assert r2.text =~ "second."
  end

  test "agent turn error fails the token with {agent, reason}", %{name: name} do
    {:ok, _} =
      start_consensus(
        name,
        [
          {"a", [{:error, :boom}]},
          {"b", [say("ok.\nVERDICT: APPROVE")]}
        ],
        threshold: :unanimous,
        rounds: 2
      )

    assert {:error, {"a", :boom}} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)

    Process.sleep(30)
    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.phase == :idle
  end

  test "agent death halts the session", %{name: name} do
    {:ok, pid} =
      start_consensus(name, [
        {"a", [say("yes.\nVERDICT: APPROVE")]},
        {"b", [say("yes.\nVERDICT: APPROVE")]}
      ])

    ref = Process.monitor(pid)
    GenAgent.stop("#{name}/a")

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  test "status reports round progress", %{name: name} do
    {:ok, _} =
      start_consensus(name, [
        {"a", [say("yes.\nVERDICT: APPROVE")]},
        {"b", [say("yes.\nVERDICT: APPROVE")]}
      ])

    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.agents == ["a", "b"]
    assert info.threshold == :majority
    assert info.phase == :idle
    assert info.queued == 0
  end

  test "init requires :verdict_parser", %{name: name} do
    Process.flag(:trap_exit, true)

    result =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Consensus,
        opts: [
          agents: [
            {"a", TestAgent, [backend: Mock, scripts: []]},
            {"b", TestAgent, [backend: Mock, scripts: []]}
          ]
        ]
      )

    assert {:error, {%KeyError{key: :verdict_parser}, _}} = result
  end

  test "init requires 2+ agents", %{name: name} do
    Process.flag(:trap_exit, true)

    result =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Consensus,
        opts: [
          agents: [{"solo", TestAgent, [backend: Mock, scripts: []]}],
          verdict_parser: parser()
        ]
      )

    assert {:error, {%ArgumentError{message: "Consensus requires at least 2" <> _}, _}} = result
  end

  test "init rejects invalid threshold", %{name: name} do
    Process.flag(:trap_exit, true)

    result =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Consensus,
        opts: [
          agents: [
            {"a", TestAgent, [backend: Mock, scripts: []]},
            {"b", TestAgent, [backend: Mock, scripts: []]}
          ],
          verdict_parser: parser(),
          threshold: {:at_least, 99}
        ]
      )

    assert {:error, {%ArgumentError{message: "Consensus invalid :threshold" <> _}, _}} = result
  end

  test "duplicate agent names rejected", %{name: name} do
    Process.flag(:trap_exit, true)

    result =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Consensus,
        opts: [
          agents: [
            {"a", TestAgent, [backend: Mock, scripts: []]},
            {"a", TestAgent, [backend: Mock, scripts: []]}
          ],
          verdict_parser: parser()
        ]
      )

    assert {:error, {%ArgumentError{message: "Consensus duplicate agent names" <> _}, _}} = result
  end
end
