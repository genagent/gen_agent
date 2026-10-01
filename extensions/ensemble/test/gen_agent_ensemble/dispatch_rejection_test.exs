defmodule GenAgentEnsemble.DispatchRejectionTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.{Consensus, Pipeline, Pool, Solo, Switchboard}

  defmodule MissingAgentStrategy do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(opts) do
      {:ok, %{token: nil}, Keyword.fetch!(opts, :agents)}
    end

    @impl true
    def handle_tell(prompt, opts, token, state), do: dispatch(prompt, opts, token, state)

    @impl true
    def handle_ask(prompt, opts, token, state), do: dispatch(prompt, opts, token, state)

    @impl true
    def handle_response(_agent, response, %{token: token} = state) do
      {:ok, [{:reply, token, response}], %{state | token: nil}}
    end

    defp dispatch(prompt, opts, token, state) do
      agent = Keyword.get(opts, :agent, "missing")
      {:ok, [{:dispatch, agent, prompt, token}], %{state | token: token}}
    end
  end

  setup do
    name = "rejection-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case Registry.lookup(GenAgentEnsemble.Registry, name) do
        [{server, _}] -> if Process.alive?(server), do: Ensemble.stop(name)
        [] -> :ok
      end
    end)

    {:ok, name: name}
  end

  defp agent(tag) do
    {tag, ControlledAgent,
     [backend: ControlledBackend, observer: self(), tag: tag, max_pending_prompts: 0]}
  end

  defp ask_async(name, prompt, opts \\ []) do
    Task.async(fn -> Ensemble.ask(name, prompt, opts) end)
  end

  defp await_poll(name, token, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    case Ensemble.poll(name, token) do
      {:ok, :pending} ->
        if System.monotonic_time(:millisecond) < deadline,
          do: await_poll(name, token, deadline),
          else: flunk("token #{token} did not complete")

      result ->
        result
    end
  end

  test "Solo closes rejected tell, retains earlier ask, and serves a later ask", %{name: name} do
    {:ok, _} = Ensemble.start_link(name: name, strategy: Solo, opts: [agent: agent("solo")])

    first = ask_async(name, "first")
    assert_receive {:controlled_prompt, "solo", "first", first_task}

    {:ok, rejected} = Ensemble.tell(name, "rejected")
    assert {:error, {:overloaded, _}} = Ensemble.poll(name, rejected)
    assert {:ok, %{queued_tokens: 1}} = Ensemble.status(name)

    send(first_task, {:result, "FIRST"})
    assert {:ok, %{text: "FIRST"}} = Task.await(first)

    later = ask_async(name, "later")
    assert_receive {:controlled_prompt, "solo", "later", later_task}
    send(later_task, {:result, "LATER"})
    assert {:ok, %{text: "LATER"}} = Task.await(later)
    assert {:ok, %{queued_tokens: 0}} = Ensemble.status(name)
  end

  test "missing sub-agent rejects ask and tell without killing the session", %{name: name} do
    {:ok, server} =
      Ensemble.start_link(
        name: name,
        strategy: MissingAgentStrategy,
        opts: [
          agents: [{"live", ControlledAgent, [backend: ControlledBackend, observer: self()]}]
        ]
      )

    unavailable = {:dispatch_rejected, "missing", {:agent_not_running, "missing"}}

    assert {:error, ^unavailable} = Ensemble.ask(name, "missing ask")
    {:ok, token} = Ensemble.tell(name, "missing tell")
    assert {:error, ^unavailable} = Ensemble.poll(name, token)
    assert Process.alive?(server)
    assert {:ok, %{pending_tokens: []}} = Ensemble.status(name)

    live = ask_async(name, "working", agent: "live")
    assert_receive {:controlled_prompt, _, "working", task}, 2_000
    send(task, {:result, "WORKS"})
    assert {:ok, %{text: "WORKS"}} = Task.await(live)
  end

  test "dead sub-agent rejects dispatch while another worker remains usable", %{name: name} do
    agents =
      for tag <- ["live", "dead"] do
        {tag, ControlledAgent, [backend: ControlledBackend, observer: self(), tag: tag]}
      end

    {:ok, server} =
      Ensemble.start_link(name: name, strategy: MissingAgentStrategy, opts: [agents: agents])

    [{dead, _}] = Registry.lookup(GenAgent.Registry, "#{name}/dead")
    monitor = Process.monitor(dead)
    Process.exit(dead, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :killed}, 2_000

    assert {:error, {:dispatch_rejected, "dead", {:agent_not_running, "dead"}}} =
             Ensemble.ask(name, "dead ask", agent: "dead")

    live = ask_async(name, "working", agent: "live")
    assert_receive {:controlled_prompt, "live", "working", task}, 2_000
    send(task, {:result, "WORKS"})
    assert {:ok, %{text: "WORKS"}} = Task.await(live)
    assert Process.alive?(server)
  end

  test "Switchboard removes only the rejected token from its agent queue", %{name: name} do
    {:ok, _} =
      Ensemble.start_link(name: name, strategy: Switchboard, opts: [agents: [agent("a")]])

    first = ask_async(name, "first", agent: "a")
    assert_receive {:controlled_prompt, "a", "first", first_task}

    rejected = ask_async(name, "rejected", agent: "a")
    assert {:error, {:overloaded, _}} = Task.await(rejected)
    assert {:ok, %{pending_per_agent: %{"a" => 1}}} = Ensemble.status(name)

    send(first_task, {:result, "FIRST"})
    assert {:ok, %{text: "FIRST"}} = Task.await(first)

    later = ask_async(name, "later", agent: "a")
    assert_receive {:controlled_prompt, "a", "later", later_task}
    send(later_task, {:result, "LATER"})
    assert {:ok, %{text: "LATER"}} = Task.await(later)
  end

  test "Pool releases a worker after rejected dispatch", %{name: name} do
    {:ok, _} =
      Ensemble.start_link(
        name: name,
        strategy: Pool,
        opts: [
          worker_count: 1,
          worker_template: {"worker", ControlledAgent, elem(agent("worker"), 2)}
        ]
      )

    external = Task.async(fn -> GenAgent.ask("#{name}/worker-1", "external") end)
    assert_receive {:controlled_prompt, "worker", "external", external_task}

    {:ok, rejected} = Ensemble.tell(name, "rejected")
    assert {:error, {:overloaded, _}} = Ensemble.poll(name, rejected)
    assert {:ok, %{free: 1, busy: 0, queued: 0}} = Ensemble.status(name)

    send(external_task, {:result, "EXTERNAL"})
    assert {:ok, %{text: "EXTERNAL"}} = Task.await(external)

    later = ask_async(name, "later")
    assert_receive {:controlled_prompt, "worker", "later", later_task}
    send(later_task, {:result, "LATER"})
    assert {:ok, %{text: "LATER"}} = Task.await(later)
  end

  test "Pipeline aborts a rejected stage and admits the next run", %{name: name} do
    {:ok, _} =
      Ensemble.start_link(
        name: name,
        strategy: Pipeline,
        opts: [stages: [agent("first"), agent("second")]]
      )

    external = Task.async(fn -> GenAgent.ask("#{name}/second", "external") end)
    assert_receive {:controlled_prompt, "second", "external", external_task}

    failed = ask_async(name, "failed")
    assert_receive {:controlled_prompt, "first", "failed", first_task}
    {:ok, later} = Ensemble.tell(name, "later")
    assert {:ok, %{queued: 1}} = Ensemble.status(name)
    send(first_task, {:result, "NEXT_STAGE"})
    assert {:error, {"second", {:overloaded, _}}} = Task.await(failed)
    assert_receive {:controlled_prompt, "first", "later", later_first}
    assert {:ok, %{phase: {:in_stage, "first"}, queued: 0}} = Ensemble.status(name)

    send(external_task, {:result, "EXTERNAL"})
    assert {:ok, %{text: "EXTERNAL"}} = Task.await(external)

    send(later_first, {:result, "TO_SECOND"})
    assert_receive {:controlled_prompt, "second", "TO_SECOND", later_second}
    send(later_second, {:result, "DONE"})
    assert {:ok, :completed, %{text: "DONE"}} = await_poll(name, later)
  end

  test "Consensus fanout rejection discards accepted peer response and resets phase", %{
    name: name
  } do
    {:ok, _} =
      Ensemble.start_link(
        name: name,
        strategy: Consensus,
        opts: [agents: [agent("a"), agent("b")], rounds: 1, verdict_parser: &{:ok, :yes, &1}]
      )

    external = Task.async(fn -> GenAgent.ask("#{name}/b", "external") end)
    assert_receive {:controlled_prompt, "b", "external", external_task}

    failed = ask_async(name, "failed")
    assert_receive {:controlled_prompt, "a", "failed", peer_task}
    assert {:error, {"b", {:overloaded, _}}} = Task.await(failed)
    assert {:ok, %{phase: :idle, queued: 0}} = Ensemble.status(name)

    send(peer_task, {:result, "STALE"})
    send(external_task, {:result, "EXTERNAL"})
    assert {:ok, %{text: "EXTERNAL"}} = Task.await(external)

    later = ask_async(name, "later")
    assert_receive {:controlled_prompt, "a", "later", later_a}
    assert_receive {:controlled_prompt, "b", "later", later_b}
    send(later_a, {:result, "A"})
    send(later_b, {:result, "B"})
    assert {:ok, %{text: text}} = Task.await(later)
    assert text =~ "A"
    assert text =~ "B"
    refute text =~ "STALE"
  end
end
