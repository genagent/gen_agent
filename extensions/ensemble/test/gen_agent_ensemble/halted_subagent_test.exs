defmodule GenAgentEnsemble.HaltedSubagentTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.Strategies.{Pipeline, Pool, Solo, Switchboard}

  defmodule HaltAgent do
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, Keyword.take(opts, [:scripts]), %{}}

    @impl true
    def pre_turn("halt", state), do: {:halt, state}
    def pre_turn(prompt, state), do: {:ok, prompt, state}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  setup do
    name = "halted-subagent-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        GenAgentEnsemble.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    %{name: name}
  end

  test "Solo closes a token dispatched to a halted member", %{name: name} do
    agent = "member"
    {:ok, _} = start(name, Solo, agent: spec(agent))
    halt_member(name, agent)

    assert {:error, :halted} = GenAgentEnsemble.ask(name, "work", timeout: 2_000)
    assert {:ok, info} = GenAgentEnsemble.status(name)
    assert info.queued_tokens == 0
  end

  test "Pipeline fails the halted stage and drains its own next token", %{name: name} do
    stages = [spec("first"), spec("second")]
    {:ok, _} = start(name, Pipeline, stages: stages)
    halt_member(name, "second")

    assert {:error, {"second", :halted}} = GenAgentEnsemble.ask(name, "work", timeout: 2_000)
    assert {:error, {"second", :halted}} = GenAgentEnsemble.ask(name, "next", timeout: 2_000)
    assert {:ok, info} = GenAgentEnsemble.status(name)
    assert info.phase == :idle
    assert info.queued == 0
  end

  test "Pool releases its busy slot after halted-worker rejection", %{name: name} do
    {:ok, _} = start(name, Pool, worker_count: 1, worker_template: spec("worker"))
    halt_member(name, "worker-1")

    assert {:error, :halted} = GenAgentEnsemble.ask(name, "work", timeout: 2_000)
    assert {:error, :halted} = GenAgentEnsemble.ask(name, "next", timeout: 2_000)
    assert {:ok, info} = GenAgentEnsemble.status(name)
    assert info.busy == 0
    assert info.queued == 0
  end

  test "Switchboard closes only dispatches routed to the halted member", %{name: name} do
    {:ok, _} = start(name, Switchboard, agents: [spec("halted"), spec("healthy")])
    halt_member(name, "halted")

    assert {:error, :halted} =
             GenAgentEnsemble.ask(name, "work", agent: "halted", timeout: 2_000)

    assert {:ok, %{text: "healthy"}} =
             GenAgentEnsemble.ask(name, "work", agent: "healthy", timeout: 2_000)
  end

  defp spec(name) do
    {name, HaltAgent,
     [
       backend: Mock,
       scripts: for(_ <- 1..3, do: fn _prompt -> [Event.new(:result, %{text: name})] end)
     ]}
  end

  defp start(name, strategy, opts) do
    GenAgentEnsemble.start_link(name: name, strategy: strategy, opts: opts)
  end

  defp halt_member(session, member) do
    name = "#{session}/#{member}"
    assert {:ok, ref} = GenAgent.tell(name, "halt")
    assert {:error, :pre_turn_halted} = GenAgent.poll(name, ref)
    assert GenAgent.runtime_snapshot(name).halted
  end
end
