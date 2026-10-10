defmodule GenAgentEnsemble.OptionalCallbacksTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}

  defmodule MinimalStrategy do
    @behaviour GenAgentEnsemble.Strategy

    def init(opts) do
      observer = Keyword.fetch!(opts, :observer)

      specs =
        for a <- ["a", "b"],
            do: {a, ControlledAgent, backend: ControlledBackend, observer: observer, tag: a}

      {:ok, observer, specs}
    end

    def handle_tell(prompt, opts, token, observer) do
      send(observer, {:accepted, prompt, token})
      ops = for a <- Keyword.get(opts, :agents, ["a"]), do: {:dispatch, a, prompt, token}
      {:ok, ops, observer}
    end

    def handle_ask(prompt, opts, token, observer), do: handle_tell(prompt, opts, token, observer)

    def handle_response(agent, response, observer) do
      send(observer, {:response_callback, agent, response})
      {:ok, [], observer}
    end

    def handle_notify(ops, observer), do: {:ok, ops, observer}
  end

  defmodule HandlingStrategy do
    @behaviour GenAgentEnsemble.Strategy
    defdelegate init(opts), to: MinimalStrategy
    defdelegate handle_tell(prompt, opts, token, state), to: MinimalStrategy
    defdelegate handle_ask(prompt, opts, token, state), to: MinimalStrategy
    defdelegate handle_response(agent, response, state), to: MinimalStrategy
    defdelegate handle_notify(ops, state), to: MinimalStrategy

    def handle_error(agent, reason, observer) do
      send(observer, {:error_callback, agent, reason})
      {:ok, [], observer}
    end

    def handle_agent_down(agent, reason, observer) do
      send(observer, {:down_callback, agent, reason})
      {:ok, [], observer}
    end
  end

  setup do
    name = "optional-callbacks-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    %{name: name}
  end

  defp start(name, strategy \\ MinimalStrategy) do
    {:ok, server} = E.start_link(name: name, strategy: strategy, opts: [observer: self()])
    server
  end

  defp waiter(server, name, token) do
    task = Task.async(fn -> receive do: (:go -> E.await(name, token, :infinity)) end)
    :erlang.trace(task.pid, true, [:send])
    send(task.pid, :go)
    pid = task.pid
    assert_receive {:trace, ^pid, :send, {:"$gen_call", _, {:await, ^token, :infinity}}, ^server}
    :erlang.trace(pid, false, [:send])
    assert map_size(:sys.get_state(server).waiters[token]) == 1
    task
  end

  defp stale_completions(server, refs) do
    for {ref, {agent, _}} <- refs do
      send(server, {:gen_agent, :completion, agent, ref, {:ok, :stale}})
      send(server, {:gen_agent, :completion, agent, ref, {:error, :stale}})
    end

    :sys.get_state(server)
    refute_received {:response_callback, _, :stale}
    refute_received {:error_callback, _, :stale}
  end

  test "missing error handler closes tell and waiters and retires sibling refs", %{name: name} do
    server = start(name)
    {:ok, token} = E.tell_with_completion(name, "fail", self(), agents: ["a", "b"])
    assert_receive {:controlled_prompt, "a", "fail", backend}
    assert_receive {:controlled_prompt, "b", "fail", _}
    refs = :sys.get_state(server).in_flight
    task = waiter(server, name, token)
    send(backend, {:error, :boom})
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:error, :boom}}
    assert Task.await(task) == {:error, :boom}
    assert E.await(name, token, 0) == {:error, :boom}
    assert :sys.get_state(server).in_flight == %{}
    assert :sys.get_state(server).dispatch_contexts == %{}
    stale_completions(server, refs)
    assert E.poll(name, token) == {:error, :boom}
    refute_received {:gen_agent_ensemble, :completion, ^name, ^token, _}
  end

  test "missing error handler unblocks ask", %{name: name} do
    server = start(name)
    task = Task.async(fn -> E.ask(name, "ask", timeout: 2_000) end)
    assert_receive {:accepted, "ask", token}
    assert_receive {:controlled_prompt, "a", "ask", backend}
    send(backend, {:error, :boom})
    assert Task.await(task) == {:error, :boom}
    refute Map.has_key?(:sys.get_state(server).pending, token)
    assert :sys.get_state(server).in_flight == %{}
  end

  test "missing down handler fails multiple affected tokens and preserves unrelated work", %{
    name: name
  } do
    server = start(name)
    {:ok, first} = E.tell_with_completion(name, "first", self(), agents: ["a", "b"])
    assert_receive {:controlled_prompt, "a", "first", _}
    assert_receive {:controlled_prompt, "b", "first", sibling}
    ask = Task.async(fn -> E.ask(name, "second", timeout: 2_000) end)
    assert_receive {:accepted, "second", second}
    {:ok, unrelated} = E.tell(name, "unrelated", agents: ["b"])
    {:ok, idle} = E.tell(name, "idle", agents: [])
    state = :sys.get_state(server)
    refs = Map.reject(state.in_flight, fn {_, {_, token}} -> token == unrelated end)
    waiting = waiter(server, name, first)
    [{agent, _}] = Registry.lookup(GenAgent.Registry, "#{name}/a")
    Process.exit(agent, :kill)
    failure = {:agent_down, "a", :killed}
    assert Task.await(waiting) == {:error, failure}
    assert Task.await(ask) == {:error, failure}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^first, {:error, ^failure}}
    assert E.await(name, first, 0) == {:error, failure}
    state = :sys.get_state(server)
    refute Map.has_key?(state.pending, second)
    assert MapSet.new(Map.keys(state.pending)) == MapSet.new([unrelated, idle])
    assert Enum.all?(state.in_flight, fn {_, {_, token}} -> token == unrelated end)
    assert map_size(state.in_flight) == 1
    assert Map.keys(state.dispatch_contexts) == Map.keys(state.in_flight)
    stale_completions(server, refs)
    send(sibling, {:result, "late"})
    assert_receive {:controlled_prompt, "b", "unrelated", backend}
    send(backend, {:result, "live"})
    assert_receive {:response_callback, "b", %GenAgent.Response{text: "live"}}
    refute_received {:response_callback, "b", %GenAgent.Response{text: "late"}}
    E.notify(name, [{:reply, unrelated, :done}, {:reply, idle, :done}])
    assert E.await(name, unrelated) == {:ok, :done}
    assert E.await(name, idle) == {:ok, :done}
  end

  test "handlers retain control of pending tokens and sibling completions", %{name: name} do
    server = start(name, HandlingStrategy)
    {:ok, token} = E.tell(name, "handled", agents: ["a", "b"])
    assert_receive {:controlled_prompt, "a", "handled", backend}
    assert_receive {:controlled_prompt, "b", "handled", sibling}
    send(backend, {:error, :recoverable})
    assert_receive {:error_callback, "a", :recoverable}
    assert E.poll(name, token) == {:ok, :pending}
    assert map_size(:sys.get_state(server).in_flight) == 1
    send(sibling, {:result, "recovered"})
    assert_receive {:response_callback, "b", %GenAgent.Response{text: "recovered"}}
    {:ok, down_token} = E.tell(name, "down")
    assert_receive {:controlled_prompt, "a", "down", _}
    [{agent, _}] = Registry.lookup(GenAgent.Registry, "#{name}/a")
    Process.exit(agent, :kill)
    assert_receive {:down_callback, "a", :killed}
    assert E.poll(name, token) == {:ok, :pending}
    assert E.poll(name, down_token) == {:ok, :pending}
    E.notify(name, [{:reply, token, :recovered}, {:reply, down_token, :handled}])
    assert E.await(name, token) == {:ok, :recovered}
    assert E.await(name, down_token) == {:ok, :handled}
  end
end
