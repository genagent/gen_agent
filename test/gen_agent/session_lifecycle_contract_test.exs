defmodule GenAgent.SessionLifecycleContractTest do
  use ExUnit.Case, async: true

  alias GenAgent.Event

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, [observer: Keyword.fetch!(opts, :observer)], %{}}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  defmodule Backend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts) do
      {:ok, %{observer: Keyword.fetch!(opts, :observer), turns: 0}}
    end

    @impl true
    def prompt(session, prompt) do
      send(session.observer, {:prompt, prompt, session.turns})
      {:ok, [Event.new(:result, %{text: prompt})], %{session | turns: session.turns + 1}}
    end

    @impl true
    def terminate_session(session) do
      send(session.observer, {:terminated, session.turns})
      :ok
    end
  end

  test "the updated backend session is reused and passed to termination" do
    name = {:session_lifecycle, make_ref()}
    {:ok, pid} = GenAgent.start_agent(Agent, name: name, backend: Backend, observer: self())
    on_exit(fn -> if Process.alive?(pid), do: GenAgent.stop(name) end)

    assert {:ok, %{text: "one"}} = GenAgent.ask(name, "one")
    assert_receive {:prompt, "one", 0}

    assert {:ok, %{text: "two"}} = GenAgent.ask(name, "two")
    assert_receive {:prompt, "two", 1}

    assert :ok = GenAgent.stop(name)
    assert_receive {:terminated, 2}
  end
end
