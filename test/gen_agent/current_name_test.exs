defmodule GenAgent.CurrentNameTest do
  use ExUnit.Case, async: true

  alias GenAgent.Event

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      observer = Keyword.fetch!(opts, :observer)
      send(observer, {:init, GenAgent.current_name(), Keyword.has_key?(opts, :name)})
      {:ok, [scripts: Keyword.fetch!(opts, :scripts)], observer}
    end

    @impl true
    def pre_turn(prompt, observer) do
      send(observer, {:pre_turn, GenAgent.current_name()})
      {:ok, prompt, observer}
    end

    @impl true
    def handle_stream_event(_event, observer) do
      send(observer, {:stream, GenAgent.current_name()})
      observer
    end

    @impl true
    def handle_response(_ref, _response, observer) do
      send(observer, {:response, GenAgent.current_name()})
      {:noreply, observer}
    end

    @impl true
    def handle_event(_event, observer) do
      send(observer, {:event, GenAgent.current_name()})
      {:noreply, observer}
    end

    @impl true
    def terminate_agent(_reason, observer) do
      send(observer, {:terminate, GenAgent.current_name()})
      :ok
    end
  end

  test "the registered name is available in server and prompt-task callbacks" do
    name = {:current_name, System.unique_integer([:positive])}

    {:ok, pid} =
      GenAgent.start_agent(Agent,
        name: name,
        backend: GenAgent.Backends.Mock,
        observer: self(),
        scripts: [[Event.new(:result, %{text: "done"})]]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenAgent.stop(name)
    end)

    assert GenAgent.current_name() == nil
    assert_receive {:init, ^name, false}
    assert :ok = GenAgent.notify_ack(name, :ping)
    assert_receive {:event, ^name}
    assert {:ok, _response} = GenAgent.ask(name, "work")
    assert_receive {:pre_turn, ^name}
    assert_receive {:stream, ^name}
    assert_receive {:response, ^name}

    assert :ok = GenAgent.stop(name)
    assert_receive {:terminate, ^name}
    assert GenAgent.current_name() == nil
  end
end
