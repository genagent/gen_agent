defmodule GenAgentEnsemble.ResponsiveCancelTest do
  use ExUnit.Case, async: false
  alias GenAgentEnsemble, as: E

  defmodule Agent do
    use GenAgent
    def init_agent(opts), do: {:ok, opts, %{observer: Keyword.fetch!(opts, :observer)}}
    def handle_response(_, _, state), do: {:noreply, state}

    def pre_turn("held" = prompt, state) do
      send(state.observer, {:held, self()})

      receive do
        :release -> {:ok, prompt, state}
      end
    end

    def pre_turn(prompt, state), do: {:ok, prompt, state}
  end

  # A FIFO strategy that exposes exactly-once cancellation and fails loudly if
  # a cancelled predecessor is left ahead of a healthy successor.
  defmodule Strategy do
    def init(opts),
      do:
        {:ok, %{observer: opts[:observer], queues: %{}, attack: opts[:attack], cancelling: nil},
         opts[:agents]}

    defp closed_ops(nil), do: []

    defp closed_ops(token),
      do: [
        {:reply, token, :wrong},
        {:reply_error, token, :wrong},
        {:dispatch, "b", "escaped", token}
      ]

    def handle_tell(prompt, opts, token, state) do
      targets = Keyword.get(opts, :targets, ["a"])

      queues =
        Enum.reduce(targets, state.queues, fn name, queues ->
          Map.update(queues, name, [token], &(&1 ++ [token]))
        end)

      {:ok, Enum.map(targets, &{:dispatch, &1, prompt, token}), %{state | queues: queues}}
    end

    def handle_response(name, response, state) do
      [token | rest] = Map.fetch!(state.queues, name)

      {:ok, closed_ops(state.cancelling) ++ [{:reply, token, response}],
       %{state | queues: Map.put(state.queues, name, rest)}}
    end

    def handle_notify(:halt, state), do: {:ok, [{:halt, :done}], state}

    def handle_cancel(token, state) do
      send(state.observer, {:cancel_callback, token})
      queues = Map.new(state.queues, fn {name, queue} -> {name, List.delete(queue, token)} end)
      cancelling = if state.attack, do: token, else: nil
      {:ok, closed_ops(cancelling), %{state | queues: queues, cancelling: cancelling}}
    end
  end

  defp start(opts \\ []) do
    name = "responsive-cancel-#{System.unique_integer([:positive])}"

    agents =
      for name <- ["a", "b", "c"] do
        {name, Agent, observer: self(), tag: name, backend: E.ControlledBackend}
      end

    {:ok, server} =
      E.start_link(
        name: name,
        strategy: Strategy,
        opts: [agents: agents, observer: self(), attack: opts[:attack]]
      )

    children = :sys.get_state(server).agents

    on_exit(fn ->
      Enum.each(children, fn {_, pid} -> send(pid, :release) end)

      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    {name, server, children}
  end

  defp begin_cancel(name, server, token, count) do
    :erlang.trace(server, true, [:send, :set_on_spawn])
    task = Task.async(fn -> E.cancel(name, token) end)

    workers =
      for _ <- 1..count do
        assert_receive {:trace, worker, :send, {:"$gen_call", _, {:cancel_request, ref}}, child}
        {worker, ref, child}
      end

    assert_receive {:cancel_callback, ^token}
    {task, workers}
  end

  test "held fanout controls allow reads, admissions, healthy completion and independent cancellation" do
    {name, server, children} = start()
    {:ok, token} = E.tell_with_completion(name, "held", self(), targets: ["a", "b"])
    for _ <- 1..2, do: assert_receive({:held, _})
    {task, workers} = begin_cancel(name, server, token, 2)
    assert length(Enum.uniq_by(workers, &elem(&1, 0))) == 2
    assert :sys.get_state(server).in_flight == %{}
    assert E.cancel(name, token) == {:error, :cancelling}
    refute_receive {:cancel_callback, ^token}, 0
    assert {:ok, %{admission: %{pending_count: 1, pending_bytes: charge}}} = E.status(name)
    assert charge == :erlang.external_size("held")
    assert {:ok, []} = E.inbox(name)
    assert E.poll(name, token) == {:ok, :pending}
    assert E.await(name, token, 0) == {:error, :timeout}
    state = :sys.get_state(server)

    assert %{
             state: %{
               cancellations: :redacted,
               cancelling_refs: :redacted,
               control_monitors: :redacted
             }
           } =
             E.Server.format_status(%{state: state})

    {:ok, healthy} = E.tell_with_completion(name, "healthy", self(), targets: ["c"])
    assert_receive {:controlled_prompt, "c", "healthy", backend}
    send(backend, {:result, "healthy result"})
    assert {:ok, %GenAgent.Response{text: "healthy result"}} = E.await(name, healthy)
    {:ok, other} = E.tell(name, "other", targets: ["c"])
    assert_receive {:controlled_prompt, "c", "other", _}
    assert E.cancel(name, other) == {:ok, :cancelled}
    assert_receive {:cancel_callback, ^other}

    # Release only a. Its terminal evidence must bypass strategy FIFO while
    # the cancellation and b's exact control are still outstanding.
    send(children["a"], :release)
    assert_receive {:controlled_prompt, "a", "held", backend}
    send(backend, {:result, "discarded predecessor"})
    {:ok, successor} = E.tell_with_completion(name, "successor", self())
    assert_receive {:controlled_prompt, "a", "successor", backend}
    send(backend, {:result, "successor result"})
    assert {:ok, %GenAgent.Response{text: "successor result"}} = E.await(name, successor)
    assert E.poll(name, token) == {:ok, :pending}
    op = :sys.get_state(server).cancellations[token]
    send(server, {:cancel_deadline, token, op.id})
    assert Task.await(task) == {:ok, :cancelled_unconfirmed}
    state = :sys.get_state(server)
    assert map_size(state.cancelled_refs) == 1
    assert [{_, {^token, child, _}}] = Map.to_list(state.cancelled_refs)
    assert child == children["b"]
    refute_receive {:cancel_callback, ^token}, 0
  end

  test "cancel and sibling callback ops cannot reply or dispatch a cancelling token" do
    {name, server, _} = start(attack: true)
    {:ok, token} = E.tell_with_completion(name, "held", self())
    assert_receive {:held, _}
    {task, [{_, ref, _}]} = begin_cancel(name, server, token, 1)
    assert E.poll(name, token) == {:ok, :pending}

    {:ok, sibling} = E.tell_with_completion(name, "healthy", self(), targets: ["c"])
    assert_receive {:controlled_prompt, "c", "healthy", backend}
    send(backend, {:result, "sibling"})
    assert {:ok, %GenAgent.Response{text: "sibling"}} = E.await(name, sibling)
    state = :sys.get_state(server)
    assert state.in_flight == %{}
    assert state.dispatch_contexts == %{}
    assert map_size(state.cancelling_refs) == 1
    assert Map.has_key?(state.pending, token)
    assert E.poll(name, token) == {:ok, :pending}
    refute_received {:controlled_prompt, "b", "escaped", _}
    refute_received {:gen_agent_ensemble, :completion, ^name, ^token, _}

    send(server, {:gen_agent, :completion, :ignored, ref, {:ok, :late}})
    assert Task.await(task) == {:ok, :cancelled}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:error, :cancelled}}
    assert E.await(name, token, 0) == {:error, :cancelled}
    assert :sys.get_state(server).pending_prompt_bytes == 0
    refute_received {:gen_agent_ensemble, :completion, ^name, ^token, _}
    assert Process.alive?(server)
  end

  test "caller death does not strand cancellation; worker failure retains exact ownership" do
    {name, server, children} = start()
    {:ok, token} = E.tell(name, "held")
    assert_receive {:held, _}
    :erlang.trace(server, true, [:send, :set_on_spawn])
    caller = spawn(fn -> E.cancel(name, token) end)
    caller_monitor = Process.monitor(caller)
    assert_receive {:trace, worker, :send, {:"$gen_call", _, {:cancel_request, ref}}, child}
    assert child == children["a"]
    op = :sys.get_state(server).cancellations[token]
    send(server, {:cancel_control_result, token, make_ref(), ref, worker, true})
    send(server, {:cancel_control_result, token, op.id, ref, self(), true})
    send(server, {:cancel_control_result, token, op.id, ref, child, true})
    send(server, {:cancel_deadline, token, make_ref()})
    assert E.poll(name, token) == {:ok, :pending}
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}
    :erlang.trace(server, true, [:receive])
    Process.exit(worker, :kill)
    assert_receive {:trace, ^server, :receive, {:DOWN, _, :process, ^worker, :killed}}
    assert E.await(name, token, 0) == {:error, :cancelled}
    state = :sys.get_state(server)
    assert state.cancellations == %{}
    assert state.control_monitors == %{}
    assert {^token, ^child, _} = state.cancelled_refs[ref]
    send(server, {:cancel_control_result, token, op.id, ref, worker, true})
    send(server, {:cancel_deadline, token, op.id})
    assert :sys.get_state(server).cancelled_refs == state.cancelled_refs
  end

  test "captured child death during control confirms cancellation without a lease" do
    {name, server, children} = start()
    {:ok, token} = E.tell(name, "held")
    assert_receive {:held, _}
    {task, _} = begin_cancel(name, server, token, 1)
    Process.exit(children["a"], :kill)
    assert Task.await(task) == {:ok, :cancelled}
    assert E.await(name, token, 0) == {:error, :cancelled}
    assert :sys.get_state(server).cancellation_leases == %{}
  end

  for {cancel_reply, interrupt_reply, expected} <- [
        {{:ok, :cancelled}, nil, :cancelled},
        {{:error, :current}, {:ok, :accepted}, :cancelled},
        {{:error, :current}, {:error, :not_found}, :cancelled_unconfirmed},
        {{:error, :not_found}, nil, :cancelled_unconfirmed}
      ] do
    @cancel_reply cancel_reply
    @interrupt_reply interrupt_reply
    @expected expected
    test "exact captured PID controls #{inspect(cancel_reply)} / #{inspect(interrupt_reply)}" do
      {name, server, _} = start()
      {:ok, token} = E.tell(name, "held")
      assert_receive {:held, _}
      observer = self()
      # Registry and member ownership still identify the real child. Controls
      # must use only the captured dispatch PID, here a barrier protocol peer.
      :sys.replace_state(server, fn state ->
        contexts =
          Map.new(state.dispatch_contexts, fn {ref, {at, ordinal, _, admission}} ->
            {ref, {at, ordinal, observer, admission}}
          end)

        %{state | dispatch_contexts: contexts}
      end)

      task = Task.async(fn -> E.cancel(name, token) end)
      assert_receive {:"$gen_call", from, {:cancel_request, ref}}
      :gen_statem.reply(from, @cancel_reply)

      if @interrupt_reply do
        assert_receive {:"$gen_call", interrupt_from, {:interrupt_request, ^ref}}
        assert elem(interrupt_from, 0) == elem(from, 0)
        :gen_statem.reply(interrupt_from, @interrupt_reply)
      end

      assert Task.await(task) == {:ok, @expected}
      refute_receive {:"$gen_call", _, {:interrupt_request, _}}, 0
      state = :sys.get_state(server)

      if @expected == :cancelled do
        assert state.cancelled_refs == %{}
      else
        assert {^token, ^observer, _} = state.cancelled_refs[ref]
      end
    end
  end

  test "completion before admission during controls confirms once and ignores later evidence" do
    {name, server, _} = start()
    {:ok, token} = E.tell_with_completion(name, "held", self())
    assert_receive {:held, _}
    {task, [{_, ref, _}]} = begin_cancel(name, server, token, 1)

    send(
      server,
      {:gen_agent, :completion, :ignored, ref, {:ok, %GenAgent.Response{text: "late"}}}
    )

    assert Task.await(task) == {:ok, :cancelled}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:error, :cancelled}}
    send(server, {:gen_agent, :admission, :ignored, ref, :ok})
    send(server, {:gen_agent, :completion, :ignored, ref, {:error, :duplicate}})
    state = :sys.get_state(server)
    assert state.cancellation_leases == %{}
    assert state.pending_prompt_bytes == 0
    assert E.await(name, token, 0) == {:error, :cancelled}
    refute_receive {:gen_agent_ensemble, :completion, ^name, ^token, _}, 0
    refute_receive {:cancel_callback, ^token}, 0
  end

  test "admission rejection during controls settles ownership before admission acceptance" do
    {name, server, _} = start()
    {:ok, token} = E.tell(name, "held")
    assert_receive {:held, _}
    {task, [{_, ref, _}]} = begin_cancel(name, server, token, 1)
    send(server, {:gen_agent, :admission, :ignored, ref, {:error, :rejected}})
    assert Task.await(task) == {:ok, :cancelled}
    send(server, {:gen_agent, :admission, :ignored, ref, :ok})
    state = :sys.get_state(server)
    assert state.dispatch_contexts == %{}
    assert state.cancellation_leases == %{}
    assert state.pending_prompt_bytes == 0
    assert E.await(name, token, 0) == {:error, :cancelled}
  end

  test "halt during controls retires workers and timers and replies to the saved caller" do
    {name, server, _} = start()
    {:ok, token} = E.tell(name, "held")
    assert_receive {:held, _}
    {task, [{worker, ref, _}]} = begin_cancel(name, server, token, 1)
    monitor = Process.monitor(worker)
    op = :sys.get_state(server).cancellations[token]
    E.notify(name, :halt)
    assert Task.await(task) == {:error, {:halted, :done}}
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert Process.read_timer(op.timer) == false
    send(server, {:cancel_deadline, token, op.id})
    send(server, {:cancel_control_result, token, op.id, ref, worker, true})
    state = :sys.get_state(server)
    assert state.cancellations == %{}
    assert state.cancelling_refs == %{}
    assert state.control_monitors == %{}
    assert E.await(name, token, 0) == {:error, {:halted, :done}}
  end
end
