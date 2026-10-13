# Compile isolated copies of the actual fenced modules, alongside existing guide tests.
for pattern <- ~w(research pipeline supervisor debate pool) do
  guide = Path.expand("../../guides/patterns/#{pattern}.md", __DIR__)

  for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
      String.starts_with?(code, "defmodule ") do
    code = Regex.replace(~r/\b(Research|Pipeline|Fanout|Debate|Pool)\b/, code, "Guide240.\\1")
    Code.compile_string(code, guide)
  end
end

defmodule GenAgent.PatternGuideSnippetsTest do
  use ExUnit.Case, async: false
  alias GenAgent.Backends.Mock
  alias Guide240.{Debate, Pipeline, Pool}
  alias Guide240.Fanout.Coordinator
  alias Guide240.Research.Agent, as: ResearchAgent

  # Only inject backend options; all turns, gates and start errors use the existing Mock.
  defmodule Backend do
    @behaviour GenAgent.Backend

    def start_session(_opts) do
      name = GenAgent.current_name()

      config =
        Agent.get_and_update(__MODULE__, fn state ->
          {state, %{state | names: state.names ++ [name]}}
        end)

      if config.mode == :conflict and config.names == [] do
        conflict =
          conflicting_name(name)

        {:ok, pid} =
          DynamicSupervisor.start_child(
            config.supervisor,
            GenAgent.child_spec(GenAgent.PatternGuideSnippetsTest.Incumbent,
              name: conflict,
              backend: Mock,
              task_supervisor: GenAgent.TaskSupervisor
            )
          )

        send(config.observer, {:incumbent, conflict, pid})
      end

      if config.mode == :start_error and length(config.names) == 1 do
        Mock.start_session(start_error: :planned_start_failure)
      else
        scripts = Map.get(config.scripts, name, config.default_scripts)
        result = Mock.start_session(scripts: scripts)

        case result do
          {:ok, session} -> send(config.observer, {:session, name, session.agent})
          _ -> :ok
        end

        result
      end
    end

    defp conflicting_name(name) do
      cond do
        String.starts_with?(name, "pipe-") -> String.replace(name, "-1-first", "-2-second")
        String.starts_with?(name, "pool-") -> String.replace(name, ~r/-1$/, "-2")
        true -> String.replace(name, ~r/-a$/, "-b")
      end
    end

    defdelegate prompt(session, prompt), to: Mock
    defdelegate terminate_session(session), to: Mock
  end

  defmodule Incumbent do
    use GenAgent
    def init_agent(_), do: {:ok, [], nil}
    def handle_response(_, _, state), do: {:noreply, state}
  end

  setup do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    observer = self()

    {:ok, fixture} =
      Agent.start(
        fn ->
          %{
            mode: :normal,
            names: [],
            scripts: %{},
            default_scripts: [],
            observer: observer,
            supervisor: supervisor
          }
        end,
        name: Backend
      )

    on_exit(fn ->
      for name <- Agent.get(fixture, & &1.names), GenAgent.whereis(name), do: GenAgent.stop(name)
      Agent.stop(fixture)
    end)

    :ok
  end

  defp configure(opts), do: Agent.update(Backend, &Map.merge(&1, Map.new(opts)))
  defp events(text), do: [GenAgent.Event.new(:result, %{text: text})]
  defp name, do: "guide240-#{System.unique_integer([:positive])}"

  defp stages,
    do: Enum.map(~w(first second third), &%{name: &1, role: &1, instruction: "Transform."})

  for pattern <- [:pipeline, :debate, :pool], mode <- [:start_error, :conflict] do
    test "#{pattern} rolls back only owned children after #{mode}" do
      configure(mode: unquote(mode))

      result =
        case unquote(pattern) do
          :pipeline -> Pipeline.run("seed", stages(), backend: Backend)
          :debate -> Debate.start("topic", backend: Backend)
          :pool -> Pool.start(3, backend: Backend)
        end

      assert {:error, reason} = result

      if unquote(mode) == :start_error,
        do: assert(reason == {:backend_start_failed, :planned_start_failure})

      assert_receive {:session, first, session_pid}
      assert GenAgent.whereis(first) == nil
      refute Process.alive?(session_pid)

      if unquote(mode) == :conflict do
        assert_receive {:incumbent, conflicting_name, pid}
        assert GenAgent.whereis(conflicting_name) == pid
        assert Process.alive?(pid)
      end
    end
  end

  test "research filters a numbered preamble before limiting, strips numbering and waits for synthesis" do
    configure(
      default_scripts: [
        events(
          "Here are questions:\n\n1. First question?\n2) Second question?\n3. Third question?"
        ),
        events("answer one"),
        events("answer two"),
        Mock.gate(:report, events("final report"))
      ]
    )

    name = name()

    assert {:ok, _} =
             GenAgent.start_agent(ResearchAgent,
               name: name,
               backend: Backend,
               topic: "topic",
               max_sub_questions: 2
             )

    assert {:ok, _} = GenAgent.tell(name, "list")
    assert_receive {:mock_blocked, :report, task}, 1_000
    assert {:error, :timeout} = ResearchAgent.await_completion(name, 20)
    assert GenAgent.status(name).agent_state.final_report == nil
    send(task, {:mock_release, :report})
    assert {:ok, state} = ResearchAgent.await_completion(name, 1_000)
    assert state.sub_questions == ["First question?", "Second question?"]

    assert state.answered == [
             {"First question?", "answer one"},
             {"Second question?", "answer two"}
           ]

    assert state.final_report == "final report"
  end

  test "research rejects a listing with no questions instead of reporting a nil success" do
    configure(default_scripts: [events("Here are some ideas:\n1. Background context")])
    agent = name()

    assert {:ok, _} =
             GenAgent.start_agent(ResearchAgent, name: agent, backend: Backend, topic: "topic")

    assert {:ok, _} = GenAgent.tell(agent, "list")
    assert {:error, :no_questions} = ResearchAgent.await_completion(agent, 1_000)
  end

  test "research ignores a preamble in unnumbered output" do
    configure(
      default_scripts: [
        events("Some questions:\nFirst?\nSecond?"),
        events("one"),
        events("two"),
        events("report")
      ]
    )

    agent = name()

    assert {:ok, _} =
             GenAgent.start_agent(ResearchAgent,
               name: agent,
               backend: Backend,
               topic: "topic",
               max_sub_questions: 2
             )

    assert {:ok, _} = GenAgent.tell(agent, "list")
    assert {:ok, state} = ResearchAgent.await_completion(agent, 1_000)
    assert state.sub_questions == ["First?", "Second?"]
    assert state.final_report == "report"
  end

  test "pipeline preserves the seed in its trace and waits for the last stage" do
    configure(default_scripts: [Mock.gate(:stage, events("output"))])
    assert {:ok, handle} = Pipeline.run("seed", stages(), backend: Backend)

    for index <- 1..3 do
      assert_receive {:mock_blocked, :stage, task}, 1_000
      assert {:error, :timeout} = Pipeline.await_completion(handle, 20)
      state = GenAgent.status(Enum.at(handle.stages, index - 1)).agent_state
      assert state.input == if(index == 1, do: "seed", else: "output")
      assert state.output == nil
      send(task, {:mock_release, :stage})
    end

    assert {:ok, states} = Pipeline.await_completion(handle, 1_000)
    assert Enum.map(states, & &1.input) == ["seed", "output", "output"]
    assert Enum.all?(states, &(&1.output == "output"))
  end

  test "debate waits for both runtime halts with a bounded timeout" do
    configure(default_scripts: [Mock.gate(:debate, events("statement"))])
    assert {:ok, handle} = Debate.start("topic", backend: Backend, max_rounds: 1)

    for _ <- 1..2 do
      assert_receive {:mock_blocked, :debate, task}, 1_000
      assert {:error, :timeout} = Debate.await_completion(handle, 20)
      send(task, {:mock_release, :debate})
    end

    assert {:ok, [a, b]} = Debate.await_completion(handle, 1_000)
    assert a.transcript == b.transcript
    assert length(a.transcript) == 2
  end

  test "supervisor waits through planning, worker collection and synthesis" do
    configure(
      default_scripts: [Mock.gate(:plan, events("task")), Mock.gate(:synthesis, events("report"))]
    )

    name = name()

    assert {:ok, _} =
             GenAgent.start_agent(Coordinator,
               name: name,
               backend: Backend,
               worker_backend: Mock,
               worker_opts: [backend_opts: [scripts: [Mock.gate(:worker, events("answer"))]]],
               topic: "topic"
             )

    assert {:ok, _} = GenAgent.tell(name, "plan")

    for tag <- [:plan, :worker, :synthesis] do
      assert_receive {:mock_blocked, ^tag, task}, 1_000
      assert {:error, :timeout} = Coordinator.await_completion(name, 20)
      send(task, {:mock_release, tag})
    end

    assert {:ok, state} = Coordinator.await_completion(name, 1_000)
    assert state.final_output == "report"
  end

  test "all four completion helpers surface backend failure explicitly" do
    configure(default_scripts: [{:error, :planned_turn_failure}])
    research = name()
    coordinator = name()

    assert {:ok, _} =
             GenAgent.start_agent(ResearchAgent,
               name: research,
               backend: Backend,
               topic: "topic"
             )

    assert {:ok, _} = GenAgent.tell(research, "list")

    assert {:error, :planned_turn_failure} =
             ResearchAgent.await_completion(research, 1_000)

    assert {:ok, pipeline} = Pipeline.run("seed", stages(), backend: Backend)
    assert {:error, :planned_turn_failure} = Pipeline.await_completion(pipeline, 1_000)
    assert {:ok, debate} = Debate.start("topic", backend: Backend)
    assert {:error, :planned_turn_failure} = Debate.await_completion(debate, 1_000)

    assert {:ok, _} =
             GenAgent.start_agent(Coordinator,
               name: coordinator,
               backend: Backend,
               worker_backend: Mock,
               topic: "topic"
             )

    assert {:ok, _} = GenAgent.tell(coordinator, "plan")

    assert {:error, :planned_turn_failure} =
             Coordinator.await_completion(coordinator, 1_000)
  end
end
