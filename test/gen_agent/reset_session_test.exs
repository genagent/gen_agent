defmodule GenAgent.ResetSessionTest do
  use ExUnit.Case, async: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgent.Support.TestAgent

  defmodule ResetBackend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(_opts), do: {:ok, %{turns: 0}}

    @impl true
    def prompt(session, _prompt) do
      event = Event.new(:result, %{text: Integer.to_string(session.turns)})
      {:ok, [event], %{session | turns: session.turns + 1}}
    end

    @impl true
    def reset_session(session), do: {:ok, %{session | turns: 0}}

    @impl true
    def terminate_session(_session), do: :ok
  end

  setup do
    name = "reset-session-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    %{name: name}
  end

  test "reset replaces backend context while keeping callback state", %{name: name} do
    assert {:ok, _pid} = GenAgent.start_agent(TestAgent, name: name, backend: ResetBackend)

    assert {:ok, %{text: "0"}} = GenAgent.ask(name, "one")
    assert {:ok, %{text: "1"}} = GenAgent.ask(name, "two")
    assert :ok = GenAgent.reset_session(name)
    assert {:ok, %{text: "0"}} = GenAgent.ask(name, "three")
    assert length(GenAgent.status(name).agent_state.responses) == 3
  end

  test "unsupported and active resets leave the current session alone", %{name: name} do
    scripts = [Mock.gate(:active, [Event.new(:result, %{text: "done"})])]

    assert {:ok, _pid} =
             GenAgent.start_agent(TestAgent, name: name, backend: Mock, scripts: scripts)

    assert {:error, :unsupported} = GenAgent.reset_session(name)
    assert {:ok, ref} = GenAgent.tell_with_completion(name, "go")
    assert_receive {:mock_blocked, :active, task_pid}
    assert {:error, :busy} = GenAgent.reset_session(name)
    send(task_pid, {:mock_release, :active})
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, %{text: "done"}}}
  end

  test "missing agents return not_found" do
    assert {:error, :not_found} = GenAgent.reset_session("missing-reset-agent")
  end
end
