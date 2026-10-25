defmodule GenAgentEnsemble.Strategies.SoloTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.HaltSupport
  alias GenAgentEnsemble.Strategies.Solo
  alias GenAgentEnsemble.TestAgent

  setup do
    name = "solo-#{System.unique_integer([:positive])}"
    agent_name = "#{name}-a"
    on_exit(fn -> safe_stop(name) end)
    %{name: name, agent_name: agent_name}
  end

  defp safe_stop(name) do
    GenAgentEnsemble.stop(name)
  catch
    :exit, _ -> :ok
  end

  defp start_session(name, agent_name, scripts) do
    agent_opts = [backend: Mock, scripts: scripts]

    GenAgentEnsemble.start_link(
      name: name,
      strategy: Solo,
      opts: [agent: {agent_name, TestAgent, agent_opts}]
    )
  end

  test "tell + poll round trip", %{name: name, agent_name: agent_name} do
    {:ok, _} =
      start_session(name, agent_name, [
        [Event.new(:result, %{text: "hello"})]
      ])

    {:ok, token} = GenAgentEnsemble.tell(name, "say hi")

    response = await_completion(name, token)
    assert response.text == "hello"
  end

  test "ask blocks until the response lands", %{name: name, agent_name: agent_name} do
    {:ok, _} =
      start_session(name, agent_name, [
        fn prompt -> [Event.new(:result, %{text: "you said: #{prompt}"})] end
      ])

    {:ok, response} = GenAgentEnsemble.ask(name, "hello there", timeout: 5_000)
    assert response.text == "you said: hello there"
  end

  test "poll returns :not_found for unknown token", %{name: name, agent_name: agent_name} do
    {:ok, _} = start_session(name, agent_name, [])
    assert {:error, :not_found} = GenAgentEnsemble.poll(name, "tok-bogus")
  end

  test "multiple tells in FIFO order", %{name: name, agent_name: agent_name} do
    {:ok, _} =
      start_session(name, agent_name, [
        [Event.new(:result, %{text: "r1"})],
        [Event.new(:result, %{text: "r2"})],
        [Event.new(:result, %{text: "r3"})]
      ])

    {:ok, t1} = GenAgentEnsemble.tell(name, "p1")
    {:ok, t2} = GenAgentEnsemble.tell(name, "p2")
    {:ok, t3} = GenAgentEnsemble.tell(name, "p3")

    assert %{text: "r1"} = await_completion(name, t1)
    assert %{text: "r2"} = await_completion(name, t2)
    assert %{text: "r3"} = await_completion(name, t3)
  end

  test "turn error closes the pending token with {:error, reason}",
       %{name: name, agent_name: agent_name} do
    {:ok, _} = start_session(name, agent_name, [{:error, :boom}])

    {:ok, token} = GenAgentEnsemble.tell(name, "will fail")
    assert {:error, :boom} = await_error(name, token)
  end

  test "ask returns {:error, reason} when the turn fails",
       %{name: name, agent_name: agent_name} do
    {:ok, _} = start_session(name, agent_name, [{:error, :nope}])
    assert {:error, :nope} = GenAgentEnsemble.ask(name, "fail me", timeout: 5_000)
  end

  test "halt op fails pending tokens and leaves a halted session",
       %{name: name, agent_name: _agent_name} do
    defmodule HaltOnTell do
      @behaviour GenAgentEnsemble.Strategy

      @impl true
      def init(_), do: {:ok, nil, []}

      @impl true
      def handle_tell(_p, _o, _token, state),
        do: {:ok, [{:halt, :test_halt}], state}

      @impl true
      def handle_ask(_p, _o, _t, state), do: {:ok, [], state}

      @impl true
      def handle_response(_a, _r, state), do: {:ok, [], state}
    end

    halted = "#{name}-halt"

    {:ok, pid} =
      GenAgentEnsemble.start_link(
        name: halted,
        strategy: HaltOnTell,
        opts: []
      )

    on_exit(fn -> safe_stop(halted) end)
    watched = HaltSupport.watch(pid)

    # The tell that triggers the halt was accepted; its result is the halt error.
    {:ok, token} = GenAgentEnsemble.tell(halted, "bye")
    HaltSupport.assert_tree_gone(watched)

    assert Registry.lookup(GenAgentEnsemble.Registry, halted) == [{pid, nil}]
    assert GenAgentEnsemble.await(halted, token, 0) == {:error, {:halted, :test_halt}}
    assert GenAgentEnsemble.await(halted, token, 0) == {:error, {:halted, :test_halt}}
    assert GenAgentEnsemble.poll(halted, token) == {:error, {:halted, :test_halt}}
    assert GenAgentEnsemble.poll(halted, token) == {:error, :not_found}
    HaltSupport.assert_halted(halted, :test_halt)

    assert :ok = GenAgentEnsemble.stop(halted)
    assert Registry.lookup(GenAgentEnsemble.Registry, halted) == []
  end

  test "status surfaces strategy-specific info", %{name: name, agent_name: agent_name} do
    {:ok, _} = start_session(name, agent_name, [])
    {:ok, info} = GenAgentEnsemble.status(name)

    assert info.session == name
    assert info.strategy == Solo
    assert info.agents == [agent_name]
    assert info.agent == agent_name
    assert info.queued_tokens == 0
  end

  defp await_completion(name, token) do
    assert {:ok, response} = GenAgentEnsemble.await(name, token, 5_000)
    response
  end

  defp await_error(name, token) do
    assert {:error, _} = err = GenAgentEnsemble.await(name, token, 5_000)
    err
  end
end
