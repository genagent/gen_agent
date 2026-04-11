defmodule GenAgent.Scenarios.CheckpointerTest do
  @moduledoc """
  End-to-end scenario port of `Playground.Checkpointer`.

  Human-in-the-loop review workflow. The agent works through a
  multi-step task, but after each step sits idle with a
  `:awaiting_review` phase marker rather than halting. The manager
  inspects state, then drives the next step via notify:

    * `:approve`          -- continue to the next step
    * `{:revise, hint}`   -- redo the current step with feedback
    * `:finish`           -- halt early

  Validates the "idle with phase marker" pattern. Halt would be
  the wrong primitive here -- a halted mailbox blocks any
  subsequent `{:prompt, ..., state}` return from `handle_event`,
  so the next step would never dispatch.
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
      defstruct [
        :task,
        :total_steps,
        :parent,
        phase: :running,
        step: 0,
        drafts: []
      ]
    end

    @impl true
    def init_agent(opts) do
      state = %State{
        task: Keyword.fetch!(opts, :task),
        total_steps: Keyword.fetch!(opts, :total_steps),
        parent: Keyword.fetch!(opts, :parent)
      }

      {:ok, [scripts: Keyword.get(opts, :scripts, [])], state}
    end

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      state = %{
        state
        | drafts: state.drafts ++ [response.text],
          phase: :awaiting_review
      }

      send(state.parent, {:awaiting_review, state.step, response.text})
      # NOT :halt. Idle-with-phase-marker is the pause primitive.
      {:noreply, state}
    end

    @impl true
    def handle_event(:approve, %State{phase: :awaiting_review} = state) do
      next = state.step + 1

      if next >= state.total_steps do
        send(state.parent, {:finished, state.drafts})
        {:halt, %{state | phase: :finished}}
      else
        state = %{state | step: next, phase: :running}
        {:prompt, "next step: #{next + 1}/#{state.total_steps}", state}
      end
    end

    def handle_event({:revise, hint}, %State{phase: :awaiting_review} = state) do
      state = %{state | phase: :running}
      {:prompt, "revise step #{state.step + 1}: #{hint}", state}
    end

    def handle_event(:finish, %State{phase: :awaiting_review} = state) do
      send(state.parent, {:finished_early, state.drafts})
      {:halt, %{state | phase: :finished}}
    end

    def handle_event(_event, state), do: {:noreply, state}
  end

  defp result(text), do: [Event.new(:result, %{text: text})]

  defp start_with_scripts(scripts) do
    name = "checkpointer-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      GenAgent.start_agent(Agent,
        name: name,
        backend: Mock,
        scripts: scripts,
        task: "write a 3-part tagline",
        total_steps: 3,
        parent: self()
      )

    {:ok, _ref} = GenAgent.tell(name, "start")
    name
  end

  describe "idle-with-phase-marker pause primitive" do
    test "approves through all steps and finishes" do
      name =
        start_with_scripts([
          result("draft 1"),
          result("draft 2"),
          result("draft 3")
        ])

      assert_receive {:awaiting_review, 0, "draft 1"}, 500
      # Agent is idle with phase marker, NOT halted.
      s = GenAgent.status(name)
      assert s.state == :idle
      refute s.halted
      assert s.agent_state.phase == :awaiting_review

      GenAgent.notify(name, :approve)
      assert_receive {:awaiting_review, 1, "draft 2"}, 500

      GenAgent.notify(name, :approve)
      assert_receive {:awaiting_review, 2, "draft 3"}, 500

      GenAgent.notify(name, :approve)
      assert_receive {:finished, ["draft 1", "draft 2", "draft 3"]}, 500

      assert GenAgent.status(name).halted == true
      GenAgent.stop(name)
    end

    test "revise redoes the current step with feedback in the prompt" do
      name =
        start_with_scripts([
          result("draft 1"),
          fn prompt ->
            assert String.contains?(prompt, "be more specific")
            result("draft 1 revised")
          end,
          result("draft 2"),
          result("draft 3")
        ])

      assert_receive {:awaiting_review, 0, "draft 1"}, 500
      GenAgent.notify(name, {:revise, "be more specific"})
      assert_receive {:awaiting_review, 0, "draft 1 revised"}, 500

      GenAgent.notify(name, :approve)
      assert_receive {:awaiting_review, 1, "draft 2"}, 500
      GenAgent.notify(name, :approve)
      assert_receive {:awaiting_review, 2, "draft 3"}, 500
      GenAgent.notify(name, :approve)
      assert_receive {:finished, _}, 500

      GenAgent.stop(name)
    end

    test "finish halts early without running remaining steps" do
      name =
        start_with_scripts([
          result("draft 1"),
          result("draft 2")
        ])

      assert_receive {:awaiting_review, 0, "draft 1"}, 500
      GenAgent.notify(name, :finish)
      assert_receive {:finished_early, ["draft 1"]}, 500

      assert GenAgent.status(name).halted == true
      # The second script should NOT have been consumed.
      GenAgent.stop(name)
    end
  end
end
