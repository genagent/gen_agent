defmodule GenAgent.QuickStartTest do
  use ExUnit.Case, async: true

  alias GenAgent.{Event, Response}

  # Mirrors the Quick start agent in the README and GenAgent moduledoc.
  # The scripted backend keeps the documented flow independent of a CLI.
  defmodule Coder do
    use GenAgent

    defmodule State do
      defstruct [:path, responses: []]
    end

    @impl true
    def init_agent(opts) do
      path = Keyword.fetch!(opts, :cwd)
      {:ok, [scripts: Keyword.fetch!(opts, :scripts)], %State{path: path}}
    end

    @impl true
    def handle_response(_ref, response, state) do
      {:noreply, %{state | responses: state.responses ++ [response.text]}}
    end
  end

  test "quick start supports synchronous, asynchronous, and completion turns" do
    name = "quick-start-#{System.unique_integer([:positive])}"

    scripts =
      for text <- ["explained", "tests added", "checked", "tests passed"] do
        [Event.new(:result, %{text: text})]
      end

    assert {:ok, _pid} =
             GenAgent.start_agent(Coder,
               name: name,
               backend: GenAgent.Backends.Mock,
               cwd: "/example/project",
               scripts: scripts
             )

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    assert {:ok, %Response{text: "explained"}} = GenAgent.ask(name, "Explain the project")

    assert {:ok, ref} = GenAgent.tell(name, "Add tests")
    # The following ask is a queue barrier, so polling is deterministic.
    assert {:ok, %Response{text: "checked"}} = GenAgent.ask(name, "Check the tests")
    assert {:ok, :completed, %Response{text: "tests added"}} = GenAgent.poll(name, ref)

    assert {:ok, completion_ref} = GenAgent.tell_with_completion(name, "Run the tests")

    assert_receive {:gen_agent, :completion, ^name, ^completion_ref,
                    {:ok, %Response{text: "tests passed"}}}

    assert :ok = GenAgent.notify_ack(name, {:ci_failed, "test_auth"})

    assert GenAgent.status(name).agent_state.responses ==
             ["explained", "tests added", "checked", "tests passed"]
  end
end
