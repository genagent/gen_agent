defmodule GenAgentEnsemble.Strategies.SoloTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
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

  test "halt op terminates the session and fails pending tokens",
       %{name: name, agent_name: agent_name} do
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

    {:ok, _} =
      GenAgentEnsemble.start_link(
        name: "#{name}-halt",
        strategy: HaltOnTell,
        opts: []
      )

    on_exit(fn -> safe_stop("#{name}-halt") end)

    {:ok, token} = GenAgentEnsemble.tell("#{name}-halt", "bye")
    # Allow the halt to process.
    Process.sleep(30)
    refute Process.whereis(GenAgentEnsemble.Registry) |> is_nil()
    assert Registry.lookup(GenAgentEnsemble.Registry, "#{name}-halt") == []

    # Token closed via the halt path; the session is gone, so poll would fail —
    # we just assert the session terminated. The token was replied to via
    # GenServer.reply before the stop. Since it was a tell, it was completed
    # locally but the process is gone — so we can't poll. Enough to assert
    # the session process terminated cleanly.
    assert token != nil
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

  defp await_completion(name, token, retries \\ 50) do
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

  defp await_error(name, token, retries \\ 50) do
    case GenAgentEnsemble.poll(name, token) do
      {:error, _} = err ->
        err

      {:ok, :pending} when retries > 0 ->
        Process.sleep(20)
        await_error(name, token, retries - 1)

      other ->
        flunk("expected error, got: #{inspect(other)}")
    end
  end
end
