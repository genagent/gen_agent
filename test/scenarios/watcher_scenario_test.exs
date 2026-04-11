defmodule GenAgent.Scenarios.WatcherTest do
  @moduledoc """
  End-to-end scenario port of `Playground.Watcher`.

  A reactive event-driven agent: starts idle with no initial prompt,
  sits waiting until events are pushed at it via `notify/2`.
  `handle_event/2` filters events -- interesting ones dispatch a
  turn, boring ones no-op. Regression-covers the notify-deferral
  fix (notifies arriving during `:processing` must have their state
  mutations preserved).
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event

  defmodule Agent do
    @moduledoc false
    use GenAgent

    defmodule State do
      @moduledoc false
      defstruct dispatched: [], ignored: [], responses: [], parent: nil
    end

    @impl true
    def init_agent(opts) do
      parent = Keyword.fetch!(opts, :parent)
      scripts = Keyword.get(opts, :scripts, [])
      {:ok, [scripts: scripts], %State{parent: parent}}
    end

    @impl true
    def handle_event({:pr_opened, _, _} = event, %State{} = state) do
      state = %{state | dispatched: state.dispatched ++ [event]}
      {:prompt, "welcome PR: #{inspect(event)}", state}
    end

    def handle_event({:ci_result, :failed, _} = event, %State{} = state) do
      state = %{state | dispatched: state.dispatched ++ [event]}
      {:prompt, "diagnose failure: #{inspect(event)}", state}
    end

    def handle_event(event, %State{} = state) do
      state = %{state | ignored: state.ignored ++ [event]}
      send(state.parent, {:ignored, event})
      {:noreply, state}
    end

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      state = %{state | responses: state.responses ++ [response.text]}
      send(state.parent, {:responded, response.text})
      {:noreply, state}
    end
  end

  defp start(name, scripts) do
    {:ok, _pid} =
      GenAgent.start_agent(Agent,
        name: name,
        backend: Mock,
        scripts: scripts,
        parent: self()
      )

    name
  end

  defp result(text), do: [Event.new(:result, %{text: text})]

  describe "event filtering topology" do
    test "boring events no-op, interesting events dispatch a turn" do
      name = "watcher-#{System.unique_integer([:positive])}"
      start(name, [result("welcomed alice")])

      # A boring event should not dispatch.
      GenAgent.notify(name, {:ci_result, :passed})
      assert_receive {:ignored, {:ci_result, :passed}}, 500

      # An interesting event dispatches.
      GenAgent.notify(name, {:pr_opened, "alice", "fix: auth"})
      assert_receive {:responded, "welcomed alice"}, 500

      s = GenAgent.status(name).agent_state
      assert length(s.dispatched) == 1
      assert length(s.ignored) == 1
      assert length(s.responses) == 1

      GenAgent.stop(name)
    end

    test "multiple interesting events queue correctly and each dispatches" do
      name = "watcher-#{System.unique_integer([:positive])}"
      start(name, [result("r1"), result("r2"), result("r3")])

      GenAgent.notify(name, {:pr_opened, "alice", "one"})
      GenAgent.notify(name, {:pr_opened, "bob", "two"})
      GenAgent.notify(name, {:pr_opened, "carol", "three"})

      # Each turn should complete in order.
      assert_receive {:responded, "r1"}, 500
      assert_receive {:responded, "r2"}, 500
      assert_receive {:responded, "r3"}, 500

      s = GenAgent.status(name).agent_state
      assert length(s.dispatched) == 3
      assert s.responses == ["r1", "r2", "r3"]

      GenAgent.stop(name)
    end

    test "idle-until-triggered: no turn runs until a notify arrives" do
      name = "watcher-#{System.unique_integer([:positive])}"
      start(name, [result("only-on-trigger")])

      # Give it a moment to demonstrate that nothing dispatches on its own.
      Process.sleep(50)
      s = GenAgent.status(name)
      assert s.state == :idle
      assert s.agent_state.responses == []

      # Now trigger.
      GenAgent.notify(name, {:pr_opened, "alice", "first"})
      assert_receive {:responded, "only-on-trigger"}, 500

      GenAgent.stop(name)
    end
  end
end
