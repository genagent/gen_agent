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

  # A script that blocks when the backend consumes its stream until the test
  # sends `:release` to the pid announced as `{:reached, tag, pid}`.
  defp gated(tag, events) do
    test = self()

    fn _prompt ->
      Stream.flat_map([:gate], fn _ ->
        send(test, {:reached, tag, self()})

        receive do
          :release -> :ok
        after
          5_000 -> flunk("gate #{inspect(tag)} was never released")
        end

        events
      end)
    end
  end

  defp gated_error(tag, reason), do: gated(tag, [Event.new(:error, %{reason: reason})])

  defp gated_say(tag, text), do: gated(tag, [Event.new(:result, %{text: text})])

  defp release(tag) do
    assert_receive {:reached, ^tag, pid}, 2_000
    send(pid, :release)
  end

  defp wait_responded(name, count, retries \\ 100) do
    {:ok, info} = GenAgentEnsemble.status(name)

    case info.phase do
      %{responded: ^count} ->
        :ok

      _ when retries > 0 ->
        Process.sleep(20)
        wait_responded(name, count, retries - 1)

      other ->
        flunk("expected #{count} responses, got: #{inspect(other)}")
    end
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

  describe "tied thresholds" do
    test "2-2 split with {:at_least, 2} does not converge", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [say("x.\nVERDICT: APPROVE")]},
            {"b", [say("x.\nVERDICT: REJECT")]},
            {"c", [say("x.\nVERDICT: APPROVE")]},
            {"d", [say("x.\nVERDICT: REJECT")]}
          ],
          threshold: {:at_least, 2},
          rounds: 1
        )

      {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)
      assert resp.text =~ "DIVERGED AFTER 1 ROUND"
      refute resp.text =~ "CONSENSUS"
    end

    test "agent order does not change a tied result", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"d", [say("x.\nVERDICT: REJECT")]},
            {"c", [say("x.\nVERDICT: APPROVE")]},
            {"b", [say("x.\nVERDICT: REJECT")]},
            {"a", [say("x.\nVERDICT: APPROVE")]}
          ],
          threshold: {:at_least, 2},
          rounds: 1
        )

      {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)
      assert resp.text =~ "DIVERGED"
    end

    test "tie resolves in the next round", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [say("x.\nVERDICT: APPROVE"), say("x.\nVERDICT: APPROVE")]},
            {"b", [say("x.\nVERDICT: REJECT"), say("x.\nVERDICT: APPROVE")]},
            {"c", [say("x.\nVERDICT: APPROVE"), say("x.\nVERDICT: APPROVE")]},
            {"d", [say("x.\nVERDICT: REJECT"), say("x.\nVERDICT: REJECT")]}
          ],
          threshold: {:at_least, 2},
          rounds: 3
        )

      {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)
      assert resp.text =~ "CONSENSUS: :approve (3 of 4 agreed via at_least 2, round 2)"
    end

    test "unequal counts above a low threshold converge on the leader", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [say("x.\nVERDICT: REJECT")]},
            {"b", [say("x.\nVERDICT: APPROVE")]},
            {"c", [say("x.\nVERDICT: APPROVE")]},
            {"d", [say("x.\nVERDICT: APPROVE")]},
            {"e", [say("x.\nVERDICT: REJECT")]}
          ],
          threshold: {:at_least, 2},
          rounds: 1
        )

      {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)
      assert resp.text =~ "CONSENSUS: :approve (3 of 5"
    end
  end

  describe "turn errors" do
    test "one error is tolerated when the majority is still reachable", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [{:error, :boom}]},
            {"b", [say("x.\nVERDICT: APPROVE")]},
            {"c", [say("x.\nVERDICT: APPROVE")]}
          ],
          threshold: :majority,
          rounds: 2
        )

      {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)
      assert resp.text =~ "CONSENSUS: :approve (2 of 3 agreed via majority, round 1)"
      assert resp.text =~ "a [abstain]"
      assert resp.text =~ "boom"
    end

    test "error arriving after the votes is tolerated", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [gated_error(:a, :late)]},
            {"b", [say("x.\nVERDICT: APPROVE")]},
            {"c", [say("x.\nVERDICT: APPROVE")]}
          ],
          threshold: {:at_least, 2},
          rounds: 1
        )

      {:ok, token} = GenAgentEnsemble.tell(name, "merge?")
      wait_responded(name, 2)
      release(:a)

      assert {:ok, resp} = GenAgentEnsemble.await(name, token, 5_000)
      assert resp.text =~ "CONSENSUS: :approve"
      assert resp.text =~ "a [abstain]"
    end

    test "{:at_least, n} tolerates multiple errors while reachable", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [{:error, :one}]},
            {"b", [{:error, :two}]},
            {"c", [say("x.\nVERDICT: APPROVE")]},
            {"d", [say("x.\nVERDICT: APPROVE")]}
          ],
          threshold: {:at_least, 2},
          rounds: 1
        )

      {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)
      assert resp.text =~ "CONSENSUS: :approve (2 of 4"
    end

    test "fails with the first original error when the majority becomes impossible",
         %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [gated_error(:a, :first)]},
            {"b", [gated_error(:b, :second)]},
            {"c", [say("x.\nVERDICT: APPROVE")]}
          ],
          threshold: :majority,
          rounds: 2
        )

      {:ok, token} = GenAgentEnsemble.tell(name, "merge?")
      wait_responded(name, 1)
      release(:a)
      wait_responded(name, 2)
      release(:b)

      assert {:error, {"a", :first}} = GenAgentEnsemble.await(name, token, 5_000)

      Process.sleep(30)
      {:ok, info} = GenAgentEnsemble.status(name)
      assert info.phase == :idle
    end

    test "fails when a later response makes the threshold impossible", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [{:error, :boom}]},
            {"b", [gated_say(:b, "x.\nVERDICT: APPROVE")]},
            {"c", [gated_say(:c, "x.\nVERDICT: REJECT")]}
          ],
          threshold: :majority,
          rounds: 2
        )

      {:ok, token} = GenAgentEnsemble.tell(name, "merge?")
      wait_responded(name, 1)
      release(:b)
      wait_responded(name, 2)
      release(:c)

      assert {:error, {"a", :boom}} = GenAgentEnsemble.await(name, token, 5_000)
    end

    test "tolerated error is round-local and the agent is dispatched again", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [gated_error(:a, :boom), say("x.\nVERDICT: APPROVE")]},
            {"b", [say("x.\nVERDICT: APPROVE"), say("x.\nVERDICT: APPROVE")]},
            {"c", [say("x.\nVERDICT: REJECT"), say("x.\nVERDICT: APPROVE")]}
          ],
          threshold: {:at_least, 1},
          rounds: 2
        )

      {:ok, token} = GenAgentEnsemble.tell(name, "merge?")
      wait_responded(name, 2)
      release(:a)

      assert {:ok, resp} = GenAgentEnsemble.await(name, token, 5_000)
      assert resp.text =~ "CONSENSUS: :approve (3 of 3 agreed via at_least 1, round 2)"
    end

    test "failure does not leak into the next queued run", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [gated_error(:a, :boom), say("x.\nVERDICT: APPROVE")]},
            {"b", [say("x.\nVERDICT: APPROVE"), say("x.\nVERDICT: APPROVE")]}
          ],
          threshold: :unanimous,
          rounds: 2
        )

      {:ok, t1} = GenAgentEnsemble.tell(name, "one")
      assert_receive {:reached, :a, pid}, 2_000
      {:ok, t2} = GenAgentEnsemble.tell(name, "two")

      {:ok, info} = GenAgentEnsemble.status(name)
      assert info.queued == 1
      send(pid, :release)

      assert {:error, {"a", :boom}} = GenAgentEnsemble.await(name, t1, 5_000)
      assert {:ok, resp} = GenAgentEnsemble.await(name, t2, 5_000)
      assert resp.text =~ "CONSENSUS: :approve"
    end

    test "tolerated error keeps the custom synthesis shape", %{name: name} do
      synth = fn summary ->
        inspect(summary.responses)
      end

      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [{:error, :boom}]},
            {"b", [say("x.\nVERDICT: APPROVE")]},
            {"c", [say("x.\nVERDICT: APPROVE")]}
          ],
          threshold: :majority,
          rounds: 1,
          reply: {:synthesize, synth}
        )

      {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)
      assert resp.text =~ ~s({"a", nil, "turn error: :boom", ""})
    end
  end

  describe "typed decision metadata" do
    test "converged reply exposes decision while text stays a binary", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [say("fine.\nVERDICT: APPROVE")]},
            {"b", [say("ok.\nVERDICT: APPROVE")]},
            {"c", [say("no.\nVERDICT: REJECT")]}
          ],
          threshold: :majority,
          rounds: 1
        )

      {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)

      assert is_binary(resp.text)
      assert resp.text =~ "CONSENSUS: :approve (2 of 3 agreed via majority, round 1)"
      assert GenAgentEnsemble.IEx.text({:ok, resp}) == resp.text

      assert ExUnit.CaptureIO.capture_io(fn -> GenAgentEnsemble.IEx.puts({:ok, resp}) end) ==
               resp.text <> "\n"

      assert resp.metadata.consensus == %{
               status: :converged,
               verdict: :approve,
               rounds: 1,
               threshold: :majority,
               votes: [
                 %{agent: "a", verdict: :approve, rationale: "fine."},
                 %{agent: "b", verdict: :approve, rationale: "ok."},
                 %{agent: "c", verdict: :reject, rationale: "no."}
               ]
             }
    end

    test "diverged reply with an abstain keeps nil verdict and agent order", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [say("yes.\nVERDICT: APPROVE")]},
            {"b", [say("no.\nVERDICT: REJECT")]},
            {"c", [say("i dunno")]}
          ],
          threshold: :unanimous,
          rounds: 1
        )

      {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)

      assert resp.text =~ "DIVERGED AFTER 1 ROUND"
      c = resp.metadata.consensus
      assert %{status: :diverged, verdict: nil, rounds: 1, threshold: :unanimous} = c

      assert Enum.map(c.votes, &{&1.agent, &1.verdict}) ==
               [{"a", :approve}, {"b", :reject}, {"c", nil}]

      assert Enum.at(c.votes, 2).rationale == "i dunno"
    end

    test "custom string synthesizer keeps its text and gets metadata", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [say("yes.\nVERDICT: APPROVE")]},
            {"b", [say("yes.\nVERDICT: APPROVE")]}
          ],
          threshold: :unanimous,
          rounds: 1,
          reply: {:synthesize, fn summary -> "Decision: #{summary.verdict}" end}
        )

      {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)

      assert resp.text == "Decision: approve"
      assert %{status: :converged, verdict: :approve, rounds: 1} = resp.metadata.consensus
    end

    test "invalid synthesizer map still fails and returns no decision", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [say("yes.\nVERDICT: APPROVE")]},
            {"b", [say("yes.\nVERDICT: APPROVE")]}
          ],
          threshold: :unanimous,
          rounds: 1,
          reply: {:synthesize, fn summary -> %{verdict: summary.verdict} end}
        )

      assert {:error, {:invalid_strategy_result, :synthesizer_reply}} =
               GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)
    end

    test "usage is preserved alongside metadata", %{name: name} do
      usage_say = fn text ->
        fn _prompt ->
          [Event.new(:usage, %{input_tokens: 3}), Event.new(:result, %{text: text})]
        end
      end

      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [usage_say.("x.\nVERDICT: APPROVE")]},
            {"b", [usage_say.("x.\nVERDICT: APPROVE")]}
          ],
          threshold: :unanimous,
          rounds: 1
        )

      {:ok, resp} = GenAgentEnsemble.ask(name, "merge?", timeout: 5_000)

      assert resp.usage.input_tokens == 6
      assert resp.metadata.consensus.status == :converged
    end

    test "queued turns carry their own decision", %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [say("one.\nVERDICT: APPROVE"), say("two.\nVERDICT: REJECT")]},
            {"b", [say("one.\nVERDICT: APPROVE"), say("two.\nVERDICT: REJECT")]}
          ],
          threshold: :unanimous,
          rounds: 1
        )

      {:ok, t1} = GenAgentEnsemble.tell(name, "one")
      {:ok, t2} = GenAgentEnsemble.tell(name, "two")

      r1 = await_completion(name, t1)
      r2 = await_completion(name, t2)

      assert r1.metadata.consensus.verdict == :approve
      assert r2.metadata.consensus.verdict == :reject
      assert Enum.map(r2.metadata.consensus.votes, & &1.rationale) == ["two.", "two."]
    end

    test "failed turn returns an error and the next turn has only its own decision",
         %{name: name} do
      {:ok, _} =
        start_consensus(
          name,
          [
            {"a", [gated_error(:a, :boom), say("x.\nVERDICT: APPROVE")]},
            {"b", [say("x.\nVERDICT: APPROVE"), say("x.\nVERDICT: APPROVE")]}
          ],
          threshold: :unanimous,
          rounds: 1
        )

      {:ok, t1} = GenAgentEnsemble.tell(name, "one")
      assert_receive {:reached, :a, pid}, 2_000
      {:ok, t2} = GenAgentEnsemble.tell(name, "two")
      send(pid, :release)

      assert {:error, {"a", :boom}} = GenAgentEnsemble.await(name, t1, 5_000)
      assert {:ok, resp} = GenAgentEnsemble.await(name, t2, 5_000)
      assert resp.metadata.consensus.status == :converged
      assert Enum.all?(resp.metadata.consensus.votes, &(&1.verdict == :approve))
    end
  end

  test "agent death halts the session", %{name: name} do
    {:ok, pid} =
      start_consensus(name, [
        {"a", [say("yes.\nVERDICT: APPROVE")]},
        {"b", [say("yes.\nVERDICT: APPROVE")]}
      ])

    ref = Process.monitor(pid)
    Process.exit(GenAgent.whereis("#{name}/a"), :kill)

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

    assert {:error, {:init_failed, :error, KeyError}} = result
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

    assert {:error, {:init_failed, :error, ArgumentError}} = result
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

    assert {:error, {:init_failed, :error, ArgumentError}} = result
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

    assert {:error, {:init_failed, :error, ArgumentError}} = result
  end
end
