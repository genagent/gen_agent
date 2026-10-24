defmodule GenAgentEnsemble.CancellationOwnershipTest do
  use ExUnit.Case, async: false
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.Server

  defmodule HeldAgent do
    use GenAgent
    def init_agent(opts), do: {:ok, opts, %{observer: Keyword.fetch!(opts, :observer)}}

    def handle_response(_, _, state), do: {:noreply, state}

    def pre_turn(prompt, state) do
      send(state.observer, {:held, self()})

      receive do
        :release -> {:ok, prompt, state}
      end
    end
  end

  defmodule Strategy do
    def init(opts), do: {:ok, nil, Keyword.fetch!(opts, :agents)}

    def handle_tell(prompt, opts, token, state) do
      ops = for name <- Keyword.get(opts, :targets, ["a"]), do: {:dispatch, name, prompt, token}
      {:ok, ops, state}
    end

    def handle_cancel(_, state), do: {:ok, [], state}
    def handle_notify(:halt, state), do: {:ok, [{:halt, :done}], state}
    def handle_response(_, _, _), do: raise("cancelled result reached strategy")
  end

  defp start(opts) do
    name = "cancel-ownership-#{System.unique_integer([:positive])}"

    agents =
      for name <- ["a", "b"],
          do: {name, HeldAgent, [observer: self(), backend: E.ControlledBackend]}

    {:ok, server} = E.start_link([name: name, strategy: Strategy, opts: [agents: agents]] ++ opts)
    children = Map.values(:sys.get_state(server).agents)

    on_exit(fn ->
      Enum.each(children, &send(&1, :release))

      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    {name, server}
  end

  defp cancel_held(name, server, token, count) do
    for _ <- 1..count, do: assert_receive({:held, _})
    state = :sys.get_state(server)
    refs = for {ref, {_, ^token}} <- state.in_flight, do: ref
    :erlang.trace(server, true, [:send, :set_on_spawn])
    cancellation = Task.async(fn -> E.cancel(name, token) end)
    assert_receive {:trace, _worker, :send, {:"$gen_call", _, {:cancel_request, ref}}, child}
    assert ref in refs
    assert elem(state.dispatch_contexts[ref], 2) == child
    op = :sys.get_state(server).cancellations[token]
    send(server, {:cancel_deadline, token, op.id})
    assert Task.await(cancellation, 2_000) == {:ok, :cancelled_unconfirmed}
    :erlang.trace(server, false, [:send, :set_on_spawn])
    refs
  end

  defp admission(name) do
    {:ok, %{admission: admission}} = E.status(name)
    admission
  end

  test "timeout retains capacity after result eviction; admission cannot settle it" do
    {name, server} = start(max_pending_prompts: 1, max_completed_results: 0)
    handler = make_ref()
    observer = self()
    events = for scope <- [:token, :dispatch], do: [:gen_agent_ensemble, scope, :error]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, _, metadata, _ ->
          if metadata.session == name, do: send(observer, {:terminal, event, metadata.token})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, token} = E.tell(name, "secret prompt")
    [ref] = cancel_held(name, server, token, 1)
    assert E.poll(name, token) == {:error, :not_found}

    assert %{pending_count: 1, pending_bytes: bytes, unresolved_cancelled_refs: 1} =
             admission(name)

    assert bytes == :erlang.external_size("secret prompt")
    for _ <- 1..3, do: assert({:error, {:overloaded, %{limit: :count}}} = E.tell(name, "new"))
    send(server, {:gen_agent, :admission, :ignored, ref, :ok})
    assert admission(name).pending_count == 1
    state = :sys.get_state(server)
    assert state.pending == %{}
    assert state.token_contexts == %{}

    assert %{
             state: %{
               cancelled_refs: :redacted,
               cancellation_leases: :redacted,
               cancellation_monitors: :redacted
             }
           } = Server.format_status(%{state: state})

    refute inspect(:sys.get_status(server), limit: :infinity) =~ "secret prompt"
    {^token, child, _} = state.cancelled_refs[ref]
    send(child, :release)
    assert_receive {:controlled_prompt, _, "secret prompt", backend}, 2_000
    # A child call barriers the actual admission send after pre_turn returns.
    assert %{state: :processing} = GenAgent.status(E.member_name(name, "a"))
    assert admission(name).pending_count == 1
    :erlang.trace(server, true, [:receive])
    send(backend, {:result, "done"})

    assert_receive {:trace, ^server, :receive, {:gen_agent, :completion, _, ^ref, {:ok, _}}},
                   2_000

    :erlang.trace(server, false, [:receive])
    for _ <- 1..2, do: send(server, {:gen_agent, :completion, :ignored, ref, {:error, :late}})
    assert %{pending_count: 0, pending_bytes: 0, unresolved_cancelled_refs: 0} = admission(name)
    assert :sys.get_state(server).cancellation_monitors == %{}

    for event <- events do
      assert_receive {:terminal, ^event, ^token}
      refute_receive {:terminal, ^event, ^token}, 0
    end

    assert {:ok, _} = E.tell(name, "replacement", targets: [])
  end

  test "fanout retains whole charge until rejection and captured PID death settle all refs" do
    charge = :erlang.external_size("fanout")
    {name, server} = start(max_pending_prompt_bytes: charge)
    {:ok, token} = E.tell(name, "fanout", targets: ["a", "b"])
    [first, second] = cancel_held(name, server, token, 2)
    send(server, {:gen_agent, :admission, :ignored, first, {:error, :rejected}})

    assert %{pending_count: 1, pending_bytes: ^charge, unresolved_cancelled_refs: 1} =
             admission(name)

    assert {:error, {:overloaded, %{limit: :bytes}}} = E.tell(name, "x")
    {^token, child, monitor} = :sys.get_state(server).cancelled_refs[second]
    send(server, {:DOWN, make_ref(), :process, self(), :normal})
    assert admission(name).pending_count == 1
    :erlang.trace(server, true, [:receive])
    Process.exit(child, :kill)

    assert_receive {:trace, ^server, :receive, {:DOWN, ^monitor, :process, ^child, :killed}},
                   2_000

    :erlang.trace(server, false, [:receive])
    assert %{pending_count: 0, pending_bytes: 0, unresolved_cancelled_refs: 0} = admission(name)
    send(server, {:gen_agent, :completion, :ignored, second, {:ok, %{text: "late"}}})
    assert admission(name).pending_bytes == 0
  end

  for evidence <- [:completion, :rejection] do
    test "late #{evidence} drained during another control timeout releases the earlier charge" do
      {name, server} = start(max_pending_prompts: 2)
      {:ok, t1} = E.tell(name, "first")
      [ref1] = cancel_held(name, server, t1, 1)
      {:ok, t2} = E.tell(name, "second prompt", targets: ["b"])
      assert_receive {:held, _}
      state = :sys.get_state(server)
      {^t1, _child1, monitor1} = state.cancelled_refs[ref1]
      [{ref2, {"b", ^t2}}] = Map.to_list(state.in_flight)
      :erlang.trace(server, true, [:send, :set_on_spawn])
      cancellation = Task.async(fn -> E.cancel(name, t2) end)
      assert_receive {:trace, _worker, :send, {:"$gen_call", _, {:cancel_request, ^ref2}}, _}

      # Worker send barriers installation; evidence is handled while b waits.
      message =
        case unquote(evidence) do
          :completion -> {:gen_agent, :completion, :ignored, ref1, {:error, :cancelled}}
          :rejection -> {:gen_agent, :admission, :ignored, ref1, {:error, :rejected}}
        end

      send(server, message)
      assert admission(name).pending_count == 1
      op = :sys.get_state(server).cancellations[t2]
      send(server, {:cancel_deadline, t2, op.id})
      assert Task.await(cancellation, 2_000) == {:ok, :cancelled_unconfirmed}
      :erlang.trace(server, false, [:send, :set_on_spawn])
      charge = :erlang.external_size("second prompt")

      assert %{
               pending_count: 1,
               pending_bytes: ^charge,
               unresolved_cancelled_tokens: 1,
               unresolved_cancelled_refs: 1
             } = admission(name)

      state = :sys.get_state(server)
      assert Map.keys(state.cancellation_leases) == [t2]
      refute Map.has_key?(state.cancelled_refs, ref1)
      refute Map.has_key?(state.cancellation_monitors, monitor1)
      assert {:ok, _} = E.tell(name, "replacement", targets: [])
    end
  end

  test "admission drained during a control timeout preserves acceptance without duplicate starts" do
    {name, server} = start([])
    {:ok, cancelling} = E.tell(name, "cancel", targets: ["b"])
    {:ok, surviving} = E.tell(name, "survive")
    for _ <- 1..2, do: assert_receive({:held, _})
    state = :sys.get_state(server)
    refs = Map.new(state.in_flight, fn {ref, {_, token}} -> {token, ref} end)
    cancel_ref = refs[cancelling]
    surviving_ref = refs[surviving]
    handler = make_ref()
    observer = self()
    event = [:gen_agent_ensemble, :dispatch, :start]

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _, _, metadata, _ ->
          if metadata.session == name, do: send(observer, {:dispatch_start, metadata.token})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :erlang.trace(server, true, [:send, :set_on_spawn])
    cancellation = Task.async(fn -> E.cancel(name, cancelling) end)
    assert_receive {:trace, _worker, :send, {:"$gen_call", _, {:cancel_request, ^cancel_ref}}, _}
    send(server, {:gen_agent, :admission, :ignored, surviving_ref, :ok})
    assert elem(:sys.get_state(server).dispatch_contexts[surviving_ref], 3) == :accepted
    op = :sys.get_state(server).cancellations[cancelling]
    send(server, {:cancel_deadline, cancelling, op.id})
    assert Task.await(cancellation, 2_000) == {:ok, :cancelled_unconfirmed}
    :erlang.trace(server, false, [:send, :set_on_spawn])
    assert elem(:sys.get_state(server).dispatch_contexts[surviving_ref], 3) == :accepted
    send(server, {:gen_agent, :admission, :ignored, surviving_ref, :ok})
    _ = :sys.get_state(server)
    assert_receive {:dispatch_start, ^surviving}
    refute_receive {:dispatch_start, ^surviving}, 0
  end

  test "halt retires leases and monitors and preserves the cancelled result" do
    {name, server} = start(max_pending_prompts: 1)
    {:ok, token} = E.tell(name, "held")
    cancel_held(name, server, token, 1)
    assert E.await(name, token, 0) == {:error, :cancelled}
    E.notify(name, :halt)
    assert %{pending_count: 0, pending_bytes: 0, unresolved_cancelled_refs: 0} = admission(name)
    state = :sys.get_state(server)
    assert state.cancelled_refs == %{}
    assert state.cancellation_leases == %{}
    assert state.cancellation_monitors == %{}
    assert E.await(name, token, 0) == {:error, :cancelled}
    assert {:error, {:halted, :done}} = E.tell(name, "new")
  end
end
