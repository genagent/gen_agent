defmodule GenAgentEnsemble.Backends.EchoTest do
  use ExUnit.Case, async: true

  alias GenAgent.Event
  alias GenAgentEnsemble.Backends.Echo

  describe "start_session/1" do
    test "uses a default transform when none is given" do
      {:ok, session} = Echo.start_session([])
      assert is_function(session.transform, 1)
      assert session.delay_ms == 0
    end

    test "accepts a custom transform and delay" do
      transform = &String.upcase/1
      {:ok, session} = Echo.start_session(transform: transform, delay_ms: 25)
      assert session.transform == transform
      assert session.delay_ms == 25
    end
  end

  describe "prompt/2" do
    test "default transform prepends 'echo: '" do
      {:ok, session} = Echo.start_session([])
      {:ok, events, ^session} = Echo.prompt(session, "hi")

      assert [%Event{kind: :result, data: %{text: "echo: hi"}}] = Enum.to_list(events)
    end

    test "honors a custom transform" do
      {:ok, session} = Echo.start_session(transform: &String.reverse/1)
      {:ok, events, ^session} = Echo.prompt(session, "hello")

      assert [%Event{kind: :result, data: %{text: "olleh"}}] = Enum.to_list(events)
    end

    test "delay_ms sleeps before returning" do
      {:ok, session} = Echo.start_session(delay_ms: 30)

      started = System.monotonic_time(:millisecond)
      {:ok, _events, _} = Echo.prompt(session, "x")
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed >= 30
    end
  end

  describe "update_session/2 and terminate_session/1" do
    test "update_session is a no-op" do
      {:ok, session} = Echo.start_session([])
      assert session == Echo.update_session(session, %{session_id: "anything"})
    end

    test "terminate_session returns :ok" do
      {:ok, session} = Echo.start_session([])
      assert :ok == Echo.terminate_session(session)
    end
  end

  describe "end-to-end through ensemble" do
    setup do
      name = "echo-e2e-#{System.unique_integer([:positive])}"
      on_exit(fn -> safe_stop(name) end)
      %{name: name}
    end

    test "works with Solo + Simple via ask/2", %{name: name} do
      {:ok, _} =
        GenAgentEnsemble.start_link(
          name: name,
          strategy: GenAgentEnsemble.Strategies.Solo,
          opts: [
            agent: {"w", GenAgentEnsemble.Agents.Simple, backend: GenAgentEnsemble.Backends.Echo}
          ]
        )

      assert {:ok, %{text: "echo: hello there"}} =
               GenAgentEnsemble.ask(name, "hello there", timeout: 5_000)
    end

    defp safe_stop(name) do
      GenAgentEnsemble.stop(name)
    catch
      :exit, _ -> :ok
    end
  end
end
