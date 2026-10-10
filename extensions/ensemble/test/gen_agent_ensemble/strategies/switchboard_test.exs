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

    for token <- [t1, t2, t3] do
      assert {:ok, %{text: _}} = GenAgentEnsemble.await(name, token, 5_000)
    end

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

    assert {:ok, %{text: "alice:qa"}} = GenAgentEnsemble.await(name, ta, 5_000)
    assert {:ok, %{text: "bob:qb"}} = GenAgentEnsemble.await(name, tb, 5_000)

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

    assert {:error, {:init_failed, :error, ArgumentError}} = result
  end

  test "last-agent-dies halts the session", %{name: name} do
    {:ok, pid} = start_session(name, [{"alice", [echo("alice")]}])
    ref = Process.monitor(pid)

    Process.exit(GenAgent.whereis("#{name}/alice"), :kill)

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  test "idle agent death removes only that agent; survivor keeps serving", %{name: name} do
    {:ok, pid} =
      start_session(name, [
        {"alice", [echo("alice")]},
        {"bob", [echo("bob"), echo("bob")]}
      ])

    session = Process.monitor(pid)

    Process.exit(GenAgent.whereis("#{name}/alice"), :kill)

    info = await_fleet(name, ["bob"])
    assert info.pending_per_agent == %{"bob" => 0}

    assert {:error, {:unknown_agent, "alice"}} =
             GenAgentEnsemble.ask(name, "hi", agent: "alice")

    {:ok, token} = GenAgentEnsemble.tell(name, "later", agent: "alice")
    assert {:error, {:unknown_agent, "alice"}} = GenAgentEnsemble.await(name, token, 5_000)

    assert {:ok, %{text: "bob:one"}} = GenAgentEnsemble.ask(name, "one", agent: "bob")
    assert {:ok, %{text: "bob:two"}} = GenAgentEnsemble.ask(name, "two", agent: "bob")
    assert Process.alive?(pid)
    refute_received {:DOWN, ^session, :process, _, _}
  end

  test "busy agent death fails running and queued tokens; survivor keeps serving", %{name: name} do
    alice =
      {"alice", GenAgentEnsemble.ControlledAgent,
       [backend: GenAgentEnsemble.ControlledBackend, observer: self(), tag: "alice"]}

    {:ok, pid} =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Switchboard,
        opts: [agents: [alice, {"bob", TestAgent, [backend: Mock, scripts: [echo("bob")]]}]]
      )

    session = Process.monitor(pid)

    {:ok, running} = GenAgentEnsemble.tell(name, "first", agent: "alice")
    assert_receive {:controlled_prompt, "alice", "first", task}, 2_000
    task_ref = Process.monitor(task)
    {:ok, queued} = GenAgentEnsemble.tell(name, "second", agent: "alice")

    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.pending_per_agent["alice"] == 2

    Process.exit(GenAgent.whereis("#{name}/alice"), :kill)

    assert {:error, {:agent_down, :killed}} = GenAgentEnsemble.await(name, running, 5_000)
    assert {:error, {:agent_down, :killed}} = GenAgentEnsemble.await(name, queued, 5_000)

    # Release the test backend explicitly; agent death is not a claim that
    # every external provider task has settled.
    send(task, {:result, "discarded after agent death"})
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 2_000

    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.agents == ["bob"]
    assert info.pending_per_agent == %{"bob" => 0}

    assert {:error, {:unknown_agent, "alice"}} =
             GenAgentEnsemble.ask(name, "again", agent: "alice")

    assert {:ok, %{text: "bob:alive"}} = GenAgentEnsemble.ask(name, "alive", agent: "bob")
    assert Process.alive?(pid)
    refute_received {:DOWN, ^session, :process, _, _}
  end

  # The Server learns of a death through its own monitor, which is not ordered
  # against the test's view, so observe the removal with a bounded deadline.
  defp await_fleet(name, agents) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_fleet(name, agents, deadline)
  end

  defp await_fleet(name, agents, deadline) do
    {:ok, info} = GenAgentEnsemble.status(name)

    cond do
      info.agents == agents ->
        info

      System.monotonic_time(:millisecond) > deadline ->
        flunk("fleet never became #{inspect(agents)}: #{inspect(info)}")

      true ->
        receive do
        after
          1 -> await_fleet(name, agents, deadline)
        end
    end
  end
end
