defmodule GenAgentEnsemble.ServerTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.Strategies.Solo
  alias GenAgentEnsemble.TestAgent

  defmodule InitErrorStrategy do
    @behaviour GenAgentEnsemble.Strategy
    def init(_opts), do: {:error, :bad_configuration}
    def handle_tell(_prompt, _opts, _token, state), do: {:ok, [], state}
    def handle_ask(_prompt, _opts, _token, state), do: {:ok, [], state}
    def handle_response(_agent, _response, state), do: {:ok, [], state}
  end

  defmodule StatusOverrideStrategy do
    @behaviour GenAgentEnsemble.Strategy
    def init(_opts), do: {:ok, %{}, []}
    def handle_status(_state), do: %{session: :overridden}
    def handle_tell(_prompt, _opts, _token, state), do: {:ok, [], state}
    def handle_ask(_prompt, _opts, _token, state), do: {:ok, [], state}
    def handle_response(_agent, _response, state), do: {:ok, [], state}
  end

  defp safe_stop(name) do
    GenAgentEnsemble.stop(name)
  catch
    :exit, _ -> :ok
  end

  defp start_solo(session_name, bare_agent_name, scripts) do
    on_exit(fn -> safe_stop(session_name) end)

    GenAgentEnsemble.start_link(
      name: session_name,
      strategy: Solo,
      opts: [
        agent: {bare_agent_name, TestAgent, [backend: Mock, scripts: scripts]}
      ]
    )
  end

  defp await_response(name, token, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(name, token, deadline)
  end

  defp poll(name, token, deadline) do
    case GenAgentEnsemble.poll(name, token) do
      {:ok, :completed, response} ->
        response

      {:ok, :pending} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          poll(name, token, deadline)
        else
          flunk("timeout waiting for #{token}")
        end
    end
  end

  describe "sub-agent name namespacing" do
    test "two ensembles using the same bare sub-agent name stay isolated" do
      a = "ns-a-#{System.unique_integer([:positive])}"
      b = "ns-b-#{System.unique_integer([:positive])}"

      {:ok, _} = start_solo(a, "w", [[Event.new(:result, %{text: "from A"})]])
      {:ok, _} = start_solo(b, "w", [[Event.new(:result, %{text: "from B"})]])

      {:ok, ta} = GenAgentEnsemble.tell(a, "hi A")
      {:ok, tb} = GenAgentEnsemble.tell(b, "hi B")

      assert await_response(a, ta).text == "from A"
      assert await_response(b, tb).text == "from B"
    end
  end

  test "init error tuple stops server initialization with its reason" do
    name = "init-error-#{System.unique_integer([:positive])}"

    assert {:error, :bad_configuration} =
             GenAgentEnsemble.start_link(name: name, strategy: InitErrorStrategy)
  end

  test "strategy status fields can replace base status fields" do
    name = "status-override-#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(name) end)
    {:ok, _} = GenAgentEnsemble.start_link(name: name, strategy: StatusOverrideStrategy)

    assert {:ok, %{session: :overridden}} = GenAgentEnsemble.status(name)
  end
end
