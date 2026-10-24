defmodule GenAgentEnsemble.StrategyCallbackContainmentTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend, Server}

  defmodule Strategy do
    @behaviour GenAgentEnsemble.Strategy
    def init(opts), do: {:ok, Map.new(opts), Keyword.get(opts, :agents, [])}

    def handle_tell(prompt, opts, token, state),
      do: request(:handle_tell, prompt, opts, token, state)

    def handle_ask(prompt, opts, token, state),
      do: request(:handle_ask, prompt, opts, token, state)

    defp request(callback, prompt, opts, token, state) do
      send(state.observer, {:request, callback, token})

      if prompt == "fail",
        do: result(callback, token, state),
        else: {:ok, Keyword.get(opts, :ops, fn _ -> [] end).(token), state}
    end

    def handle_notify({:ops, ops}, state), do: {:ok, ops, state}
    def handle_notify(_, state), do: result(:handle_notify, state.token, state)
    def handle_response(_, _, state), do: result(:handle_response, state.token, state)
    def handle_error(_, _, state), do: result(:handle_error, state.token, state)
    def handle_agent_down(_, _, state), do: result(:handle_agent_down, state.token, state)
    def handle_cancel(token, state), do: result(:handle_cancel, token, state)
    def handle_start_rejected(_, _, state), do: result(:handle_start_rejected, state.token, state)

    def handle_dispatch_rejected(_, token, _, state),
      do: result(:handle_dispatch_rejected, token, state)

    defp result(callback, token, state) do
      send(state.observer, {:failed_callback, callback})

      case state.mode do
        :error ->
          raise "callback-secret-sentinel"

        :throw ->
          throw("callback-secret-sentinel")

        :exit ->
          exit("callback-secret-sentinel")

        :shape ->
          {:secret, "callback-secret-sentinel"}

        :ops ->
          {:ok, :invalid, :poison}

        :improper ->
          {:ok, [{:reply, token, :prefix_must_not_run} | "callback-secret-sentinel"], :poison}
      end
    end
  end

  defmodule HeldMember do
    use GenAgent

    def init_agent(opts) do
      send(opts[:observer], {:held_start, self()})

      receive do
        :release_start -> {:ok, [], %{}}
      end
    end

    def handle_response(_, _, state), do: {:noreply, state}
  end

  test "callback failure retires a held lifecycle worker and ignores its late correlated result" do
    name = "held-callback-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      E.start_link(name: name, strategy: Strategy, opts: [observer: self(), mode: :throw])

    on_exit(fn -> stop_session(pid) end)
    {:ok, early} = E.tell(name, "early", ops: fn token -> [{:reply, token, :won}] end)
    observer = self()

    {:ok, pending} =
      E.tell(name, "start",
        ops: fn token ->
          [
            {:start, {"held", HeldMember, [backend: ControlledBackend, observer: observer]}},
            {:reply, token, :tail}
          ]
        end
      )

    assert_receive {:held_start, child}
    on_exit(fn -> send(child, :release_start) end)
    child_monitor = Process.monitor(child)
    tree_monitor = Process.monitor(:sys.get_state(pid).agent_tree)
    before = :sys.get_state(pid)
    active = before.runtime.active
    monitor = Process.monitor(active.worker)

    :sys.replace_state(pid, fn state ->
      %{state | strategy_state: Map.put(state.strategy_state, :token, pending)}
    end)

    E.notify(name, :fail)
    reason = {:strategy_callback_failed, :handle_notify, :throw}
    assert E.await(name, pending, 0) == {:error, {:halted, reason}}
    assert E.await(name, early, 0) == {:ok, :won}
    assert_receive {:DOWN, ^monitor, :process, _, _}
    halted = :sys.get_state(pid)
    assert halted.runtime.active == nil
    assert :queue.is_empty(halted.runtime.queue)

    send(
      pid,
      {:lifecycle_result, active.id, active.worker, before.agent_supervisor, active.argument,
       {:ok, child}}
    )

    assert E.await(name, pending, 0) == {:error, {:halted, reason}}
    send(child, :release_start)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, _}, 2_000
    assert_receive {:DOWN, ^tree_monitor, :process, _, _}, 2_000
    assert {:ok, %{lifecycle: :halted}} = E.status(name)
  end

  @callbacks [
    :handle_tell,
    :handle_ask,
    :handle_notify,
    :handle_response,
    :handle_error,
    :handle_agent_down,
    :handle_cancel,
    :handle_start_rejected,
    :handle_dispatch_rejected
  ]
  for callback <- @callbacks, mode <- [:error, :throw, :exit, :shape, :ops, :improper] do
    @tag :callback_matrix
    test "#{callback} #{mode} halts current ownership and retains results" do
      callback = unquote(callback)
      mode = unquote(mode)
      name = "callback-#{System.unique_integer([:positive])}"
      agents = [{"w", ControlledAgent, [backend: ControlledBackend, observer: self(), tag: "w"]}]

      {:ok, pid} =
        E.start_link(
          name: name,
          strategy: Strategy,
          opts: [observer: self(), mode: mode, agents: agents],
          max_completed_results: 20
        )

      on_exit(fn -> stop_session(pid) end)
      {:ok, early} = E.tell(name, "early", ops: fn token -> [{:reply, token, :won}] end)

      {:ok, active} =
        E.tell_with_completion(name, "active", self(),
          ops: fn token -> [{:dispatch, "w", "held", token}] end
        )

      assert_receive {:controlled_prompt, "w", "held", _}

      {:ok, queued} =
        E.tell(name, "queued", ops: fn token -> [{:dispatch, "w", "queued", token}] end)

      ask = Task.async(fn -> E.ask(name, "blocked") end)
      assert_receive {:request, :handle_ask, _}
      refs = Map.keys(:sys.get_state(pid).in_flight)
      waiter = Task.async(fn -> E.await(name, active, :infinity) end)
      await_waiter(pid, active)

      :sys.replace_state(pid, fn state ->
        %{state | strategy_state: Map.put(state.strategy_state, :token, active)}
      end)

      reason =
        if mode in [:error, :throw, :exit],
          do: {:strategy_callback_failed, callback, mode},
          else: {:invalid_strategy_result, callback}

      terminal = {:error, {:halted, reason}}

      log =
        capture_log(fn ->
          trigger(callback, name, pid, active, terminal)
          assert Task.await(ask) == terminal
          assert Task.await(waiter) == terminal
          assert E.await(name, active, 0) == terminal
          assert E.await(name, queued, 0) == terminal
          assert E.await(name, early, 0) == {:ok, :won}
          assert_receive {:gen_agent_ensemble, :completion, ^name, ^active, ^terminal}
          refute_receive {:gen_agent_ensemble, :completion, ^name, ^active, _}, 0

          assert {:ok, %{lifecycle: :halted, admission: %{pending_count: 0, pending_bytes: 0}}} =
                   E.status(name)

          assert Process.alive?(pid)
          assert Registry.lookup(GenAgentEnsemble.Registry, name) == [{pid, nil}]
          assert :sys.get_state(pid).strategy_state == nil
          assert E.tell(name, "later") == terminal
          assert E.ask(name, "later") == terminal

          for ref <- refs do
            send(pid, {:gen_agent, :completion, E.member_name(name, "w"), ref, {:error, :late}})
          end

          E.notify(name, :fail)
          assert {:ok, %{lifecycle: :halted}} = E.status(name)
          state = :sys.get_state(pid)
          assert state.cancellations == %{}
          assert state.control_monitors == %{}
          assert state.cancelling_refs == %{}
          assert_receive {:failed_callback, ^callback}
          refute_receive {:failed_callback, _}, 0

          refute inspect(Server.format_status(%{state: :sys.get_state(pid)})) =~
                   "callback-secret-sentinel"
        end)

      refute log =~ "callback-secret-sentinel"
    end
  end

  defp trigger(:handle_tell, name, _, _, terminal) do
    assert {:ok, token} = E.tell(name, "fail")
    assert E.await(name, token, 0) == terminal
  end

  defp trigger(:handle_ask, name, _, _, terminal), do: assert(E.ask(name, "fail") == terminal)
  defp trigger(:handle_notify, name, _, _, _), do: E.notify(name, :fail)

  defp trigger(:handle_cancel, name, _, token, terminal),
    do: assert(E.cancel(name, token) == terminal)

  defp trigger(:handle_start_rejected, name, _, token, _),
    do: E.notify(name, {:ops, [{:start, {"bad"}}, {:reply, token, :tail}]})

  defp trigger(:handle_dispatch_rejected, name, _, token, _),
    do: E.notify(name, {:ops, [{:dispatch, "missing", "p", token}, {:reply, token, :tail}]})

  defp trigger(:handle_agent_down, _, pid, _, _),
    do: Process.exit(:sys.get_state(pid).agents["w"], :kill)

  defp trigger(callback, name, pid, active, _) do
    {ref, _} = Enum.find(:sys.get_state(pid).in_flight, fn {_, {_, token}} -> token == active end)

    outcome =
      if callback == :handle_response,
        do: {:ok, %GenAgent.Response{text: "ok"}},
        else: {:error, :controlled}

    send(pid, {:gen_agent, :completion, E.member_name(name, "w"), ref, outcome})
  end

  defp stop_session(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp await_waiter(pid, token, attempts \\ 1000) do
    if Map.has_key?(:sys.get_state(pid).waiters, token) do
      :ok
    else
      assert attempts > 0
      :erlang.yield()
      await_waiter(pid, token, attempts - 1)
    end
  end
end
