defmodule GenAgentEnsemble.Strategies.DebateTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.Strategies.Debate
  alias GenAgentEnsemble.TestAgent

  setup do
    name = "debate-#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(name) end)
    %{name: name}
  end

  defp safe_stop(name) do
    GenAgentEnsemble.stop(name)
  catch
    :exit, _ -> :ok
  end

  defp start_debate(name, agent_scripts, extra_opts \\ []) do
    agents =
      for {sub_name, scripts} <- agent_scripts do
        {sub_name, TestAgent, [backend: Mock, scripts: scripts]}
      end

    GenAgentEnsemble.start_link(
      name: name,
      strategy: Debate,
      opts: Keyword.put(extra_opts, :agents, agents)
    )
  end

  defp reply(text), do: fn _prompt -> [Event.new(:result, %{text: text})] end

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

  test "runs to the round cap and returns full transcript", %{name: name} do
    {:ok, _} =
      start_debate(
        name,
        [
          {"alice", [reply("a1"), reply("a2")]},
          {"bob", [reply("b1"), reply("b2")]}
        ],
        rounds: 4
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "topic", timeout: 5_000)

    assert resp.text == "alice:\na1\n\nbob:\nb1\n\nalice:\na2\n\nbob:\nb2"
  end

  test "each agent sees the previous agent's response as its prompt", %{name: name} do
    alice_agent = :ets.new(:alice_prompts, [:public, :set])
    bob_agent = :ets.new(:bob_prompts, [:public, :set])

    record = fn table, label, reply_text ->
      fn prompt ->
        :ets.insert(table, {System.unique_integer([:monotonic]), prompt})
        [Event.new(:result, %{text: "#{label}:#{reply_text}"})]
      end
    end

    {:ok, _} =
      start_debate(
        name,
        [
          {"alice", [record.(alice_agent, "a", "x1"), record.(alice_agent, "a", "x2")]},
          {"bob", [record.(bob_agent, "b", "y1"), record.(bob_agent, "b", "y2")]}
        ],
        rounds: 4
      )

    {:ok, _} = GenAgentEnsemble.ask(name, "opening", timeout: 5_000)

    alice_prompts = :ets.tab2list(alice_agent) |> Enum.sort() |> Enum.map(&elem(&1, 1))
    bob_prompts = :ets.tab2list(bob_agent) |> Enum.sort() |> Enum.map(&elem(&1, 1))

    assert alice_prompts == ["opening", "b:y1"]
    assert bob_prompts == ["a:x1", "a:x2"]
  end

  test "converge fn ends the debate early", %{name: name} do
    {:ok, _} =
      start_debate(
        name,
        [
          {"alice", [reply("argue"), reply("rebut")]},
          {"bob", [reply("AGREED on point X"), reply("should-not-reach")]}
        ],
        rounds: 10,
        converge: &String.contains?(&1, "AGREED")
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "topic", timeout: 5_000)

    # alice's turn 1 then bob's turn 2 (converges): 2 turns total.
    assert resp.text == "alice:\nargue\n\nbob:\nAGREED on point X"
  end

  test "converge is NOT checked on the first turn", %{name: name} do
    # Alice's turn-1 text contains "AGREED", but converge is only
    # checked from turn 2 onwards. Debate continues to bob's reply.
    # rounds: 2 halts by round cap so bob's script doesn't need
    # more than one entry.
    {:ok, _} =
      start_debate(
        name,
        [
          {"alice", [reply("AGREED immediately")]},
          {"bob", [reply("here is my counterpoint")]}
        ],
        rounds: 2,
        converge: &String.contains?(&1, "AGREED")
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "topic", timeout: 5_000)

    assert resp.text =~ "alice:\nAGREED immediately"
    assert resp.text =~ "bob:\nhere is my counterpoint"
  end

  test ":first controls who starts", %{name: name} do
    {:ok, _} =
      start_debate(
        name,
        [
          {"alice", [reply("a1")]},
          {"bob", [reply("b1")]}
        ],
        first: "bob",
        rounds: 2
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "topic", timeout: 5_000)

    assert resp.text == "bob:\nb1\n\nalice:\na1"
  end

  test ":reply :last returns only the last agent's text", %{name: name} do
    {:ok, _} =
      start_debate(
        name,
        [
          {"alice", [reply("a1")]},
          {"bob", [reply("b1-final")]}
        ],
        rounds: 2,
        reply: :last
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "topic", timeout: 5_000)

    assert resp.text == "b1-final"
  end

  test ":reply {:synthesize, fn} gets the structured transcript", %{name: name} do
    synth = fn transcript ->
      count = length(transcript)
      "count=#{count};" <> Enum.map_join(transcript, "|", fn {a, t} -> "#{a}=#{t}" end)
    end

    {:ok, _} =
      start_debate(
        name,
        [
          {"alice", [reply("a1")]},
          {"bob", [reply("b1")]}
        ],
        rounds: 2,
        reply: {:synthesize, synth}
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "topic", timeout: 5_000)

    assert resp.text == "count=2;alice=a1|bob=b1"
  end

  test "agent turn error fails the token and resets to idle", %{name: name} do
    {:ok, _} =
      start_debate(
        name,
        [
          {"alice", [{:error, :boom}]},
          {"bob", []}
        ],
        rounds: 4
      )

    assert {:error, :boom} = GenAgentEnsemble.ask(name, "topic", timeout: 5_000)

    Process.sleep(30)
    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.phase == :idle
  end

  test "second tell queues behind the first", %{name: name} do
    {:ok, _} =
      start_debate(
        name,
        [
          {"alice", [reply("a1"), reply("a2")]},
          {"bob", [reply("b1"), reply("b2")]}
        ],
        rounds: 2
      )

    {:ok, t1} = GenAgentEnsemble.tell(name, "first topic")
    {:ok, t2} = GenAgentEnsemble.tell(name, "second topic")

    assert %{text: "alice:\na1\n\nbob:\nb1"} = await_completion(name, t1)
    assert %{text: "alice:\na2\n\nbob:\nb2"} = await_completion(name, t2)
  end

  test "agent death halts the session", %{name: name} do
    {:ok, pid} =
      start_debate(name, [
        {"alice", [reply("a1")]},
        {"bob", [reply("b1")]}
      ])

    ref = Process.monitor(pid)
    GenAgent.stop("#{name}/alice")

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  test "status reports debate shape", %{name: name} do
    {:ok, _} =
      start_debate(
        name,
        [
          {"alice", [reply("a1")]},
          {"bob", [reply("b1")]}
        ],
        rounds: 3
      )

    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.agents == ["alice", "bob"]
    assert info.first == "alice"
    assert info.rounds == 3
    assert info.phase == :idle
    assert info.queued == 0
  end

  test "exactly 2 agents required -- 1 agent raises", %{name: name} do
    Process.flag(:trap_exit, true)

    result =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Debate,
        opts: [
          agents: [{"solo", TestAgent, [backend: Mock, scripts: []]}]
        ]
      )

    assert {:error, {%ArgumentError{message: "Debate requires exactly 2 agents" <> _}, _}} =
             result
  end

  test "exactly 2 agents required -- 3 agents raises", %{name: name} do
    Process.flag(:trap_exit, true)

    result =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Debate,
        opts: [
          agents: [
            {"a", TestAgent, [backend: Mock, scripts: []]},
            {"b", TestAgent, [backend: Mock, scripts: []]},
            {"c", TestAgent, [backend: Mock, scripts: []]}
          ]
        ]
      )

    assert {:error, {%ArgumentError{message: "Debate requires exactly 2 agents" <> _}, _}} =
             result
  end

  test "distinct names required", %{name: name} do
    Process.flag(:trap_exit, true)

    result =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Debate,
        opts: [
          agents: [
            {"alice", TestAgent, [backend: Mock, scripts: []]},
            {"alice", TestAgent, [backend: Mock, scripts: []]}
          ]
        ]
      )

    assert {:error, {%ArgumentError{message: "Debate agent names must be distinct" <> _}, _}} =
             result
  end

  test ":first must be one of the agents", %{name: name} do
    Process.flag(:trap_exit, true)

    result =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Debate,
        opts: [
          agents: [
            {"alice", TestAgent, [backend: Mock, scripts: []]},
            {"bob", TestAgent, [backend: Mock, scripts: []]}
          ],
          first: "carol"
        ]
      )

    assert {:error, {%ArgumentError{message: "Debate :first must be one of" <> _}, _}} = result
  end
end
