defmodule GenAgentEnsemble.HaltResultsTest do
  use ExUnit.Case, async: false

  alias GenAgent.{Event, Response}
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend, HaltSupport, Server}

  # Every callback reports to the observer as {:callback, name, detail}.
  # Operations come from the call options (`ops:`, with :token bound to the
  # request's token), from notify/2 (`{:ops, ops}`), and from the `on_*`
  # rejection options. `park: true` blocks the callback inside the server
  # until it receives :release_callback.
  defmodule Strategy do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(opts) do
      {:ok, %{observer: Keyword.fetch!(opts, :observer), opts: opts},
       Keyword.get(opts, :agents, [])}
    end

    @impl true
    def handle_tell(prompt, opts, token, state),
      do: request(prompt, :handle_tell, opts, token, state)

    @impl true
    def handle_ask(prompt, opts, token, state),
      do: request(prompt, :handle_ask, opts, token, state)

    @impl true
    def handle_response(agent, _response, state), do: record(:handle_response, agent, [], state)

    @impl true
    def handle_error(agent, _reason, state), do: record(:handle_error, agent, [], state)

    @impl true
    def handle_agent_down(agent, _reason, state), do: record(:handle_agent_down, agent, [], state)

    @impl true
    def handle_cancel(token, state), do: record(:handle_cancel, token, [], state)

    @impl true
    def handle_dispatch_rejected(agent, token, _reason, state) do
      ops = state.opts |> Keyword.get(:on_dispatch_rejected, []) |> bind(token)
      record(:handle_dispatch_rejected, agent, ops, state)
    end

    @impl true
    def handle_start_rejected(agent, _reason, state) do
      ops = state.opts |> Keyword.get(:on_start_rejected, []) |> bind(nil)
      record(:handle_start_rejected, agent, ops, state)
    end

    @impl true
    def handle_notify({:ops, ops}, state), do: record(:handle_notify, :ops, ops, state)
    def handle_notify(event, state), do: record(:handle_notify, event, [], state)

    # Tries to replace the server-owned keys.
    @impl true
    def handle_status(state) do
      send(state.observer, {:callback, :handle_status, nil})
      %{strategy_extra: :present, lifecycle: :fake, admission: :fake, member_names: :fake}
    end

    defp request(_prompt, callback, opts, token, state) do
      send(state.observer, {:callback, callback, token})

      if Keyword.get(opts, :park) do
        send(state.observer, {:parked, self()})

        receive do
          :release_callback -> :ok
        end
      end

      {:ok, opts |> Keyword.get(:ops, []) |> bind(token), state}
    end

    defp record(callback, detail, ops, state) do
      send(state.observer, {:callback, callback, detail})
      {:ok, ops, state}
    end

    defp bind(ops, token) do
      Enum.map(ops, fn op ->
        op
        |> Tuple.to_list()
        |> Enum.map(fn
          :token -> token
          other -> other
        end)
        |> List.to_tuple()
      end)
    end
  end

  # An agent whose shutdown callbacks block until the test releases them, so
  # tree cleanup can be held open deterministically.
  defmodule SlowBackend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts), do: {:ok, opts}

    @impl true
    def prompt(session, _prompt), do: {:ok, [], session}

    @impl true
    def terminate_session(session) do
      send(session[:observer], {:backend_terminating, self()})
      SlowBackend.await_release(:release_backend)
      :ok
    end

    def await_release(message) do
      receive do
        ^message -> :ok
      after
        5_000 -> raise "shutdown callback was not released"
      end
    end
  end

  defmodule SlowAgent do
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, opts, opts}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}

    @impl true
    def terminate_agent(reason, state) do
      send(state[:observer], {:agent_terminating, self(), reason})
      SlowBackend.await_release(:release_agent)
      :ok
    end
  end

  @events for scope <- [:session, :token, :dispatch, :admission],
              event <- [:start, :stop, :halt, :error, :rejected],
              do: [:gen_agent_ensemble, scope, event]

  setup do
    %{name: "halt-results-#{System.unique_integer([:positive])}"}
  end

  # --- helpers ---

  defp start(name, extra \\ [], server_opts \\ []) do
    {:ok, pid} =
      E.start_link(
        [name: name, strategy: Strategy, opts: [observer: self()] ++ extra] ++ server_opts
      )

    on_exit(fn ->
      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  defp controlled_agent do
    {"w", ControlledAgent, [backend: ControlledBackend, observer: self(), tag: "w"]}
  end

  defp slow_agent do
    {"worker", SlowAgent, [backend: SlowBackend, observer: self()]}
  end

  defp slow_options(name) do
    [name: name, strategy: Strategy, opts: [observer: self(), agents: [slow_agent()]]]
  end

  defp watch_telemetry do
    id = "halt-results-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        id,
        @events,
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp drain_telemetry(acc \\ []) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        drain_telemetry([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp flush_callbacks do
    receive do
      {:callback, _, _} -> flush_callbacks()
    after
      0 -> :ok
    end
  end

  # Observe the actual API call entering the server's mailbox, then use a
  # system-message barrier to inspect registration. No scheduling sleeps.
  defp waiter(pid, name, token, timeout \\ :infinity) do
    task =
      Task.async(fn ->
        receive do
          :go -> E.await(name, token, timeout)
        end
      end)

    :erlang.trace(task.pid, true, [:send])
    send(task.pid, :go)
    task_pid = task.pid
    assert_receive {:trace, ^task_pid, :send, {:"$gen_call", _, {:await, ^token, ^timeout}}, ^pid}
    :erlang.trace(task.pid, false, [:send])
    state = :sys.get_state(pid)
    assert Enum.any?(state.waiters[token], fn {_, {from, _}} -> elem(from, 0) == task.pid end)
    task
  end

  # Runs `fun` in a task and returns once its call is in the server's mailbox.
  defp queue_call(pid, fun) do
    task =
      Task.async(fn ->
        receive do
          :go -> fun.()
        end
      end)

    :erlang.trace(task.pid, true, [:send])
    send(task.pid, :go)
    task_pid = task.pid
    assert_receive {:trace, ^task_pid, :send, {:"$gen_call", _, _}, ^pid}
    :erlang.trace(task.pid, false, [:send])
    task
  end

  # terminate/2 unregisters the name before it waits for the owned tree.
  defp await_unregistered(server, attempts \\ 200) do
    cond do
      Registry.keys(GenAgentEnsemble.Registry, server) == [] ->
        :ok

      attempts > 0 ->
        Process.sleep(5)
        await_unregistered(server, attempts - 1)

      true ->
        flunk("session did not begin terminating")
    end
  end

  # The tree EXIT is consumed asynchronously after the tree dies.
  defp await_tree_released(server, attempts \\ 200) do
    cond do
      :sys.get_state(server).agent_tree == nil ->
        :ok

      attempts > 0 ->
        Process.sleep(5)
        await_tree_released(server, attempts - 1)

      true ->
        flunk("halted session never consumed its tree exit")
    end
  end

  defp halt_slow_session(server, name) do
    agent = GenAgent.whereis(GenAgentEnsemble.member_name(name, "worker"))
    assert {:ok, token} = E.tell(name, "go", ops: [{:halt, :slow}])
    assert_receive {:agent_terminating, ^agent, :shutdown}, 2_000
    assert Process.alive?(server)
    {agent, token}
  end

  # --- results and waiters ---

  test "an earlier success survives, pending work fails, and results are consumed once", %{
    name: name
  } do
    start(name)
    {:ok, early} = E.tell(name, "early", ops: [{:reply, :token, :won}])
    {:ok, plain} = E.tell(name, "plain")
    {:ok, notified} = E.tell_with_completion(name, "notified", self())
    ask = Task.async(fn -> E.ask(name, "asked") end)
    assert_receive {:callback, :handle_ask, _}

    ops = [
      {:halt, :first},
      {:reply, plain, :trailing},
      {:reply_error, notified, :trailing},
      {:halt, :second}
    ]

    E.notify(name, {:ops, ops})

    assert Task.await(ask) == {:error, {:halted, :first}}

    assert_receive {:gen_agent_ensemble, :completion, ^name, ^notified,
                    {:error, {:halted, :first}}}

    refute_receive {:gen_agent_ensemble, :completion, ^name, _, _}, 0

    assert E.await(name, early, 0) == {:ok, :won}

    for _ <- 1..2 do
      assert E.await(name, plain, 0) == {:error, {:halted, :first}}
    end

    assert E.poll(name, plain) == {:error, {:halted, :first}}
    assert E.poll(name, plain) == {:error, :not_found}
    assert E.await(name, plain, 0) == {:error, :not_found}

    assert {:ok, entries} = E.inbox(name)

    assert Enum.sort(entries) ==
             Enum.sort([{early, {:ok, :won}}, {notified, {:error, {:halted, :first}}}])

    assert E.inbox(name) == {:ok, []}
    assert {:ok, %{lifecycle: :halted}} = E.status(name)
  end

  test "halt answers every waiter and releases timers, monitors, streams and capacity", %{
    name: name
  } do
    pid = start(name)
    {:ok, a} = E.tell_with_completion(name, "a", self(), stream_to: self())
    {:ok, b} = E.tell(name, "b")
    ask = Task.async(fn -> E.ask(name, "asked") end)
    assert_receive {:callback, :handle_ask, _}

    finite = waiter(pid, name, a, 60_000)
    infinite = waiter(pid, name, a)
    other = waiter(pid, name, b)

    before = :sys.get_state(pid)
    assert map_size(before.stream_recipients) == 1
    assert before.pending_prompt_bytes > 0
    timers = for {_, {_, timer}} <- before.waiters[a], timer != nil, do: timer
    mrefs = Map.keys(before.waiter_monitors)
    assert length(timers) == 1

    E.notify(name, {:ops, [{:halt, :done}]})

    assert Task.await(finite) == {:error, {:halted, :done}}
    assert Task.await(infinite) == {:error, {:halted, :done}}
    assert Task.await(other) == {:error, {:halted, :done}}
    assert Task.await(ask) == {:error, {:halted, :done}}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^a, {:error, {:halted, :done}}}

    # Drain the expected asynchronous tree EXIT before comparing stale-message effects.
    await_tree_released(pid)
    halted = :sys.get_state(pid)
    assert halted.pending == %{}
    assert halted.token_contexts == %{}
    assert halted.stream_recipients == %{}
    assert halted.waiters == %{}
    assert halted.waiter_monitors == %{}
    assert halted.pending_prompt_bytes == 0
    for timer <- timers, do: assert(Process.read_timer(timer) == false)

    # The ask was never cached; the two tells were.
    assert {:ok, entries} = E.inbox(name)
    assert Enum.sort(Enum.map(entries, &elem(&1, 0))) == Enum.sort([a, b])

    # Stale timeouts and monitor messages change nothing.
    for mref <- mrefs do
      send(pid, {:await_timeout, mref})
      send(pid, {:DOWN, mref, :process, self(), :killed})
    end

    assert :sys.get_state(pid) == %{halted | completed: %{}, completed_order: :queue.new()}

    assert {:ok, %{admission: %{pending_count: 0, pending_bytes: 0}}} = E.status(name)
  end

  for retain <- [0, 1, 2, 4] do
    test "halt results follow retention #{retain} while waiters and recipients still receive them",
         %{name: name} do
      retain = unquote(retain)
      pid = start(name, [], max_completed_results: retain)
      {:ok, early} = E.tell(name, "early", ops: [{:reply, :token, :won}])

      pending =
        for prompt <- ["one", "two", "three"] do
          {:ok, token} = E.tell_with_completion(name, prompt, self())
          token
        end

      waiting = waiter(pid, name, hd(pending))
      E.notify(name, {:ops, [{:halt, :h}]})

      assert Task.await(waiting) == {:error, {:halted, :h}}

      for token <- pending do
        assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:error, {:halted, :h}}}
      end

      refute_receive {:gen_agent_ensemble, :completion, ^name, _, _}, 0

      # Which halt result survives a small bound is unspecified; the bound is not.
      assert {:ok, entries} = E.inbox(name)
      assert length(entries) == retain

      for {token, result} <- entries do
        if token == early,
          do: assert(result == {:ok, :won}),
          else: assert(result == {:error, {:halted, :h}})
      end

      # The earlier success is only lost to the bound, never rewritten.
      assert early in Enum.map(entries, &elem(&1, 0)) == (retain == 4)
      assert E.inbox(name) == {:ok, []}
    end
  end

  # --- what a halt stops ---

  test "calls queued behind a parked callback are refused after its halt", %{name: name} do
    pid = start(name)
    watch_telemetry()
    me = self()

    parked = Task.async(fn -> E.ask(name, "parked", park: true, ops: [{:halt, :parked}]) end)
    assert_receive {:parked, ^pid}
    assert_receive {:callback, :handle_ask, _}

    queued = [
      queue_call(pid, fn -> E.ask(name, "q-ask") end),
      queue_call(pid, fn -> E.tell(name, "q-tell") end),
      queue_call(pid, fn -> E.tell_with_completion(name, "q-comp", me, stream_to: me) end)
    ]

    send(pid, :release_callback)

    assert Task.await(parked) == {:error, {:halted, :parked}}
    for task <- queued, do: assert(Task.await(task) == {:error, {:halted, :parked}})

    # The normalized internal forms are refused identically.
    for request <- [
          {:tell, "x", []},
          {:tell, "x", [], nil},
          {:tell, "x", [], me, me},
          {:ask, "x", []}
        ] do
      assert GenServer.call(pid, request) == {:error, {:halted, :parked}}
    end

    refute_receive {:callback, _, _}, 0
    refute_received {:gen_agent_ensemble, _, _, _, _}

    events = drain_telemetry()
    assert [_] = for({[_, :token, :start], _, _} = event <- events, do: event)
    assert [] = for({[_, :admission, :rejected], _, _} = event <- events, do: event)
  end

  test "the first halt wins and ends its batch, including nested callback batches", %{
    name: name
  } do
    pid = start(name)
    {:ok, p1} = E.tell(name, "1")
    {:ok, p2} = E.tell(name, "2")
    late = {"late", GenAgentEnsemble.TestAgent, [backend: GenAgent.Backends.Mock]}

    # A halt message from the removed deferred path means nothing, running or not.
    send(pid, {:halt_session, :stale})
    assert {:ok, %{lifecycle: :running}} = E.status(name)

    ops = [
      {:reply, p1, :won},
      {:halt, :first},
      {:start, late},
      {:dispatch, "late", "prompt", p2},
      {:forward, "late", :event},
      {:reply_error, p2, :trailing},
      {:halt, :second}
    ]

    E.notify(name, {:ops, ops})
    assert E.await(name, p1, 0) == {:ok, :won}
    assert E.await(name, p2, 0) == {:error, {:halted, :first}}
    assert GenAgent.whereis(GenAgentEnsemble.member_name(name, "late")) == nil

    E.notify(name, {:ops, [{:halt, :third}]})
    send(pid, {:halt_session, :stale})
    assert HaltSupport.assert_halted(name, :first)
  end

  test "any term is a valid halt reason, including nil and false", %{name: name} do
    for {reason, index} <- Enum.with_index([nil, false, 0, {:k, "v"}]) do
      session = "#{name}-#{index}"
      start(session)
      assert {:ok, token} = E.tell(session, "go", ops: [{:halt, reason}])
      assert E.await(session, token, 0) == {:error, {:halted, reason}}
      assert E.ask(session, "x") == {:error, {:halted, reason}}
      assert {:ok, %{lifecycle: :halted}} = E.status(session)
    end
  end

  test "a halt from a rejected dispatch callback ends the outer batch and closes the token", %{
    name: name
  } do
    start(name, on_dispatch_rejected: [{:halt, :nested}, {:reply_error, :token, :ignored}])

    assert {:ok, token} =
             E.tell(name, "go", ops: [{:dispatch, "missing", "p", :token}, {:reply, :token, :no}])

    assert E.await(name, token, 0) == {:error, {:halted, :nested}}
    assert HaltSupport.assert_halted(name, :nested)
  end

  test "a halt from a rejected start callback ends the outer batch and closes the token", %{
    name: name
  } do
    start(name, on_start_rejected: [{:halt, :start_nested}])
    assert {:ok, token} = E.tell(name, "go", ops: [{:start, {"bad"}}, {:reply, :token, :skipped}])
    assert E.await(name, token, 0) == {:error, {:halted, :start_nested}}
    assert HaltSupport.assert_halted(name, :start_nested)
  end

  test "no strategy callback or late message affects a halted session", %{name: name} do
    pid = start(name, agents: [controlled_agent()])
    reason = {:secret, "s3cr3t"}

    {:ok, scoped} = E.tell(name, "scoped", ops: [{:dispatch, "w", "scoped", :token}])
    assert_receive {:controlled_prompt, "w", "scoped", _backend}
    E.notify(name, {:ops, [{:dispatch, "w", "unscoped"}]})

    # While running the strategy's extras appear but cannot replace server keys.
    assert {:ok, running} = E.status(name)
    assert running.strategy_extra == :present
    assert running.lifecycle == :running
    assert running.in_flight == 2
    assert is_map(running.admission)
    assert running.member_names == %{"w" => E.member_name(name, "w")}

    before = :sys.get_state(pid)
    refs = Map.keys(before.in_flight)
    monitor_refs = Map.keys(before.monitors)
    assert length(refs) == 2

    flush_callbacks()
    E.notify(name, {:ops, [{:halt, reason}]})
    assert {:ok, status} = E.status(name)
    flush_callbacks()

    assert status.lifecycle == :halted
    refute Map.has_key?(status, :strategy_extra)
    assert status.admission.pending_count == 0
    assert status.in_flight == 0
    assert status.member_names == %{}
    # Drain the expected asynchronous tree EXIT before comparing stale-message effects.
    await_tree_released(pid)
    halted = :sys.get_state(pid)

    for ref <- refs do
      send(
        pid,
        {:gen_agent, :completion, GenAgentEnsemble.member_name(name, "w"), ref,
         {:ok, %Response{text: "late"}}}
      )

      send(
        pid,
        {:gen_agent, :completion, GenAgentEnsemble.member_name(name, "w"), ref, {:error, :late}}
      )

      send(
        pid,
        {:gen_agent, :event, GenAgentEnsemble.member_name(name, "w"), ref, Event.new(:text)}
      )
    end

    for mref <- monitor_refs, do: send(pid, {:DOWN, mref, :process, self(), :killed})
    send(pid, {:halt_session, :stale})
    E.notify(name, :another)
    E.notify(name, {:ops, [{:reply, scoped, :overwrite}, {:halt, :other}]})

    assert :sys.get_state(pid) == halted
    refute_receive {:callback, _, _}, 0
    refute_received {:gen_agent_ensemble, _, _, _, _}

    # Cancellation finds nothing to cancel and never reaches the strategy.
    assert E.cancel(name, scoped) == {:error, :already_finished}
    assert E.cancel(name, "tok-unknown") == {:error, :not_found}
    assert E.await(name, scoped, 0) == {:error, {:halted, reason}}
    refute_receive {:callback, _, _}, 0

    # The reason is reachable by callers but not by crash reports or status.
    assert halted.halt_reason == reason
    assert %{state: redacted} = Server.format_status(%{state: halted})
    assert redacted.halt_reason == :redacted
    assert redacted.lifecycle == :halted
    refute inspect(Server.format_status(%{state: halted})) =~ "s3cr3t"
    refute inspect(status) =~ "s3cr3t"
  end

  # --- telemetry ---

  test "halt retires every open dispatch and pending token exactly once", %{name: name} do
    pid = start(name, agents: [controlled_agent()])
    watch_telemetry()
    reason = {:secret, "s3cr3t"}

    {:ok, early} = E.tell(name, "early", ops: [{:reply, :token, :won}])
    {:ok, scoped} = E.tell(name, "scoped", ops: [{:dispatch, "w", "scoped", :token}])
    assert_receive {:controlled_prompt, "w", "scoped", _backend}
    E.notify(name, {:ops, [{:dispatch, "w", "unscoped"}]})
    {:ok, waiting} = E.tell(name, "waiting")
    assert {:ok, %{in_flight: 2}} = E.status(name)

    starts = drain_telemetry()
    assert [_, _] = for({[_, :dispatch, :start], _, _} = event <- starts, do: event)

    E.notify(name, {:ops, [{:halt, reason}]})
    assert {:ok, %{lifecycle: :halted}} = E.status(name)
    events = drain_telemetry()

    assert [_] = for({[_, :session, :halt], _, _} = event <- events, do: event)
    assert [] = for({[_, :session, :stop], _, _} = event <- events, do: event)

    dispatch_errors = for {[_, :dispatch, :error], _, meta} <- events, do: meta
    assert Enum.all?(dispatch_errors, &(&1.reason_kind == :halted))
    assert Enum.sort(Enum.map(dispatch_errors, & &1.token)) == Enum.sort([scoped, nil])

    token_errors = for {[_, :token, :error], _, meta} <- events, do: meta
    assert Enum.all?(token_errors, &(&1.reason_kind == :halted))
    assert Enum.sort(Enum.map(token_errors, & &1.token)) == Enum.sort([scoped, waiting])
    assert [] = for({[_, :token, :stop], _, _} = event <- events, do: event)
    refute inspect(events) =~ "s3cr3t"

    # Already finished work is not reported again, and refusals emit nothing.
    assert E.ask(name, "refused") == {:error, {:halted, reason}}
    assert E.await(name, early, 0) == {:ok, :won}
    assert :sys.get_state(pid).lifecycle == :halted
    assert drain_telemetry() == []

    assert :ok = E.stop(name)
    assert [{[_, :session, :stop], _, meta}] = drain_telemetry()
    assert %{session: ^name, outcome: :halted, reason_kind: :normal} = meta
  end

  # --- tree shutdown ---

  test "reads and refusals stay served while child shutdown is blocked", %{name: name} do
    {:ok, server} = E.start_link(slow_options(name))

    on_exit(fn ->
      send(
        GenAgent.whereis(GenAgentEnsemble.member_name(name, "worker")) || self(),
        :release_agent
      )
    end)

    watched = HaltSupport.watch(server)
    %{agent_tree: tree} = :sys.get_state(server)
    agent = GenAgent.whereis(GenAgentEnsemble.member_name(name, "worker"))
    agent_ref = Process.monitor(agent)

    {:ok, early} = E.tell(name, "early", ops: [{:reply, :token, :won}])
    {_agent, token} = halt_slow_session(server, name)

    # Cleanup is held inside the child, yet the façade answers promptly.
    assert Process.alive?(tree)
    assert E.await(name, early, 0) == {:ok, :won}
    assert E.await(name, token, 0) == {:error, {:halted, :slow}}
    HaltSupport.assert_halted(name, :slow)
    assert Process.alive?(tree)
    assert Registry.lookup(GenAgentEnsemble.Registry, name) == [{server, nil}]

    send(agent, :release_agent)
    assert_receive {:backend_terminating, ^agent}, 2_000
    assert Process.alive?(tree)
    send(agent, :release_backend)

    assert_receive {:DOWN, ^agent_ref, :process, ^agent, _}, 2_000
    HaltSupport.assert_tree_gone(watched)
    assert E.await(name, token, 0) == {:error, {:halted, :slow}}
    HaltSupport.assert_halted(name, :slow)
    assert Registry.lookup(GenAgentEnsemble.Registry, name) == [{server, nil}]

    # Nothing left to wait for.
    assert :ok = E.stop(name)
    assert_receive {:DOWN, _, :process, ^server, :normal}, 2_000
  end

  test "an explicit stop during cleanup waits for it, then disposes the session", %{name: name} do
    {:ok, server} = E.start_link(slow_options(name))
    watch_telemetry()
    watched = HaltSupport.watch(server)
    {agent, _token} = halt_slow_session(server, name)
    drain_telemetry()

    stop = Task.async(fn -> E.stop(name) end)
    await_unregistered(server)
    assert Process.alive?(server)
    assert Registry.lookup(GenAgentEnsemble.Registry, name) == []
    stop_ref = stop.ref
    refute_receive {^stop_ref, _}, 50

    send(agent, :release_agent)
    assert_receive {:backend_terminating, ^agent}, 2_000
    send(agent, :release_backend)

    assert Task.await(stop) == :ok
    server_ref = watched.server_ref
    assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}, 2_000
    for {pid, ref} <- watched.owned, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 2_000)

    # One stop for the whole life, and no second report for settled work.
    events = drain_telemetry()
    assert [{[_, :session, :stop], _, %{outcome: :halted}}] = events
  end

  for reason <- [:normal, :shutdown, :killed] do
    test "owner exit #{reason} during cleanup still stops the session after it", %{name: name} do
      observer = self()
      options = slow_options(name)
      reason = unquote(reason)

      owner =
        spawn(fn ->
          {:ok, server} = E.start_link(options)
          send(observer, {:started, server})

          receive do
            :finish -> exit(reason)
          end
        end)

      on_exit(fn -> Process.exit(owner, :kill) end)
      assert_receive {:started, server}, 2_000
      ref = Process.monitor(server)
      {agent, _token} = halt_slow_session(server, name)

      send(owner, :finish)
      await_unregistered(server)
      assert Process.alive?(server)
      refute_received {:DOWN, ^ref, :process, ^server, _}

      send(agent, :release_agent)
      assert_receive {:backend_terminating, ^agent}, 2_000
      send(agent, :release_backend)
      assert_receive {:DOWN, ^ref, :process, ^server, ^reason}, 2_000
    end

    test "owner exit #{reason} after cleanup stops the session without touching the tree", %{
      name: name
    } do
      observer = self()
      options = slow_options(name)
      reason = unquote(reason)

      owner =
        spawn(fn ->
          {:ok, server} = E.start_link(options)
          send(observer, {:started, server})

          receive do
            :finish -> exit(reason)
          end
        end)

      on_exit(fn -> Process.exit(owner, :kill) end)
      assert_receive {:started, server}, 2_000
      watched = HaltSupport.watch(server)
      {agent, _token} = halt_slow_session(server, name)
      send(agent, :release_agent)
      assert_receive {:backend_terminating, ^agent}, 2_000
      send(agent, :release_backend)
      HaltSupport.assert_tree_gone(watched)
      await_tree_released(server)

      send(owner, :finish)
      server_ref = watched.server_ref
      assert_receive {:DOWN, ^server_ref, :process, ^server, ^reason}, 2_000
    end
  end

  test "an unexpected tree exit remains fatal after logical halt", %{name: name} do
    {:ok, server} = E.start_link(slow_options(name))
    Process.unlink(server)
    tree = :sys.get_state(server).agent_tree
    {agent, _token} = halt_slow_session(server, name)

    on_exit(fn ->
      send(agent, :release_agent)
      send(agent, :release_backend)
    end)

    ref = Process.monitor(server)

    # This is a supervisor-failure exit, not the tagged cleanup we requested.
    send(server, {:EXIT, tree, :shutdown})
    await_unregistered(server)
    assert Process.alive?(server)
    send(agent, :release_agent)
    assert_receive {:backend_terminating, ^agent}, 2_000
    send(agent, :release_backend)
    assert_receive {:DOWN, ^ref, :process, ^server, :shutdown}, 2_000
  end

  test "a tree exit while running still stops the session", %{name: name} do
    pid = start(name)
    Process.unlink(pid)
    ref = Process.monitor(pid)
    %{agent_tree: tree} = :sys.get_state(pid)

    # Only a halted session expects the :shutdown it asked for.
    send(pid, {:EXIT, tree, :shutdown})
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 2_000
  end
end
