defmodule GenAgent.Scenarios.SupervisorTest do
  @moduledoc """
  End-to-end scenario port of `Playground.Supervisor`.

  Coordinator + dynamic worker pool. One coordinator plans sub-tasks
  on its first turn, spawns worker agents from inside its own
  `handle_response/3` callback (fan-out), notifies each worker with
  its task, and then collects results as they arrive via notify
  (fan-in). Once all workers have reported, the coordinator
  self-chains a synthesis turn and halts.

  Exercises:
    * `GenAgent.start_agent/2` called from inside a callback
    * many-to-one notify (fan-in)
    * one-to-many notify (fan-out)
    * multi-phase coordinator state machine
    * per-worker self-halt after a single turn
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event

  defmodule Worker do
    @moduledoc false
    use GenAgent

    defmodule State do
      @moduledoc false
      defstruct [:coordinator, :sub_task, :result]
    end

    @impl true
    def init_agent(opts) do
      state = %State{
        coordinator: Keyword.fetch!(opts, :coordinator),
        sub_task: Keyword.fetch!(opts, :sub_task)
      }

      {:ok, [scripts: Keyword.get(opts, :scripts, [])], state}
    end

    @impl true
    def handle_event(:go, %State{} = state) do
      {:prompt, state.sub_task, state}
    end

    def handle_event(_, state), do: {:noreply, state}

    @impl true
    def handle_response(_ref, response, %State{} = state) do
      GenAgent.notify(state.coordinator, {:worker_result, state.sub_task, response.text})
      {:halt, %{state | result: response.text}}
    end
  end

  defmodule Coordinator do
    @moduledoc false
    use GenAgent

    defmodule State do
      @moduledoc false
      defstruct [
        :task,
        :parent,
        :self_name,
        :worker_scripts,
        phase: :planning,
        sub_tasks: [],
        workers: [],
        results: %{},
        synthesis: nil
      ]
    end

    @impl true
    def init_agent(opts) do
      state = %State{
        task: Keyword.fetch!(opts, :task),
        parent: Keyword.fetch!(opts, :parent),
        self_name: Keyword.fetch!(opts, :self_name),
        worker_scripts: Keyword.fetch!(opts, :worker_scripts)
      }

      {:ok, [scripts: Keyword.get(opts, :scripts, [])], state}
    end

    @impl true
    def handle_response(_ref, response, %State{phase: :planning} = state) do
      sub_tasks = String.split(response.text, "|", trim: true)

      workers =
        Enum.map(sub_tasks, fn sub_task ->
          name = "worker-#{System.unique_integer([:positive])}"

          {:ok, _pid} =
            GenAgent.start_agent(Worker,
              name: name,
              backend: Mock,
              coordinator: state.self_name,
              sub_task: sub_task,
              scripts: [Map.fetch!(state.worker_scripts, sub_task)]
            )

          GenAgent.notify(name, :go)
          name
        end)

      {:noreply, %{state | phase: :fanned_out, sub_tasks: sub_tasks, workers: workers}}
    end

    def handle_response(_ref, response, %State{phase: :synthesizing} = state) do
      send(state.parent, {:synthesized, response.text})
      {:halt, %{state | phase: :finished, synthesis: response.text}}
    end

    @impl true
    def handle_event({:worker_result, sub_task, text}, %State{phase: :fanned_out} = state) do
      results = Map.put(state.results, sub_task, text)

      if map_size(results) == length(state.sub_tasks) do
        bundled = Enum.map_join(state.sub_tasks, " / ", &Map.fetch!(results, &1))

        state = %{state | results: results, phase: :synthesizing}
        {:prompt, "synthesize: #{bundled}", state}
      else
        {:noreply, %{state | results: results}}
      end
    end

    def handle_event(_event, state), do: {:noreply, state}
  end

  defp result(text), do: [Event.new(:result, %{text: text})]

  describe "fan-out/fan-in topology" do
    test "plan -> spawn workers -> collect results -> synthesize -> halt" do
      # Use the coordinator's OWN registered name so workers can notify
      # it back via GenAgent.notify/2.
      coordinator_name = "coord-#{System.unique_integer([:positive])}"

      worker_scripts = %{
        "sub-a" => result("result-a"),
        "sub-b" => result("result-b"),
        "sub-c" => result("result-c")
      }

      {:ok, _pid} =
        GenAgent.start_agent(Coordinator,
          name: coordinator_name,
          backend: Mock,
          task: "demo",
          parent: self(),
          self_name: coordinator_name,
          worker_scripts: worker_scripts,
          scripts: [
            # 1st turn: plan (split into 3 sub-tasks)
            result("sub-a|sub-b|sub-c"),
            # 2nd turn: synthesize
            result("final: a+b+c")
          ]
        )

      {:ok, _ref} = GenAgent.tell(coordinator_name, "demo")

      assert_receive {:synthesized, "final: a+b+c"}, 2_000

      s = GenAgent.status(coordinator_name).agent_state
      assert s.phase == :finished
      assert map_size(s.results) == 3
      assert Map.get(s.results, "sub-a") == "result-a"
      assert Map.get(s.results, "sub-b") == "result-b"
      assert Map.get(s.results, "sub-c") == "result-c"
      assert s.synthesis == "final: a+b+c"
      assert GenAgent.status(coordinator_name).halted == true

      GenAgent.stop(coordinator_name)
    end
  end
end
