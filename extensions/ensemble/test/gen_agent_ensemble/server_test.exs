defmodule GenAgentEnsemble.ServerTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.Strategies.Solo
  alias GenAgentEnsemble.TestAgent

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
end
