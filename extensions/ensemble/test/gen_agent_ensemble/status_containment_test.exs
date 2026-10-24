defmodule GenAgentEnsemble.StatusContainmentTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GenAgent.Response
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend, HaltSupport}

  # Keep Solo's real dispatch/queue/result behavior, with a configurable status
  # callback. Changing its mode goes through notify, never test-only state edits.
  defmodule WithoutStatus do
    @behaviour GenAgentEnsemble.Strategy
    alias GenAgentEnsemble.Strategies.Solo

    def init(opts) do
      {:ok, solo, specs} = Solo.init(opts)
      {:ok, %{solo: solo, observer: Keyword.fetch!(opts, :observer), mode: {:return, %{}}}, specs}
    end

    def handle_tell(prompt, opts, token, state) do
      {:ok, ops, solo} = Solo.handle_tell(prompt, opts, token, state.solo)
      {:ok, ops, %{state | solo: solo}}
    end

    def handle_ask(prompt, opts, token, state), do: handle_tell(prompt, opts, token, state)

    def handle_response(agent, response, state) do
      {:ok, ops, solo} = Solo.handle_response(agent, response, state.solo)
      {:ok, ops, %{state | solo: solo}}
    end

    def handle_notify({:status_mode, mode}, state), do: {:ok, [], %{state | mode: mode}}
    def handle_notify(:halt, state), do: {:ok, [{:halt, :done}], state}
  end

  defmodule Strategy do
    @behaviour GenAgentEnsemble.Strategy
    defdelegate init(opts), to: WithoutStatus
    defdelegate handle_tell(prompt, opts, token, state), to: WithoutStatus
    defdelegate handle_ask(prompt, opts, token, state), to: WithoutStatus
    defdelegate handle_response(agent, response, state), to: WithoutStatus
    defdelegate handle_notify(event, state), to: WithoutStatus

    def handle_status(state) do
      send(state.observer, :status_callback)

      case state.mode do
        {:raise, secret} -> raise secret
        {:throw, secret} -> throw({:private, secret})
        {:exit, secret} -> exit({:private, secret})
        {:return, fields} -> fields
      end
    end
  end

  setup do
    name = "status-containment-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    %{name: name}
  end

  defp start(name, strategy \\ Strategy) do
    {:ok, server} =
      E.start_link(
        name: name,
        strategy: strategy,
        opts: [
          observer: self(),
          agent:
            {"worker", ControlledAgent,
             backend: ControlledBackend, observer: self(), tag: "worker"}
        ]
      )

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

  defp assert_work_preserved(actual, before) do
    # Admission may advance independently; retain every ref and all tuple metadata.
    contexts =
      Map.new(actual.dispatch_contexts, fn {ref, context} ->
        case {Map.get(before.dispatch_contexts, ref), context} do
          {{started_at, ordinal, pid, :submitted}, {started_at, ordinal, pid, :accepted}} ->
            {ref, {started_at, ordinal, pid, :submitted}}

          _ ->
            {ref, context}
        end
      end)

    assert %{actual | dispatch_contexts: contexts} == before
  end

  @secret "status-private-sentinel"
  @invalid_error {:error, {:invalid_strategy_result, :handle_status}}
  @failures [
    {"raise", {:raise, @secret}, {:error, {:strategy_callback_failed, :handle_status, :error}}},
    {"throw", {:throw, @secret}, {:error, {:strategy_callback_failed, :handle_status, :throw}}},
    {"exit", {:exit, @secret}, {:error, {:strategy_callback_failed, :handle_status, :exit}}},
    {"nil", {:return, nil}, @invalid_error},
    {"atom", {:return, :invalid}, @invalid_error},
    {"keyword list", {:return, [secret: @secret]}, @invalid_error},
    {"tuple", {:return, {:ok, @secret}}, @invalid_error},
    {"error tuple", {:return, {:error, @secret}}, @invalid_error},
    {"framework-shaped error",
     {:return, {:error, {:strategy_callback_failed, :handle_status, :exit}}}, @invalid_error},
    {"improper list", {:return, [@secret | :invalid]}, @invalid_error},
    {"empty list", {:return, []}, @invalid_error},
    {"binary", {:return, @secret}, @invalid_error},
    {"number", {:return, 42}, @invalid_error}
  ]

  for {label, mode, error} <- @failures do
    test "#{label} returns a private typed error and preserves live work and retained results", %{
      name: name
    } do
      server = start(name)
      server_ref = Process.monitor(server)
      {:ok, early} = E.tell(name, "early")
      assert_receive {:controlled_prompt, "worker", "early", first_backend}
      send(first_backend, {:result, "retained"})
      assert {:ok, %Response{text: "retained"} = retained} = E.await(name, early)

      {:ok, active} = E.tell_with_completion(name, "active", self())
      assert_receive {:controlled_prompt, "worker", "active", backend}
      {:ok, queued} = E.tell_with_completion(name, "queued", self())
      waiting = waiter(server, name, active)
      E.notify(name, {:status_mode, unquote(Macro.escape(mode))})
      before = :sys.get_state(server)

      assert before.lifecycle == :running
      assert map_size(before.pending) == 2
      assert before.pending_prompt_bytes > 0
      assert map_size(before.in_flight) == 2
      assert map_size(before.dispatch_contexts) == 2
      assert before.completed[early] == {:ok, retained}

      logs =
        capture_log(fn ->
          for _ <- 1..2 do
            assert E.status(name) == unquote(Macro.escape(error))
            assert_receive :status_callback
            assert_work_preserved(:sys.get_state(server), before)
          end
        end)

      refute logs =~ @secret
      refute inspect(unquote(Macro.escape(error))) =~ @secret
      assert Registry.lookup(GenAgentEnsemble.Registry, name) == [{server, nil}]

      for pid <-
            [server, before.agent_tree, before.agent_supervisor, before.task_supervisor] ++
              Map.values(before.agents) do
        assert Process.alive?(pid)
      end

      refute_received {:DOWN, ^server_ref, :process, ^server, _}
      refute_received {:gen_agent_ensemble, :completion, ^name, _, _}

      E.notify(name, {:status_mode, {:return, %{recovered: true}}})

      assert {:ok, %{recovered: true, lifecycle: :running, admission: %{pending_count: 2}}} =
               E.status(name)

      assert_receive :status_callback
      # Only notify changed the strategy's mode; the framework's work is intact.
      after_recovery = :sys.get_state(server)
      assert_work_preserved(%{after_recovery | strategy_state: before.strategy_state}, before)

      send(backend, {:result, "active-result"})
      assert {:ok, %Response{text: "active-result"}} = Task.await(waiting)

      assert_receive {:gen_agent_ensemble, :completion, ^name, ^active,
                      {:ok, %Response{text: "active-result"}}}

      assert_receive {:controlled_prompt, "worker", "queued", next_backend}
      send(next_backend, {:result, "queued-result"})
      assert {:ok, %Response{text: "queued-result"}} = E.await(name, queued)

      assert_receive {:gen_agent_ensemble, :completion, ^name, ^queued,
                      {:ok, %Response{text: "queued-result"}}}

      assert E.await(name, early, 0) == {:ok, retained}
      assert E.await(name, early, 0) == {:ok, retained}
      assert {:ok, %{admission: %{pending_count: 0, pending_bytes: 0}}} = E.status(name)
      refute_received {:gen_agent_ensemble, :completion, ^name, _, _}
    end
  end

  test "successful maps preserve base overrides and authoritative fields", %{name: name} do
    server = start(name)
    state = :sys.get_state(server)

    for fields <- [
          %{},
          %{custom: :present},
          %Response{text: "structs remain accepted"},
          %{
            session: :custom_session,
            strategy: :custom_strategy,
            agents: :custom_agents,
            pending_tokens: :custom_pending,
            in_flight: :custom_in_flight,
            admission: :fake,
            lifecycle: :fake,
            member_names: :fake
          }
        ] do
      E.notify(name, {:status_mode, {:return, fields}})
      assert {:ok, status} = E.status(name)
      assert_receive :status_callback

      expected =
        %{
          session: name,
          strategy: Strategy,
          agents: ["worker"],
          pending_tokens: [],
          in_flight: 0
        }
        |> Map.merge(fields)
        |> Map.put(:admission, %{
          scope: :outstanding,
          pending_count: 0,
          pending_bytes: 0,
          max_pending_prompts: state.max_pending_prompts,
          max_pending_prompt_bytes: state.max_pending_prompt_bytes
        })
        |> Map.put(:lifecycle, :running)
        |> Map.put(:member_names, %{"worker" => E.member_name(name, "worker")})

      assert status == expected
    end
  end

  test "missing optional status callback returns the ordinary base status", %{name: name} do
    server = start(name, WithoutStatus)
    before = :sys.get_state(server)

    assert {:ok,
            %{
              session: ^name,
              strategy: WithoutStatus,
              agents: ["worker"],
              pending_tokens: [],
              in_flight: 0,
              lifecycle: :running,
              admission: %{pending_count: 0, pending_bytes: 0},
              member_names: %{"worker" => member_name}
            } = status} = E.status(name)

    assert map_size(status) == 8
    assert member_name == E.member_name(name, "worker")
    assert :sys.get_state(server) == before
    refute_received :status_callback
  end

  test "halted status never invokes a configured failing callback", %{name: name} do
    server = start(name)
    E.notify(name, {:status_mode, {:raise, @secret}})
    watched = HaltSupport.watch(server)
    :erlang.trace(server, true, [:receive])
    tree = :sys.get_state(server).agent_tree
    E.notify(name, :halt)
    HaltSupport.assert_tree_gone(watched)
    # Observe the actual tree EXIT, then use a system call as a processing barrier.
    assert_receive {:trace, ^server, :receive, {:EXIT, ^tree, _}}, 2_000
    :erlang.trace(server, false, [:receive])
    before = :sys.get_state(server)
    assert before.agent_tree == nil

    assert {:ok, status} = E.status(name)
    assert status.lifecycle == :halted
    assert status.agents == []
    assert status.pending_tokens == []
    assert status.in_flight == 0
    assert status.member_names == %{}
    assert status.admission.pending_count == 0
    assert status.admission.pending_bytes == 0
    assert :sys.get_state(server) == before
    refute_received :status_callback
  end
end
