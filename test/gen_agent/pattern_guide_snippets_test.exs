# Compile isolated copies of the actual fenced modules, alongside existing guide tests.
guide = Path.expand("../../guides/patterns/research.md", __DIR__)

for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
    String.starts_with?(code, "defmodule ") do
  code = Regex.replace(~r/\bResearch\b/, code, "Guide240.Research")
  Code.compile_string(code, guide)
end

defmodule GenAgent.PatternGuideSnippetsTest do
  use ExUnit.Case, async: false
  alias GenAgent.Backends.Mock
  alias Guide240.Research.Agent, as: ResearchAgent

  # Only inject backend scripts; all turns and gates use the existing Mock.
  defmodule Backend do
    @behaviour GenAgent.Backend

    def start_session(_opts) do
      # Via registration happens before init, so the agent can find its name.
      [name] = Registry.keys(GenAgent.Registry, self())

      config =
        Agent.get_and_update(__MODULE__, fn state ->
          {state, %{state | names: state.names ++ [name]}}
        end)

      Mock.start_session(scripts: Map.get(config.scripts, name, config.default_scripts))
    end

    defdelegate prompt(session, prompt), to: Mock
    defdelegate terminate_session(session), to: Mock
  end

  setup do
    {:ok, fixture} =
      Agent.start(fn -> %{names: [], scripts: %{}, default_scripts: []} end, name: Backend)

    on_exit(fn ->
      for name <- Agent.get(fixture, & &1.names), GenAgent.whereis(name), do: GenAgent.stop(name)
      Agent.stop(fixture)
    end)

    :ok
  end

  defp configure(opts), do: Agent.update(Backend, &Map.merge(&1, Map.new(opts)))
  defp events(text), do: [GenAgent.Event.new(:result, %{text: text})]
  defp name, do: "guide240-#{System.unique_integer([:positive])}"

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

  test "research surfaces backend failure explicitly" do
    configure(default_scripts: [{:error, :planned_turn_failure}])
    research = name()

    assert {:ok, _} =
             GenAgent.start_agent(ResearchAgent,
               name: research,
               backend: Backend,
               topic: "topic"
             )

    assert {:ok, _} = GenAgent.tell(research, "list")

    assert {:error, :planned_turn_failure} =
             ResearchAgent.await_completion(research, 1_000)
  end
end
