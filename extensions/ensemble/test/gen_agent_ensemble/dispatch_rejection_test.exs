defmodule GenAgentEnsemble.DispatchRejectionTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.{Consensus, Pipeline, Pool, Solo, Switchboard}

  defmodule BarrierMember do
    use GenAgent

    @impl true
    def init_agent(opts) do
      send(opts[:observer], {:member_initialized, opts[:tag], self()})

      if opts[:hold_start] do
        receive do
          :release_start -> :ok
        end
      end

      {:ok, Keyword.take(opts, [:observer, :tag]), Map.new(opts)}
    end

    @impl true
    def handle_response(_, _, state), do: {:noreply, state}

    @impl true
    def terminate_agent(_, %{tag: "held", observer: observer}) do
      send(observer, {:shutdown_held, self()})

      receive do
        :release_shutdown -> :ok
      after
        5_000 -> :ok
      end
    end

    def terminate_agent(_, _), do: :ok
  end

  defmodule MissingAgentStrategy do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(opts) do
      {:ok, %{token: nil}, Keyword.fetch!(opts, :agents)}
    end

    @impl true
    def handle_tell(prompt, opts, token, state), do: dispatch(prompt, opts, token, state)

    @impl true
    def handle_ask(prompt, opts, token, state), do: dispatch(prompt, opts, token, state)

    @impl true
    def handle_response(_agent, response, %{token: token} = state) do
      {:ok, [{:reply, token, response}], %{state | token: nil}}
    end

    defp dispatch(prompt, opts, token, state) do
      agent = Keyword.get(opts, :agent, "missing")
      {:ok, [{:dispatch, agent, prompt, token}], %{state | token: token}}
    end
  end

  defmodule FinalizerStrategy do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(opts),
      do:
        {:ok,
         %{
           mode: Keyword.fetch!(opts, :mode),
           token: nil,
           observer: Keyword.get(opts, :observer),
           barrier: Keyword.get(opts, :barrier)
         }, Keyword.get(opts, :agents, [])}

    @impl true
    def handle_tell("idle", _opts, _token, state), do: {:ok, [], state}

    def handle_tell("successor", _opts, token, state) do
      {:ok,
       [
         {:start,
          {"successor", BarrierMember,
           [backend: ControlledBackend, observer: state.observer, tag: "successor"]}},
         {:dispatch, "successor", "must not run", token}
       ], state}
    end

    def handle_tell(prompt, _opts, token, state) do
      {:ok, [{:dispatch, "missing", prompt, token}, {:reply, token, "abandoned tail"}],
       %{state | token: token}}
    end

    @impl true
    def handle_ask(prompt, opts, token, state), do: handle_tell(prompt, opts, token, state)

    @impl true
    def handle_response(_agent, _response, state), do: {:ok, [], state}

    @impl true
    def handle_dispatch_rejected("missing", token, _reason, state) do
      {:ok, rejection_ops(state.mode, token, state), state}
    end

    def handle_dispatch_rejected("also-missing", token, _reason, state),
      do: {:ok, [{:reply, token, "nested reply"}], state}

    defp rejection_ops(mode, token, state)
         when mode in [
                :held_reply,
                :held_fallback,
                :held_nested_start,
                :held_nested_dispatch,
                :held_halt
              ] do
      case mode do
        mode when mode in [:held_reply, :held_fallback] ->
          [
            state.barrier
            | if(mode == :held_reply, do: [{:reply, token, "callback reply"}], else: [])
          ]

        :held_nested_start ->
          [state.barrier, {:start, {"invalid"}}, {:reply, token, "abandoned"}]

        :held_nested_dispatch ->
          [
            state.barrier,
            {:dispatch, "also-missing", "nested", token},
            {:reply, token, "abandoned"}
          ]

        :held_halt ->
          [state.barrier, {:halt, :callback_halt}, {:reply, token, "abandoned"}]
      end
    end

    defp rejection_ops(mode, token, _state) do
      case mode do
        :reply ->
          [{:stop, "absent"}, {:reply, token, "callback reply"}]

        :nested_start ->
          [{:start, {"invalid"}}, {:reply, token, "abandoned callback tail"}]

        :nested_dispatch ->
          [{:dispatch, "also-missing", "nested", token}, {:reply, token, "abandoned tail"}]

        :halt ->
          [{:halt, :callback_halt}, {:reply, token, "abandoned tail"}]

        :fallback ->
          [{:stop, "absent"}]
      end
    end

    @impl true
    def handle_cancel(token, state) do
      send(state.observer, {:cancel_installed, token})

      {:ok,
       [
         {:stop, "held"},
         {:start,
          {"cleanup-" <> token, BarrierMember,
           [backend: ControlledBackend, observer: state.observer, tag: "cleanup"]}}
       ], state}
    end

    @impl true
    def handle_start_rejected("invalid", _reason, state),
      do: {:ok, [{:reply, state.token, "start rejection reply"}], state}
  end

  setup do
    name = "rejection-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case Registry.lookup(GenAgentEnsemble.Registry, name) do
        [{server, _}] ->
          try do
            GenServer.stop(server, :normal, 10_000)
          catch
            # The linked test owner may already have begun session shutdown.
            :exit, {{reason, {:sys, :terminate, _}}, {GenServer, :stop, _}}
            when reason in [:noproc, :normal, :shutdown] ->
              :ok

            :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
              :ok
          end

        [] ->
          :ok
      end
    end)

    {:ok, name: name}
  end

  defp agent(tag) do
    {tag, ControlledAgent,
     [backend: ControlledBackend, observer: self(), tag: tag, max_pending_prompts: 0]}
  end

  defp ask_async(name, prompt, opts \\ []) do
    Task.async(fn -> Ensemble.ask(name, prompt, opts) end)
  end

  defp await_poll(name, token, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    case Ensemble.poll(name, token) do
      {:ok, :pending} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          await_poll(name, token, deadline)
        else
          flunk("token #{token} did not complete")
        end

      result ->
        result
    end
  end

  for {mode, expected} <- [
        reply: {:ok, :completed, "callback reply"},
        nested_start: {:ok, :completed, "start rejection reply"},
        nested_dispatch: {:ok, :completed, "nested reply"},
        halt: {:error, {:halted, :callback_halt}},
        fallback: {:error, {:dispatch_rejected, "missing", {:agent_not_running, "missing"}}}
      ] do
    test "rejection batch finalizes after #{mode} callback operations", %{name: name} do
      {:ok, _server} =
        Ensemble.start_link(name: name, strategy: FinalizerStrategy, opts: [mode: unquote(mode)])

      {:ok, token} = Ensemble.tell(name, "rejected")
      assert Ensemble.poll(name, token) == unquote(Macro.escape(expected))
      assert {:ok, %{pending_tokens: []}} = Ensemble.status(name)
      assert Ensemble.poll(name, token) == {:error, :not_found}
    end
  end

  for kind <- [:start, :stop], reply? <- [true, false], cancel? <- [true, false] do
    test "held #{kind} rejection reply=#{reply?} cancellation=#{cancel?}", %{name: name} do
      kind = unquote(kind)
      reply? = unquote(reply?)
      cancel? = unquote(cancel?)

      spec =
        {"held", BarrierMember,
         [backend: ControlledBackend, observer: self(), tag: "held", hold_start: kind == :start]}

      barrier = if kind == :start, do: {:start, spec}, else: {:stop, "held"}

      {:ok, server} =
        Ensemble.start_link(
          name: name,
          strategy: FinalizerStrategy,
          opts: [
            mode: if(reply?, do: :held_reply, else: :held_fallback),
            observer: self(),
            barrier: barrier,
            agents: if(kind == :stop, do: [spec], else: [])
          ]
        )

      if kind == :stop, do: assert_receive({:member_initialized, "held", _})
      {:ok, token} = Ensemble.tell(name, "rejected")

      held =
        if kind == :start do
          assert_receive {:member_initialized, "held", pid}
          pid
        else
          assert_receive {:shutdown_held, pid}
          pid
        end

      on_exit(fn ->
        send(held, :release_start)
        send(held, :release_shutdown)
      end)

      assert {:ok, :pending} = Ensemble.poll(name, token)

      cancellation =
        if cancel? do
          task = Task.async(fn -> Ensemble.cancel(name, token) end)
          assert_receive {:cancel_installed, ^token}
          assert Map.has_key?(:sys.get_state(server).cancellations, token)
          task
        end

      send(held, if(kind == :start, do: :release_start, else: :release_shutdown))

      if kind == :start and cancel? do
        assert_receive {:shutdown_held, ^held}
        send(held, :release_shutdown)
      end

      expected =
        cond do
          cancel? -> {:error, :cancelled}
          reply? -> {:ok, "callback reply"}
          true -> {:error, {:dispatch_rejected, "missing", {:agent_not_running, "missing"}}}
        end

      assert Ensemble.await(name, token, 2_000) == expected
      if cancellation, do: assert(Task.await(cancellation) == {:ok, :cancelled})
      assert {:ok, %{pending_tokens: []}} = Ensemble.status(name)

      assert Ensemble.poll(name, token) != {:ok, :pending}
      assert {:error, :not_found} = Ensemble.poll(name, token)
      state = :sys.get_state(server)
      assert state.pending_prompt_bytes == 0
      assert state.cancellation_leases == %{}
      assert state.cancellations == %{}
    end
  end

  for {mode, expected} <- [
        held_nested_start: {:ok, "start rejection reply"},
        held_nested_dispatch: {:ok, "nested reply"},
        held_halt: {:error, {:halted, :callback_halt}}
      ] do
    test "#{mode} finalizes after held start and abandons original tails", %{name: name} do
      spec =
        {"held", BarrierMember,
         [backend: ControlledBackend, observer: self(), tag: "held", hold_start: true]}

      {:ok, _} =
        Ensemble.start_link(
          name: name,
          strategy: FinalizerStrategy,
          opts: [mode: unquote(mode), barrier: {:start, spec}]
        )

      {:ok, token} = Ensemble.tell(name, "rejected")
      assert_receive {:member_initialized, "held", held}

      on_exit(fn ->
        send(held, :release_start)
        send(held, :release_shutdown)
      end)

      assert {:ok, :pending} = Ensemble.poll(name, token)
      send(held, :release_start)
      send(held, :release_shutdown)
      assert Ensemble.await(name, token, 2_000) == unquote(Macro.escape(expected))
      assert Ensemble.poll(name, token) != {:ok, :pending}
      assert {:error, :not_found} = Ensemble.poll(name, token)
    end
  end

  test "cancellation with suspended strategy stop fences a queued successor once", %{name: name} do
    spec = {"held", BarrierMember, [backend: ControlledBackend, observer: self(), tag: "held"]}

    {:ok, server} =
      Ensemble.start_link(
        name: name,
        strategy: FinalizerStrategy,
        opts: [mode: :fallback, observer: self(), agents: [spec]]
      )

    assert_receive {:member_initialized, "held", held}
    on_exit(fn -> send(held, :release_shutdown) end)
    {:ok, first} = Ensemble.tell(name, "idle")
    cancel_first = Task.async(fn -> Ensemble.cancel(name, first) end)
    assert_receive {:cancel_installed, ^first}
    assert_receive {:shutdown_held, ^held}
    {:ok, successor} = Ensemble.tell(name, "successor")
    cancel_next = Task.async(fn -> Ensemble.cancel(name, successor) end)
    assert_receive {:cancel_installed, ^successor}
    assert {:error, :cancelling} = Ensemble.cancel(name, successor)
    assert {:ok, :pending} = Ensemble.poll(name, successor)
    assert :sys.get_state(server).runtime.active.kind == :stop
    send(held, :release_shutdown)
    assert {:ok, :cancelled} = Task.await(cancel_first)
    assert {:ok, :cancelled} = Task.await(cancel_next)
    assert {:error, :cancelled} = Ensemble.poll(name, first)
    assert {:error, :cancelled} = Ensemble.poll(name, successor)
    assert {:error, :not_found} = Ensemble.poll(name, successor)
    assert_receive {:member_initialized, "successor", _}
    refute_received {:member_initialized, "successor", _}
    refute_received {:controlled_prompt, "successor", _, _}
    refute_received {:cancel_installed, _}
    state = :sys.get_state(server)
    assert state.pending_prompt_bytes == 0
    assert state.pending == %{}
    assert state.cancellation_leases == %{}
    assert state.cancellations == %{}
  end

  test "Solo closes rejected tell, retains earlier ask, and serves a later ask", %{name: name} do
    {:ok, _} = Ensemble.start_link(name: name, strategy: Solo, opts: [agent: agent("solo")])

    first = ask_async(name, "first")
    assert_receive {:controlled_prompt, "solo", "first", first_task}

    {:ok, rejected} = Ensemble.tell(name, "rejected")
    assert {:error, {:overloaded, _}} = await_poll(name, rejected)
    assert {:ok, %{queued_tokens: 1}} = Ensemble.status(name)

    send(first_task, {:result, "FIRST"})
    assert {:ok, %{text: "FIRST"}} = Task.await(first)

    later = ask_async(name, "later")
    assert_receive {:controlled_prompt, "solo", "later", later_task}
    send(later_task, {:result, "LATER"})
    assert {:ok, %{text: "LATER"}} = Task.await(later)
    assert {:ok, %{queued_tokens: 0}} = Ensemble.status(name)
  end

  test "missing sub-agent rejects ask and tell without killing the session", %{name: name} do
    {:ok, server} =
      Ensemble.start_link(
        name: name,
        strategy: MissingAgentStrategy,
        opts: [
          agents: [{"live", ControlledAgent, [backend: ControlledBackend, observer: self()]}]
        ]
      )

    unavailable = {:dispatch_rejected, "missing", {:agent_not_running, "missing"}}

    assert {:error, ^unavailable} = Ensemble.ask(name, "missing ask")
    {:ok, token} = Ensemble.tell(name, "missing tell")
    assert {:error, ^unavailable} = Ensemble.poll(name, token)
    assert Process.alive?(server)
    assert {:ok, %{pending_tokens: []}} = Ensemble.status(name)

    live = ask_async(name, "working", agent: "live")
    assert_receive {:controlled_prompt, _, "working", task}, 2_000
    send(task, {:result, "WORKS"})
    assert {:ok, %{text: "WORKS"}} = Task.await(live)
  end

  test "dead sub-agent rejects dispatch while another worker remains usable", %{name: name} do
    agents =
      for tag <- ["live", "dead"] do
        {tag, ControlledAgent, [backend: ControlledBackend, observer: self(), tag: tag]}
      end

    {:ok, server} =
      Ensemble.start_link(name: name, strategy: MissingAgentStrategy, opts: [agents: agents])

    [{dead, _}] = Registry.lookup(GenAgent.Registry, GenAgentEnsemble.member_name(name, "dead"))
    monitor = Process.monitor(dead)
    Process.exit(dead, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :killed}, 2_000

    assert {:error, {:dispatch_rejected, "dead", {:agent_not_running, "dead"}}} =
             Ensemble.ask(name, "dead ask", agent: "dead")

    live = ask_async(name, "working", agent: "live")
    assert_receive {:controlled_prompt, "live", "working", task}, 2_000
    send(task, {:result, "WORKS"})
    assert {:ok, %{text: "WORKS"}} = Task.await(live)
    assert Process.alive?(server)
  end

  test "Switchboard removes only the rejected token from its agent queue", %{name: name} do
    {:ok, _} =
      Ensemble.start_link(name: name, strategy: Switchboard, opts: [agents: [agent("a")]])

    first = ask_async(name, "first", agent: "a")
    assert_receive {:controlled_prompt, "a", "first", first_task}

    rejected = ask_async(name, "rejected", agent: "a")
    assert {:error, {:overloaded, _}} = Task.await(rejected)
    assert {:ok, %{pending_per_agent: %{"a" => 1}}} = Ensemble.status(name)

    send(first_task, {:result, "FIRST"})
    assert {:ok, %{text: "FIRST"}} = Task.await(first)

    later = ask_async(name, "later", agent: "a")
    assert_receive {:controlled_prompt, "a", "later", later_task}
    send(later_task, {:result, "LATER"})
    assert {:ok, %{text: "LATER"}} = Task.await(later)
  end

  test "Pool releases a worker after rejected dispatch", %{name: name} do
    {:ok, _} =
      Ensemble.start_link(
        name: name,
        strategy: Pool,
        opts: [
          worker_count: 1,
          worker_template: {"worker", ControlledAgent, elem(agent("worker"), 2)}
        ]
      )

    external =
      Task.async(fn ->
        GenAgent.ask(GenAgentEnsemble.member_name(name, "worker-1"), "external")
      end)

    assert_receive {:controlled_prompt, "worker", "external", external_task}

    {:ok, rejected} = Ensemble.tell(name, "rejected")
    assert {:error, {:overloaded, _}} = await_poll(name, rejected)
    assert {:ok, %{free: 1, busy: 0, queued: 0}} = Ensemble.status(name)

    send(external_task, {:result, "EXTERNAL"})
    assert {:ok, %{text: "EXTERNAL"}} = Task.await(external)

    later = ask_async(name, "later")
    assert_receive {:controlled_prompt, "worker", "later", later_task}
    send(later_task, {:result, "LATER"})
    assert {:ok, %{text: "LATER"}} = Task.await(later)
  end

  test "Pipeline aborts a rejected stage and admits the next run", %{name: name} do
    {:ok, _} =
      Ensemble.start_link(
        name: name,
        strategy: Pipeline,
        opts: [stages: [agent("first"), agent("second")]]
      )

    external =
      Task.async(fn -> GenAgent.ask(GenAgentEnsemble.member_name(name, "second"), "external") end)

    assert_receive {:controlled_prompt, "second", "external", external_task}

    failed = ask_async(name, "failed")
    assert_receive {:controlled_prompt, "first", "failed", first_task}
    {:ok, later} = Ensemble.tell(name, "later")
    assert {:ok, %{queued: 1}} = Ensemble.status(name)
    send(first_task, {:result, "NEXT_STAGE"})
    assert {:error, {"second", {:overloaded, _}}} = Task.await(failed)
    assert_receive {:controlled_prompt, "first", "later", later_first}
    assert {:ok, %{phase: {:in_stage, "first"}, queued: 0}} = Ensemble.status(name)

    send(external_task, {:result, "EXTERNAL"})
    assert {:ok, %{text: "EXTERNAL"}} = Task.await(external)

    send(later_first, {:result, "TO_SECOND"})
    assert_receive {:controlled_prompt, "second", "TO_SECOND", later_second}
    send(later_second, {:result, "DONE"})
    assert {:ok, :completed, %{text: "DONE"}} = await_poll(name, later)
  end

  test "Consensus fanout rejection discards accepted peer response and resets phase", %{
    name: name
  } do
    {:ok, _} =
      Ensemble.start_link(
        name: name,
        strategy: Consensus,
        opts: [agents: [agent("a"), agent("b")], rounds: 1, verdict_parser: &{:ok, :yes, &1}]
      )

    external =
      Task.async(fn -> GenAgent.ask(GenAgentEnsemble.member_name(name, "b"), "external") end)

    assert_receive {:controlled_prompt, "b", "external", external_task}

    failed = ask_async(name, "failed")
    assert_receive {:controlled_prompt, "a", "failed", peer_task}
    assert {:error, {"b", {:overloaded, _}}} = Task.await(failed)
    assert {:ok, %{phase: :idle, queued: 0}} = Ensemble.status(name)

    send(peer_task, {:result, "STALE"})
    send(external_task, {:result, "EXTERNAL"})
    assert {:ok, %{text: "EXTERNAL"}} = Task.await(external)

    later = ask_async(name, "later")
    assert_receive {:controlled_prompt, "a", "later", later_a}
    assert_receive {:controlled_prompt, "b", "later", later_b}
    send(later_a, {:result, "A"})
    send(later_b, {:result, "B"})
    assert {:ok, %{text: text}} = Task.await(later)
    assert text =~ "A"
    assert text =~ "B"
    refute text =~ "STALE"
  end
end
