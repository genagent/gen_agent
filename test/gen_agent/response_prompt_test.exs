defmodule GenAgent.ResponsePromptTest do
  use ExUnit.Case, async: true

  alias GenAgent.Event

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      {:ok, [scripts: Keyword.fetch!(opts, :scripts)],
       %{observer: Keyword.fetch!(opts, :observer), turns: 0}}
    end

    @impl true
    def pre_turn(prompt, state), do: {:ok, "rewritten: #{prompt}", state}

    @impl true
    def handle_response(ref, response, state) do
      send(state.observer, {:response, ref, response.prompt, response.text})
      state = %{state | turns: state.turns + 1}

      if state.turns == 1 do
        {:prompt, "follow-up", state}
      else
        {:noreply, state}
      end
    end

    @impl true
    def post_turn({:ok, response}, ref, state) do
      send(state.observer, {:post_turn, ref, response.prompt})
      {:ok, state}
    end
  end

  test "response carries the dispatched prompt through callback, completion, and self-chain" do
    name = "response-prompt-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      GenAgent.start_agent(Agent,
        name: name,
        backend: GenAgent.Backends.Mock,
        observer: self(),
        scripts: [
          [Event.new(:result, %{text: "first"})],
          [Event.new(:result, %{text: "second"})]
        ]
      )

    on_exit(fn -> if Process.alive?(pid), do: GenAgent.stop(name) end)

    {:ok, ref} = GenAgent.tell_with_completion(name, "initial")

    assert_receive {:response, ^ref, "rewritten: initial", "first"}
    assert_receive {:post_turn, ^ref, "rewritten: initial"}

    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, response}}
    assert response.prompt == "rewritten: initial"
    assert {:ok, :completed, ^response} = GenAgent.poll(name, ref)

    assert_receive {:response, second_ref, "rewritten: follow-up", "second"}
    assert is_reference(second_ref)
    assert second_ref != ref
    assert_receive {:post_turn, ^second_ref, "rewritten: follow-up"}
  end
end
