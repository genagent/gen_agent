defmodule GenAgentEnsemble.Strategies.SwitchboardTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.Strategies.Switchboard
  alias GenAgentEnsemble.TestAgent

  setup do
    name = "sw-#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(name) end)
    %{name: name}
  end

  defp safe_stop(name) do
    GenAgentEnsemble.stop(name)
  catch
    :exit, _ -> :ok
  end

  defp start_session(name, agent_specs) do
    agents =
      for {sub_name, scripts} <- agent_specs do
        {sub_name, TestAgent, [backend: Mock, scripts: scripts]}
      end

    GenAgentEnsemble.start_link(
      name: name,
      strategy: Switchboard,
      opts: [agents: agents]
    )
  end

  defp echo(label), do: fn prompt -> [Event.new(:result, %{text: "#{label}:#{prompt}"})] end

  test "routes prompts by :agent opt", %{name: name} do
    {:ok, _} =
      start_session(name, [
        {"alice", [echo("alice")]},
        {"bob", [echo("bob")]}
      ])

    assert {:ok, %{text: "alice:hi"}} =
             GenAgentEnsemble.ask(name, "hi", agent: "alice")

    assert {:ok, %{text: "bob:hi"}} = GenAgentEnsemble.ask(name, "hi", agent: "bob")
  end

  test "fails loud when no agent is specified", %{name: name} do
    {:ok, _} = start_session(name, [{"alice", [echo("alice")]}])

    assert {:error, :no_agent_specified} = GenAgentEnsemble.ask(name, "hi")
  end

  test "fails loud on unknown agent", %{name: name} do
    {:ok, _} = start_session(name, [{"alice", [echo("alice")]}])

    assert {:error, {:unknown_agent, "carol"}} =
             GenAgentEnsemble.ask(name, "hi", agent: "carol")
  end

  test "serializes multiple tells to the same agent in FIFO order", %{name: name} do
    {:ok, _} =
      start_session(name, [
        {"alice",
         [
           echo("alice-1"),
           echo("alice-2"),
           echo("alice-3")
         ]}
      ])

    {:ok, t1} = GenAgentEnsemble.tell(name, "q1", agent: "alice")
    {:ok, t2} = GenAgentEnsemble.tell(name, "q2", agent: "alice")
    {:ok, t3} = GenAgentEnsemble.tell(name, "q3", agent: "alice")

    Process.sleep(100)

    {:ok, inbox} = GenAgentEnsemble.inbox(name)
    results = Map.new(inbox, fn {tok, {:ok, %{text: text}}} -> {tok, text} end)

    assert results[t1] == "alice-1:q1"
    assert results[t2] == "alice-2:q2"
    assert results[t3] == "alice-3:q3"
  end

  test "parallel tells to different agents don't interfere", %{name: name} do
    {:ok, _} =
      start_session(name, [
        {"alice", [echo("alice")]},
        {"bob", [echo("bob")]}
      ])

    {:ok, ta} = GenAgentEnsemble.tell(name, "qa", agent: "alice")
    {:ok, tb} = GenAgentEnsemble.tell(name, "qb", agent: "bob")

    Process.sleep(50)

    {:ok, inbox} = GenAgentEnsemble.inbox(name)
    results = Map.new(inbox, fn {tok, {:ok, %{text: text}}} -> {tok, text} end)

    assert results[ta] == "alice:qa"
    assert results[tb] == "bob:qb"
  end

  test "agent turn error fails the token; other agents unaffected", %{name: name} do
    {:ok, _} =
      start_session(name, [
        {"alice", [{:error, :boom}]},
        {"bob", [echo("bob")]}
      ])

    assert {:error, :boom} = GenAgentEnsemble.ask(name, "bad", agent: "alice")
    assert {:ok, %{text: "bob:ok"}} = GenAgentEnsemble.ask(name, "ok", agent: "bob")
  end

  test "status reports agents and pending counts", %{name: name} do
    {:ok, _} =
      start_session(name, [
        {"alice", [echo("alice")]},
        {"bob", [echo("bob")]}
      ])

    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.agents == ["alice", "bob"]
    assert info.pending_per_agent == %{"alice" => 0, "bob" => 0}
  end

  test "duplicate agent names at init fail start_link", %{name: name} do
    Process.flag(:trap_exit, true)

    result =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Switchboard,
        opts: [
          agents: [
            {"alice", TestAgent, [backend: Mock, scripts: []]},
            {"alice", TestAgent, [backend: Mock, scripts: []]}
          ]
        ]
      )

    assert {:error, {%ArgumentError{message: "Switchboard duplicate agents: " <> _}, _}} = result
  end

  test "last-agent-dies halts the session", %{name: name} do
    {:ok, pid} = start_session(name, [{"alice", [echo("alice")]}])
    ref = Process.monitor(pid)

    GenAgent.stop("#{name}/alice")

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end
end
