defmodule GenAgentEnsemble.CancelTest do
  use ExUnit.Case, async: false

  alias GenAgent.Response
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.{Consensus, Pool, Solo, Switchboard}

  defmodule LegacyStrategy do
    defdelegate init(opts), to: Solo
    defdelegate handle_tell(prompt, opts, token, state), to: Solo
    defdelegate handle_response(agent, response, state), to: Solo
  end

  defp spec(name) do
    {name, ControlledAgent, backend: ControlledBackend, observer: self(), tag: name}
  end

  defp start(strategy, opts) do
    name = "cancel-#{System.unique_integer([:positive])}"
    {:ok, pid} = E.start_link(name: name, strategy: strategy, opts: opts)

    on_exit(fn ->
      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    {name, pid}
  end

  defp refs(pid, token) do
    for {ref, {agent, ^token}} <- :sys.get_state(pid).in_flight, do: {ref, agent}
  end

  defp late(pid, name, refs) do
    for {ref, agent} <- refs do
      send(
        pid,
        {:gen_agent, :completion, "#{name}/#{agent}", ref, {:ok, %Response{text: "late"}}}
      )

      send(pid, {:gen_agent, :completion, "#{name}/#{agent}", ref, {:error, :interrupted}})
    end

    :sys.get_state(pid)
  end

  defp waiter(pid, name, token) do
    task =
      Task.async(fn ->
        receive do
          :go -> E.await(name, token, :infinity)
        end
      end)

    :erlang.trace(task.pid, true, [:send])
    send(task.pid, :go)
    task_pid = task.pid

    assert_receive {:trace, ^task_pid, :send, {:"$gen_call", _, {:await, ^token, :infinity}},
                    ^pid}

    :erlang.trace(task.pid, false, [:send])
    assert map_size(:sys.get_state(pid).waiters[token]) == 1
    task
  end

  for strategy <- [Solo, Switchboard, Pool] do
    @strategy strategy
    test "#{inspect(strategy)} cancels queued and active tokens without losing successors" do
      opts =
        case @strategy do
          Solo -> [agent: spec("w")]
          Switchboard -> [agents: [spec("w"), spec("other")]]
          Pool -> [worker_count: 1, worker_template: spec("w")]
        end

      target = if @strategy == Pool, do: "w-1", else: "w"
      {name, pid} = start(@strategy, opts)
      route = if @strategy == Switchboard, do: [agent: target], else: []
      {:ok, active} = E.tell_with_completion(name, "active", self(), route)
      assert_receive {:controlled_prompt, "w", "active", backend}
      monitor = Process.monitor(backend)
      active_refs = refs(pid, active)
      {:ok, queued} = E.tell_with_completion(name, "queued", self(), route)
      queued_refs = refs(pid, queued)
      {:ok, survivor} = E.tell_with_completion(name, "survivor", self(), route)
      waiting = waiter(pid, name, active)

      other =
        if @strategy == Switchboard do
          {:ok, token} = E.tell_with_completion(name, "independent", self(), agent: "other")
          assert_receive {:controlled_prompt, "other", "independent", task}
          {token, task}
        end

      assert E.cancel(name, queued) == {:ok, :cancelled}
      assert_receive {:gen_agent_ensemble, :completion, ^name, ^queued, {:error, :cancelled}}

      if @strategy != Pool do
        [{ref, _}] = queued_refs
        assert GenAgent.poll("#{name}/#{target}", ref) == {:error, :cancelled}
      end

      assert E.cancel(name, queued) == {:error, :already_finished}
      assert E.poll(name, active) == {:ok, :pending}
      assert E.cancel(name, active) == {:ok, :cancelled}
      assert_receive {:DOWN, ^monitor, :process, ^backend, _}
      assert Task.await(waiting) == {:error, :cancelled}
      assert_receive {:gen_agent_ensemble, :completion, ^name, ^active, {:error, :cancelled}}
      assert E.cancel(name, active) == {:error, :already_finished}
      assert_receive {:controlled_prompt, "w", "survivor", next}
      late(pid, name, active_refs ++ queued_refs)
      assert E.poll(name, survivor) == {:ok, :pending}
      send(next, {:result, "kept"})

      assert_receive {:gen_agent_ensemble, :completion, ^name, ^survivor,
                      {:ok, %Response{text: "kept"}}}

      if other do
        {token, task} = other
        assert E.poll(name, token) == {:ok, :pending}
        send(task, {:result, "independent"})

        assert_receive {:gen_agent_ensemble, :completion, ^name, ^token,
                        {:ok, %Response{text: "independent"}}}
      end

      assert E.await(name, active, 0) == {:error, :cancelled}
      assert E.poll(name, active) == {:error, :cancelled}
      assert E.cancel(name, active) == {:error, :not_found}
      assert E.cancel(name, "unknown") == {:error, :not_found}
      assert {:ok, entries} = E.inbox(name)
      assert {queued, {:error, :cancelled}} in entries
      assert :sys.get_state(pid).in_flight == %{}
      assert :sys.get_state(pid).dispatch_contexts == %{}
      assert :sys.get_state(pid).waiters == %{}
      refute_receive {:controlled_prompt, _, "queued", _}, 0
      refute_receive {:gen_agent_ensemble, :completion, ^name, ^active, _}, 0
      refute_receive {:gen_agent_ensemble, :completion, ^name, ^queued, _}, 0
    end
  end

  test "Consensus cancels all child refs and advances its queue" do
    {name, pid} =
      start(Consensus,
        agents: [spec("a"), spec("b")],
        verdict_parser: fn text -> {:ok, :yes, text} end
      )

    {:ok, token} = E.tell_with_completion(name, "active")
    assert_receive {:controlled_prompt, "a", "active", a}
    assert_receive {:controlled_prompt, "b", "active", b}
    monitors = for task <- [a, b], do: {task, Process.monitor(task)}
    old_refs = refs(pid, token)
    assert length(old_refs) == 2
    {:ok, queued} = E.tell(name, "removed")
    {:ok, next} = E.tell_with_completion(name, "next")
    assert E.cancel(name, queued) == {:ok, :cancelled}
    assert E.cancel(name, token) == {:ok, :cancelled}
    for {task, monitor} <- monitors, do: assert_receive({:DOWN, ^monitor, :process, ^task, _})
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:error, :cancelled}}
    assert_receive {:controlled_prompt, "a", "next", next_a}
    assert_receive {:controlled_prompt, "b", "next", next_b}
    late(pid, name, old_refs)
    assert E.poll(name, next) == {:ok, :pending}
    send(next_a, {:result, "A"})
    send(next_b, {:result, "B"})
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^next, {:ok, %Response{}}}
    refute_receive {:controlled_prompt, _, "removed", _}, 0
    refute_receive {:gen_agent_ensemble, :completion, ^name, ^token, _}, 0
  end

  test "blocked ask receives the shared cancellation result" do
    {name, pid} = start(Solo, agent: spec("w"))
    ask = Task.async(fn -> E.ask(name, "ask") end)
    assert_receive {:controlled_prompt, "w", "ask", _}
    [token] = Map.keys(:sys.get_state(pid).pending)
    assert E.cancel(name, token) == {:ok, :cancelled}
    assert Task.await(ask) == {:error, :cancelled}
    assert E.inbox(name) == {:ok, []}
    assert E.cancel(name, token) == {:error, :not_found}
  end

  test "legacy strategy rejects without changing state or its child" do
    {name, pid} = start(LegacyStrategy, agent: spec("w"))
    {:ok, token} = E.tell_with_completion(name, "active")
    assert_receive {:controlled_prompt, "w", "active", backend}
    before = :sys.get_state(pid)
    assert E.cancel(name, token) == {:error, :unsupported}
    assert :sys.get_state(pid) == before
    assert Process.alive?(backend)
    send(backend, {:result, "done"})

    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token,
                    {:ok, %Response{text: "done"}}}
  end

  test "completion queued behind cancel wins without misassigning an earlier FIFO token" do
    {name, pid} = start(Solo, agent: spec("w"))
    {:ok, first} = E.tell_with_completion(name, "first")
    assert_receive {:controlled_prompt, "w", "first", backend}
    {:ok, second} = E.tell_with_completion(name, "second")
    :ok = :sys.suspend(pid)
    # Send the cancel before releasing either child; their completion messages
    # will follow it in the mailbox while the Ensemble is suspended.
    tag = make_ref()
    send(pid, {:"$gen_call", {self(), tag}, {:cancel, second}})
    send(backend, {:result, "first result"})
    assert_receive {:controlled_prompt, "w", "second", next}
    [{child, _}] = Registry.lookup(GenAgent.Registry, "#{name}/w")
    :erlang.trace(child, true, [:send])
    send(next, {:result, "second result"})
    assert_receive {:trace, ^child, :send, {:gen_agent, :completion, _, _, {:ok, _}}, ^pid}
    :erlang.trace(child, false, [:send])
    :ok = :sys.resume(pid)
    assert_receive {^tag, {:error, :already_finished}}

    assert_receive {:gen_agent_ensemble, :completion, ^name, ^first,
                    {:ok, %Response{text: "first result"}}}

    assert_receive {:gen_agent_ensemble, :completion, ^name, ^second,
                    {:ok, %Response{text: "second result"}}}
  end

  test "unknown child acknowledgement closes honestly and fences late events" do
    {name, pid} = start(Solo, agent: spec("w"))
    {:ok, token} = E.tell_with_completion(name, "active")
    assert_receive {:controlled_prompt, "w", "active", backend}
    [{ref, agent}] = refs(pid, token)
    fake = make_ref()

    :sys.replace_state(pid, fn state ->
      {context, contexts} = Map.pop(state.dispatch_contexts, ref)

      %{
        state
        | in_flight: %{fake => {agent, token}},
          dispatch_contexts: Map.put(contexts, fake, context)
      }
    end)

    assert E.cancel(name, token) == {:ok, :cancelled_unconfirmed}
    assert Process.alive?(backend)
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:error, :cancelled}}
    {:ok, next} = E.tell_with_completion(name, "next")
    send(backend, {:result, "late real result"})
    assert_receive {:controlled_prompt, "w", "next", next_backend}
    late(pid, name, [{fake, agent}, {ref, agent}])
    assert E.poll(name, next) == {:ok, :pending}
    send(next_backend, {:result, "next result"})

    assert_receive {:gen_agent_ensemble, :completion, ^name, ^next,
                    {:ok, %Response{text: "next result"}}}
  end

  test "Pipeline and Debate remove queued tokens and reset active run state" do
    alias GenAgentEnsemble.Strategies.{Debate, Pipeline}

    for {strategy, opts} <- [
          {Pipeline, [stages: [spec("a"), spec("b")]]},
          {Debate, [agents: [spec("a"), spec("b")]]}
        ] do
      {:ok, state, _} = strategy.init(opts)
      {:ok, _, state} = strategy.handle_tell("active", [], "active", state)
      {:ok, [], state} = strategy.handle_tell("removed", [], "removed", state)
      {:ok, [], state} = strategy.handle_tell("next", [], "next", state)
      {:ok, [], state} = strategy.handle_cancel("removed", state)
      {:ok, [{:dispatch, "a", "next", "next"}], state} = strategy.handle_cancel("active", state)
      assert GenAgentEnsemble.Queue.len(state.queue) == 0
      {:ok, [], state} = strategy.handle_cancel("next", state)
      assert state.phase == :idle
    end
  end

  test "Supervisor cancels decomposition and stops fanout workers before advancing" do
    alias GenAgentEnsemble.Strategies.Supervisor, as: Strategy

    opts = [
      coordinator: spec("c"),
      worker_template: spec("w"),
      decomposer: fn _ -> ["one", "two"] end
    ]

    {:ok, initial, _} = Strategy.init(opts)
    {:ok, _, state} = Strategy.handle_tell("active", [], "active", initial)
    {:ok, [], idle} = Strategy.handle_cancel("active", state)
    assert idle.phase == :idle
    {:ok, _, state} = Strategy.handle_response("c", %Response{text: "parts"}, state)
    {:ok, [], state} = Strategy.handle_tell("removed", [], "removed", state)
    {:ok, [], state} = Strategy.handle_tell("next", [], "next", state)
    {:ok, [], state} = Strategy.handle_cancel("removed", state)
    {:ok, ops, state} = Strategy.handle_cancel("active", state)
    assert Enum.sort(Enum.take(ops, 2)) == [{:stop, "w-1"}, {:stop, "w-2"}]
    assert List.last(ops) == {:dispatch, "c", "next", "next"}
    assert state.phase == {:decomposing, "next"}
    assert state.subtasks == []
    assert GenAgentEnsemble.Queue.len(state.queue) == 0
  end

  test "cancellation emits one terminal event per token and dispatch" do
    {name, pid} = start(Solo, agent: spec("w"))
    handler = make_ref()

    :ok =
      :telemetry.attach_many(
        handler,
        [[:gen_agent_ensemble, :token, :error], [:gen_agent_ensemble, :dispatch, :error]],
        fn event, measurements, metadata, observer ->
          send(observer, {event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, token} = E.tell(name, "active")
    assert_receive {:controlled_prompt, "w", "active", _}
    old_refs = refs(pid, token)
    assert E.cancel(name, token) == {:ok, :cancelled}
    late(pid, name, old_refs)

    for scope <- [:dispatch, :token] do
      event = [:gen_agent_ensemble, scope, :error]

      assert_receive {^event, %{duration_ms: _},
                      %{session: ^name, token: ^token, reason_kind: :cancelled}}

      refute_receive {^event, _, %{session: ^name, token: ^token}}, 0
    end
  end
end
