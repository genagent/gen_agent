defmodule GenAgentEnsemble.MemberNamesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.Agents.Simple
  alias GenAgentEnsemble.Backends.Echo
  alias GenAgentEnsemble.ControlledBackend

  defmodule ObservedAgent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      send(opts[:observer], {:member_started, opts[:tag], self()})
      {:ok, opts, %{observer: opts[:observer], events: []}}
    end

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}

    @impl true
    def handle_event(event, state) do
      send(state.observer, {:member_event, self(), event})
      {:noreply, %{state | events: [event | state.events]}}
    end
  end

  # A parked callback lets the test arrange DOWN/name reuse before its returned
  # operations execute, without letting the server handle that queued DOWN.
  defmodule Scripted do
    @behaviour GenAgentEnsemble.Strategy

    def init(opts),
      do: {:ok, %{observer: opts[:observer], token: nil}, Keyword.get(opts, :specs, [])}

    def handle_tell(prompt, opts, token, state) do
      if opts[:park] do
        send(state.observer, {:parked, self()})

        receive do
          :release_member_callback -> :ok
        end
      end

      ops =
        Keyword.get(opts, :ops, fn token -> [{:dispatch, opts[:agent] || "w", prompt, token}] end)

      {:ok, ops.(token), %{state | token: token}}
    end

    def handle_ask(prompt, opts, token, state), do: handle_tell(prompt, opts, token, state)

    def handle_response(_agent, response, state),
      do: {:ok, [{:reply, state.token, response}], state}

    def handle_notify({:ops, ops}, state), do: {:ok, ops, state}
    def handle_cancel(_token, state), do: {:ok, [], state}
    def handle_status(_state), do: %{member_names: :forged, custom: :preserved}
  end

  defmodule Reporting do
    @behaviour GenAgentEnsemble.Strategy

    defdelegate init(opts), to: Scripted
    defdelegate handle_tell(prompt, opts, token, state), to: Scripted
    defdelegate handle_ask(prompt, opts, token, state), to: Scripted
    defdelegate handle_response(agent, response, state), to: Scripted
    defdelegate handle_notify(event, state), to: Scripted

    def handle_start_rejected(agent, reason, state) do
      send(state.observer, {:start_rejected, agent, reason})
      {:ok, [{:reply_error, state.token, reason}], state}
    end

    def handle_dispatch_rejected(agent, token, reason, state) do
      send(state.observer, {:dispatch_rejected, agent, token, reason})
      # Deliberately rely on the framework's terminal-token fallback.
      {:ok, [], state}
    end
  end

  setup do
    %{name: "member-names-#{System.unique_integer([:positive])}"}
  end

  defp echo_spec(member), do: {member, Simple, [backend: Echo]}

  defp observed_spec(member) do
    {member, ObservedAgent,
     [backend: ControlledBackend, observer: self(), tag: member, api_key: "private-options"]}
  end

  defp start(name, specs, strategy \\ Scripted) do
    {:ok, server} =
      E.start_link(name: name, strategy: strategy, opts: [specs: specs, observer: self()])

    Process.unlink(server)

    on_exit(fn ->
      send(server, :release_member_callback)

      try do
        GenServer.stop(server, :normal, 10_000)
      catch
        :exit, _ -> :ok
      end
    end)

    server
  end

  defp foreign(key) do
    {_, module, opts} = observed_spec("foreign")
    {:ok, pid} = GenAgent.start_agent(module, Keyword.put(opts, :name, key))
    assert_receive {:member_started, "foreign", ^pid}
    on_exit(fn -> DynamicSupervisor.terminate_child(GenAgent.AgentSupervisor, pid) end)
    pid
  end

  def telemetry(event, measurements, metadata, observer),
    do: send(observer, {:member_telemetry, event, measurements, metadata})

  defp observe_telemetry do
    handler = {__MODULE__, make_ref()}

    events =
      for prefix <- [:gen_agent, :gen_agent_ensemble],
          scope <- [:prompt, :dispatch],
          event <- [:start, :stop, :error, :rejected],
          do: [prefix, scope, event]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp eventually(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected state was not observed")

      true ->
        :erlang.yield()
        eventually(fun, deadline)
    end
  end

  defp kill_while_parked(server, child, mref) do
    watch = Process.monitor(child)
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^watch, :process, ^child, :killed}, 2_000

    eventually(fn ->
      {:messages, messages} = Process.info(server, :messages)
      {:DOWN, mref, :process, child, :killed} in messages
    end)
  end

  defp assert_untouched(key, pid) do
    assert GenAgent.whereis(key) == pid
    assert %{current_request: nil, queued: 0, agent_state: %{events: []}} = GenAgent.status(key)
    refute_received {:member_event, ^pid, _}
    refute_received {:controlled_prompt, "foreign", _, _}
  end

  test "pure helper preserves exact shape and binary bytes without existence checks" do
    for session <- [:a, "a", 1, 1.0, "1", ~c"1", {:a, 1}, %{a: 1}, self(), make_ref()],
        member <- ["", <<255, 0>>, "/", "%2F", "é", "é"] do
      assert E.member_name(session, member) === {E, session, member}
      assert E.IEx.member_name(session, member) === E.member_name(session, member)
    end

    for member <- [:worker, 1, nil, [119], %{secret: "private"}] do
      assert_raise ArgumentError, "member name must be a binary", fn ->
        E.member_name(:s, member)
      end
    end
  end

  test "slash, percent, Unicode and typed sessions operate simultaneously", %{name: name} do
    id = System.unique_integer([:positive])

    pairs = [
      {name <> "/b", "c"},
      {name, "b/c"},
      {name <> "%2Fb", "c"},
      {name, "b%2Fc"},
      {name, "%"},
      {name, "é"},
      {name, "é"},
      {name, ""},
      {name, <<255>>},
      {:member_names_typed, "w"},
      {"member_names_typed", "w"},
      {id, "w"},
      {id * 1.0, "w"},
      {Integer.to_string(id), "w"},
      {Integer.to_charlist(id), "w"},
      {{:session, id}, "w"},
      {%{session: id}, "w"}
    ]

    for {session, entries} <- Enum.group_by(pairs, &elem(&1, 0)) do
      start(session, Enum.map(entries, fn {_, member} -> echo_spec(member) end))
    end

    pids =
      for {session, member} <- pairs do
        key = E.member_name(session, member)
        assert {:ok, %{text: "echo: unique"}} = E.ask(session, "unique", agent: member)
        assert {:ok, %{member_names: names, custom: :preserved}} = E.status(session)
        assert Map.fetch!(names, member) === key
        assert GenAgent.status(key).name === key
        assert Enum.any?(E.list(), &(&1 === session))
        assert Enum.any?(GenAgent.list(), &(&1 === key))
        GenAgent.whereis(key)
      end

    assert Enum.all?(pids, &is_pid/1)
    assert length(Enum.uniq(pids)) == length(pairs)
  end

  test "helper, status, core APIs, messages and telemetry agree", %{name: name} do
    observe_telemetry()
    start(name, [echo_spec("w")])
    key = E.member_name(name, "w")
    assert {:ok, %{member_names: %{"w" => ^key}, agents: ["w"]}} = E.status(name)
    assert %{name: ^key} = GenAgent.status(key)
    assert :ok = GenAgent.resume(key)
    assert :ok = GenAgent.interrupt(key)
    assert {:ok, %{text: "echo: ensemble"}} = E.ask(name, "ensemble")

    assert_receive {:member_telemetry, [:gen_agent_ensemble, :dispatch, :start], _,
                    %{session: ^name, agent: "w", member_name: ^key, ref: ref}}

    assert_receive {:member_telemetry, [:gen_agent, :prompt, :start], _,
                    %{agent: ^key, ref: ^ref}}

    assert_receive {:member_telemetry, [:gen_agent_ensemble, :dispatch, :stop], _,
                    %{member_name: ^key, ref: ^ref}}

    assert {:ok, core_ref} = GenAgent.tell_with_completion(key, "core", self())
    assert_receive {:gen_agent, :completion, ^key, ^core_ref, {:ok, %{text: "echo: core"}}}
  end

  test "standalone bare and old slash string names coexist", %{name: name} do
    legacy = name <> "/w"
    old = foreign(legacy)
    bare = foreign("w")
    start(name, [echo_spec("w")])
    assert {:ok, %{text: "echo: owned"}} = E.ask(name, "owned")
    :ok = E.stop(name)
    assert_untouched(legacy, old)
    assert_untouched("w", bare)
  end

  test "initial reserved-key conflict cleans siblings and tree but preserves foreign agent", %{
    name: name
  } do
    key = E.member_name(name, "w")
    outsider = foreign(key)

    assert {:error, {:member_name_conflict, "w"}} =
             E.start_link(
               name: name,
               strategy: Scripted,
               opts: [specs: [observed_spec("sibling"), observed_spec("w")], observer: self()]
             )

    assert_receive {:member_started, "sibling", sibling}
    watch = Process.monitor(sibling)
    assert_receive {:DOWN, ^watch, :process, ^sibling, _}
    eventually(fn -> Registry.lookup(E.AgentTreeRegistry, name) == [] end)
    eventually(fn -> Registry.lookup(E.Registry, name) == [] end)
    assert GenAgent.whereis(E.member_name(name, "sibling")) == nil
    refute_received {:member_started, "w", _}
    assert_untouched(key, outsider)

    duplicate_name = {name, :duplicate}

    assert {:error, {:duplicate_sub_agent, "w"}} =
             E.start_link(
               name: duplicate_name,
               strategy: Scripted,
               opts: [specs: [echo_spec("w"), echo_spec("w")]]
             )

    eventually(fn -> Registry.lookup(E.AgentTreeRegistry, duplicate_name) == [] end)
    assert GenAgent.whereis(E.member_name(duplicate_name, "w")) == nil
  end

  test "dynamic conflicts and unknown operations never adopt or route to foreign keys", %{
    name: name
  } do
    observe_telemetry()

    for strategy <- [Scripted, Reporting] do
      session = {name, strategy}
      key = E.member_name(session, "w")
      outsider = foreign(key)
      server = start(session, [], strategy)
      spec = observed_spec("w")

      log =
        capture_log(fn ->
          {:ok, token} =
            E.tell(session, "private-prompt",
              ops: fn token ->
                [{:start, spec}, {:dispatch, "w", "private-prompt", token}]
              end
            )

          if strategy == Reporting do
            assert E.await(session, token) == {:error, {:member_name_conflict, "w"}}
            assert_receive {:start_rejected, "w", {:member_name_conflict, "w"}}
          else
            assert E.await(session, token) ==
                     {:error, {:dispatch_rejected, "w", {:agent_not_running, "w"}}}

            assert_rejected(session, key, token)
          end
        end)

      assert log =~ "member_name_conflict"
      refute log =~ "private-options"
      refute log =~ "private-prompt"
      refute log =~ inspect(outsider)
      assert DynamicSupervisor.which_children(:sys.get_state(server).agent_supervisor) == []
      refute_received {:member_started, "w", _}

      E.notify(
        session,
        {:ops, [{:dispatch, "w", "unscoped"}, {:forward, "w", :event}, {:stop, "w"}]}
      )

      assert {:ok, %{member_names: names}} = E.status(session)
      assert names == %{}
      assert_rejected(session, key, nil)

      {:ok, token} = E.tell(session, "scoped")

      assert E.await(session, token) ==
               {:error, {:dispatch_rejected, "w", {:agent_not_running, "w"}}}

      assert_rejected(session, key, token)

      if strategy == Reporting,
        do: assert_receive({:dispatch_rejected, "w", ^token, {:agent_not_running, "w"}})

      assert_untouched(key, outsider)
      :ok = E.stop(session)
      assert Process.alive?(outsider)
    end
  end

  defp assert_rejected(session, key, token) do
    assert_receive {:member_telemetry, [:gen_agent_ensemble, :dispatch, :rejected], %{},
                    %{
                      session: ^session,
                      member_name: ^key,
                      agent: "w",
                      token: ^token,
                      ref: nil,
                      ordinal: nil,
                      reason_kind: :agent_not_running
                    }}

    refute_received {:member_telemetry, [:gen_agent_ensemble, :dispatch, :rejected], _,
                     %{session: ^session, token: ^token}}

    refute_received {:member_telemetry, [:gen_agent_ensemble, :dispatch, :start], _,
                     %{session: ^session, token: ^token}}
  end

  test "invalid spec and child-spec failures precede owned duplicates and foreign conflicts", %{
    name: name
  } do
    owned = start(name, [echo_spec("w")], Reporting)
    conflict_name = {name, :foreign}
    key = E.member_name(conflict_name, "w")
    outsider = foreign(key)
    start(conflict_name, [], Reporting)

    for session <- [name, conflict_name],
        {bad, field} <- [
          {{"w", nil, [backend: Echo]}, :module},
          {{"w", Simple, [backend: Echo, shutdown: -1]}, :child_spec}
        ] do
      {:ok, token} = E.tell(session, "invalid", ops: fn _ -> [{:start, bad}] end)
      assert E.await(session, token) == {:error, {:invalid_start_spec, field}}
      assert_receive {:start_rejected, "w", {:invalid_start_spec, ^field}}
    end

    assert is_pid(:sys.get_state(owned).agents["w"])
    assert_untouched(key, outsider)
  end

  test "dead slot is duplicate before queued DOWN, then admits a normal replacement", %{
    name: name
  } do
    spec = echo_spec("w")
    server = start(name, [spec], Reporting)
    %{agents: %{"w" => old}, monitors: monitors} = :sys.get_state(server)
    [{mref, "w"}] = Map.to_list(monitors)

    attempt =
      Task.async(fn ->
        E.tell(name, "replace",
          park: true,
          ops: fn _ -> [{:start, spec}] end
        )
      end)

    assert_receive {:parked, ^server}
    kill_while_parked(server, old, mref)
    send(server, :release_member_callback)
    {:ok, token} = Task.await(attempt)
    assert_receive {:start_rejected, "w", {:duplicate_sub_agent, "w"}}
    assert E.await(name, token) == {:error, {:duplicate_sub_agent, "w"}}
    assert {:ok, %{member_names: names}} = E.status(name)
    assert names == %{}

    E.notify(name, {:ops, [{:start, spec}]})
    assert {:ok, %{agents: ["w"]}} = E.status(name)
    replacement = GenAgent.whereis(E.member_name(name, "w"))
    assert is_pid(replacement) and replacement != old
    send(server, {:DOWN, mref, :process, old, :killed})
    [{current_ref, "w"}] = Map.to_list(:sys.get_state(server).monitors)
    send(server, {:DOWN, current_ref, :process, old, :killed})
    assert {:ok, %{text: "echo: replacement"}} = E.ask(name, "replacement")
    assert :sys.get_state(server).agents == %{"w" => replacement}
  end

  test "PID mismatch is rejected before queued DOWN and stop targets only the old PID", %{
    name: name
  } do
    observe_telemetry()
    server = start(name, [echo_spec("w")])
    %{agents: %{"w" => old}, monitors: monitors} = :sys.get_state(server)
    [{mref, "w"}] = Map.to_list(monitors)

    attempt =
      Task.async(fn ->
        E.tell(name, "replace",
          park: true,
          ops: fn token ->
            [
              {:dispatch, "w", "unscoped"},
              {:forward, "w", :event},
              {:dispatch, "w", "scoped", token}
            ]
          end
        )
      end)

    assert_receive {:parked, ^server}
    kill_while_parked(server, old, mref)
    key = E.member_name(name, "w")
    outsider = foreign(key)
    send(server, :release_member_callback)
    {:ok, token} = Task.await(attempt)
    assert E.await(name, token) == {:error, {:dispatch_rejected, "w", {:agent_not_running, "w"}}}
    assert_rejected(name, key, nil)
    assert_rejected(name, key, token)
    assert_untouched(key, outsider)

    # Explicit stop after retirement is an unknown stop; it must also spare it.
    E.notify(name, {:ops, [{:stop, "w"}]})
    assert {:ok, %{agents: []}} = E.status(name)
    assert_untouched(key, outsider)

    # Stop while the old slot is still tracked but its key belongs to a foreign
    # replacement. It must terminate/check absence by old PID, then demonitor.
    stop_name = {name, :stop_before_down}
    stop_server = start(stop_name, [echo_spec("w")])
    stop_state = :sys.get_state(stop_server)
    stopped = stop_state.agents["w"]
    [{stop_ref, "w"}] = Map.to_list(stop_state.monitors)

    stop_attempt =
      Task.async(fn ->
        E.tell(stop_name, "stop",
          park: true,
          ops: fn token ->
            [{:stop, "w"}, {:reply, token, :stopped}]
          end
        )
      end)

    assert_receive {:parked, ^stop_server}
    kill_while_parked(stop_server, stopped, stop_ref)
    stop_key = E.member_name(stop_name, "w")
    stop_outsider = foreign(stop_key)
    send(stop_server, :release_member_callback)
    {:ok, stop_token} = Task.await(stop_attempt)
    assert E.await(stop_name, stop_token) == {:ok, :stopped}
    assert :sys.get_state(stop_server).monitors == %{}
    assert :sys.get_state(stop_server).agents == %{}
    assert_untouched(stop_key, stop_outsider)
  end

  test "captured child death confirms cancellation without touching the replacement", %{
    name: name
  } do
    server = start(name, [observed_spec("w")])
    assert_receive {:member_started, "w", old}
    {:ok, token} = E.tell_with_completion(name, "old turn")
    assert_receive {:controlled_prompt, "w", "old turn", _old_task}
    [{old_ref, {"w", ^token}}] = Map.to_list(:sys.get_state(server).in_flight)

    :ok = :sys.suspend(server)

    try do
      cancel = Task.async(fn -> E.cancel(name, token) end)

      eventually(fn ->
        {:messages, messages} = Process.info(server, :messages)
        Enum.any?(messages, &match?({:"$gen_call", _, {:cancel, ^token}}, &1))
      end)

      # The public cancel call precedes DOWN in the suspended server's queue.
      watch = Process.monitor(old)
      Process.exit(old, :kill)
      assert_receive {:DOWN, ^watch, :process, ^old, :killed}, 2_000
      key = E.member_name(name, "w")
      outsider = foreign(key)
      {:ok, foreign_ref} = GenAgent.tell_with_completion(key, "foreign turn", self())
      assert foreign_ref != old_ref
      assert_receive {:controlled_prompt, "foreign", "foreign turn", foreign_task}

      :ok = :sys.resume(server)
      # DOWN for the captured PID confirms physical settlement even though
      # cancellation was queued first. The replacement cannot supply that evidence.
      assert Task.await(cancel) == {:ok, :cancelled}
      assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:error, :cancelled}}
      assert GenAgent.status(key).current_request == foreign_ref
      assert Process.alive?(outsider)
      assert Process.alive?(foreign_task)
      send(foreign_task, {:result, "foreign survived"})

      assert_receive {:gen_agent, :completion, ^key, ^foreign_ref,
                      {:ok, %{text: "foreign survived"}}}

      send(server, {:gen_agent, :completion, key, old_ref, {:ok, :late}})
      assert E.await(name, token) == {:error, :cancelled}
      refute_received {:gen_agent_ensemble, :completion, ^name, ^token, _}
    after
      :sys.resume(server)
    end
  end

  test "explicit stop demonitoring, same-batch restart and stop failure preserve ownership", %{
    name: name
  } do
    server = start(name, [echo_spec("w")])
    before = :sys.get_state(server)
    old = before.agents["w"]
    [{mref, "w"}] = Map.to_list(before.monitors)
    E.notify(name, {:ops, [{:stop, "w"}, {:start, echo_spec("w")}]})
    assert {:ok, %{agents: ["w"]}} = E.status(name)
    state = :sys.get_state(server)
    new = state.agents["w"]
    assert new != old
    refute Process.alive?(old)
    refute Map.has_key?(state.monitors, mref)
    assert {:monitors, owned_monitors} = Process.info(server, :monitors)
    refute {:process, old} in owned_monitors
    send(server, {:DOWN, mref, :process, old, :normal})
    assert {:ok, %{text: "echo: after stop"}} = E.ask(name, "after stop")

    # Inject an unavailable supervisor target, without killing the owned tree.
    dead = spawn(fn -> :ok end)
    watch = Process.monitor(dead)
    assert_receive {:DOWN, ^watch, :process, ^dead, _}
    :sys.replace_state(server, &%{&1 | agent_supervisor: dead})

    try do
      log =
        capture_log(fn ->
          E.notify(name, {:ops, [{:stop, "w"}]})
          assert {:ok, %{agents: ["w"]}} = E.status(name)
        end)

      assert log =~ "agent_stop_failed"
      assert :sys.get_state(server).agents == state.agents
      assert :sys.get_state(server).monitors == state.monitors
      assert Process.alive?(new)
    after
      :sys.replace_state(server, &%{&1 | agent_supervisor: state.agent_supervisor})
    end
  end
end
