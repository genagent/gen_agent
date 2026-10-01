defmodule GenAgent.CancelRequestTest do
  use ExUnit.Case, async: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      {:ok, [scripts: Keyword.fetch!(opts, :scripts)],
       %{observer: Keyword.fetch!(opts, :observer)}}
    end

    @impl true
    def handle_response(ref, _response, state) do
      send(state.observer, {:completed, ref})
      {:noreply, state}
    end

    @impl true
    def handle_error(ref, _reason, state) do
      send(state.observer, {:error_callback, ref})
      {:noreply, state}
    end

    @impl true
    def post_turn(_outcome, ref, state) do
      send(state.observer, {:post_turn, ref})
      {:ok, state}
    end

    @impl true
    def handle_event(:halt, state), do: {:halt, state}
  end

  defp blocked_turn(label) do
    observer = self()

    fn _prompt ->
      Stream.resource(
        fn -> :start end,
        fn
          :start ->
            send(observer, {:turn_started, label, self()})

            receive do
              {:release, ^label} -> {[Event.new(:result, %{text: Atom.to_string(label)})], :done}
            end

          :done ->
            {:halt, :done}
        end,
        fn _ -> :ok end
      )
    end
  end

  defp start_agent(scripts, opts \\ []) do
    name = "cancel-ref-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      GenAgent.start_agent(
        Agent,
        Keyword.merge(
          [name: name, backend: Mock, scripts: scripts, observer: self()],
          opts
        )
      )

    on_exit(fn -> DynamicSupervisor.terminate_child(GenAgent.AgentSupervisor, pid) end)

    name
  end

  defp backend_history(name) do
    name
    |> GenAgent.whereis()
    |> :gen_statem.call(:get_backend_session)
    |> Mock.history()
  end

  defp server_data(name) do
    {_state, data} = :sys.get_state(GenAgent.whereis(name))
    data
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp attach_cancelled(name) do
    observer = self()
    handler = "cancel-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:gen_agent, :turn, :cancelled],
        fn event, measurements, metadata, _ ->
          if metadata.agent == name do
            send(observer, {:telemetry, event, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "queued tell is removed before dispatch and poll reports cancellation" do
    name = start_agent([blocked_turn(:a), blocked_turn(:b)])
    assert {:ok, ref_a} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, task_a}
    assert {:ok, ref_b} = GenAgent.tell(name, "B")

    assert {:ok, :cancelled} = GenAgent.cancel_request(name, ref_b)
    assert {:error, :cancelled} = GenAgent.poll(name, ref_b)
    assert GenAgent.runtime_snapshot(name).pending_prompts == 0
    send(task_a, {:release, :a})
    assert_receive {:completed, ^ref_a}
    refute_receive {:turn_started, :b, _}, 50
    refute_receive {:error_callback, ^ref_b}, 0
    refute_receive {:post_turn, ^ref_b}, 0
    assert backend_history(name) == ["A"]
  end

  test "cancelled ref cannot remove its successor" do
    name = start_agent([blocked_turn(:a), blocked_turn(:c)])
    assert {:ok, ref_a} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, task_a}
    assert {:ok, ref_b} = GenAgent.tell(name, "B")
    assert {:ok, ref_c} = GenAgent.tell(name, "C")
    assert {:ok, :cancelled} = GenAgent.cancel_request(name, ref_b)

    send(task_a, {:release, :a})
    assert_receive {:turn_started, :c, task_c}
    assert {:ok, :cancelled} = GenAgent.cancel_request(name, ref_b)
    assert {:error, :current} = GenAgent.cancel_request(name, ref_c)
    assert {:error, :already_finished} = GenAgent.cancel_request(name, ref_a)
    send(task_c, {:release, :c})
    assert_receive {:completed, ^ref_c}
    assert {:ok, :completed, %{text: "c"}} = GenAgent.poll(name, ref_c)
    assert backend_history(name) == ["A", "C"]
  end

  test "current request remains active and can still be interrupted" do
    name = start_agent([blocked_turn(:a)])
    assert {:ok, ref} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, task}
    monitor = Process.monitor(task)

    assert {:error, :current} = GenAgent.cancel_request(name, ref)
    assert Process.alive?(task)
    assert {:ok, :pending} = GenAgent.poll(name, ref)
    assert {:ok, :accepted} = GenAgent.interrupt_request(name, ref)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    assert {:error, :interrupted} = GenAgent.poll(name, ref)
  end

  test "cancelled completion and telemetry are each emitted once without callbacks" do
    name = start_agent([blocked_turn(:a), blocked_turn(:b)])
    attach_cancelled(name)
    assert {:ok, _ref_a} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, _task_a}
    assert {:ok, ref_b} = GenAgent.tell_with_completion(name, "B")

    assert {:ok, :cancelled} = GenAgent.cancel_request(name, ref_b)
    assert {:ok, :cancelled} = GenAgent.cancel_request(name, ref_b)

    assert_receive {:gen_agent, :completion, ^name, ^ref_b, {:error, :cancelled}}

    assert_receive {:telemetry, [:gen_agent, :turn, :cancelled], %{system_time: time},
                    %{agent: ^name, ref: ^ref_b, origin: :tell, reason_kind: :caller_cancelled}}

    assert is_integer(time)
    refute_receive {:gen_agent, :completion, ^name, ^ref_b, _}, 50
    refute_receive {:telemetry, [:gen_agent, :turn, :cancelled], _, %{ref: ^ref_b}}, 0
    refute_receive {:error_callback, ^ref_b}, 0
    refute_receive {:post_turn, ^ref_b}, 0
  end

  test "finished, unknown, internal ask and pruned refs are not cancellable" do
    name = start_agent([blocked_turn(:a), blocked_turn(:b)], max_tell_results: 1)
    assert {:ok, ref_a} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, task_a}

    caller = spawn(fn -> GenAgent.ask(name, "ask") end)
    eventually(fn -> GenAgent.runtime_snapshot(name).pending_prompts == 1 end)
    [{ask_ref, {:ask, _}, "ask"}] = :queue.to_list(server_data(name).mailbox)
    assert {:error, :not_found} = GenAgent.cancel_request(name, ask_ref)
    assert {:error, :not_found} = GenAgent.cancel_request(name, make_ref())
    Process.exit(caller, :kill)
    eventually(fn -> GenAgent.runtime_snapshot(name).pending_prompts == 0 end)

    send(task_a, {:release, :a})
    assert_receive {:completed, ^ref_a}
    assert {:error, :already_finished} = GenAgent.cancel_request(name, ref_a)

    assert {:ok, ref_b} = GenAgent.tell(name, "B")
    assert_receive {:turn_started, :b, task_b}
    send(task_b, {:release, :b})
    assert_receive {:completed, ^ref_b}
    assert {:error, :not_found} = GenAgent.cancel_request(name, ref_a)
  end

  test "cancelled tombstone is forgotten when the bounded result cache prunes it" do
    name = start_agent([blocked_turn(:a)], max_tell_results: 1)
    assert {:ok, ref_a} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, task_a}
    assert {:ok, ref_b} = GenAgent.tell(name, "B")
    assert {:ok, :cancelled} = GenAgent.cancel_request(name, ref_b)
    assert {:ok, :cancelled} = GenAgent.cancel_request(name, ref_b)

    send(task_a, {:release, :a})
    assert_receive {:completed, ^ref_a}
    assert {:error, :not_found} = GenAgent.cancel_request(name, ref_b)
  end

  test "halted queued tell can be cancelled before resume" do
    name = start_agent([blocked_turn(:a)])
    assert :ok = GenAgent.notify_ack(name, :halt)
    assert {:ok, ref} = GenAgent.tell(name, "queued")
    assert GenAgent.runtime_snapshot(name).pending_prompts == 1
    assert {:ok, :cancelled} = GenAgent.cancel_request(name, ref)
    assert :ok = GenAgent.resume(name)
    assert GenAgent.runtime_snapshot(name).pending_prompts == 0
    refute_receive {:turn_started, :a, _}, 50
    assert backend_history(name) == []
  end

  test "cancellation releases both count and byte capacity" do
    prompt = "same"

    name =
      start_agent([blocked_turn(:a), blocked_turn(:c)],
        max_pending_prompts: 1,
        max_pending_prompt_bytes: :erlang.external_size(prompt)
      )

    assert {:ok, _ref_a} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, task_a}
    assert {:ok, ref_b} = GenAgent.tell(name, prompt)
    assert {:error, {:overloaded, %{queue: :prompts}}} = GenAgent.tell(name, prompt)
    assert {:ok, :cancelled} = GenAgent.cancel_request(name, ref_b)
    assert {:ok, ref_c} = GenAgent.tell(name, prompt)
    assert GenAgent.runtime_snapshot(name).pending_prompts == 1
    send(task_a, {:release, :a})
    assert_receive {:turn_started, :c, task_c}
    send(task_c, {:release, :c})
    assert_receive {:completed, ^ref_c}
  end

  test "queued ask is dropped when its caller dies" do
    name = start_agent([blocked_turn(:a), blocked_turn(:orphan)])
    attach_cancelled(name)
    assert {:ok, ref_a} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, task_a}
    caller = spawn(fn -> GenAgent.ask(name, "orphan") end)
    monitor = Process.monitor(caller)
    eventually(fn -> GenAgent.runtime_snapshot(name).pending_prompts == 1 end)
    [{ask_ref, {:ask, _}, "orphan"}] = :queue.to_list(server_data(name).mailbox)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    eventually(fn -> GenAgent.runtime_snapshot(name).pending_prompts == 0 end)
    assert server_data(name).ask_monitors == %{}

    assert_receive {:telemetry, [:gen_agent, :turn, :cancelled], %{system_time: time},
                    %{agent: ^name, ref: ^ask_ref, origin: :ask, reason_kind: :caller_down}}

    assert is_integer(time)
    send(task_a, {:release, :a})
    assert_receive {:completed, ^ref_a}
    refute_receive {:turn_started, :orphan, _}, 50
    assert backend_history(name) == ["A"]
  end

  test "live ask timeout leaves its queued work in place" do
    name = start_agent([blocked_turn(:a), blocked_turn(:ask)])
    assert {:ok, ref_a} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, task_a}
    observer = self()

    caller =
      spawn(fn ->
        result =
          try do
            GenAgent.ask(name, "ask", 20)
          catch
            :exit, reason -> {:exit, reason}
          end

        send(observer, {:ask_result, result})

        receive do
          :done -> :ok
        end
      end)

    assert_receive {:ask_result, {:exit, _}}, 1_000
    assert Process.alive?(caller)
    assert GenAgent.runtime_snapshot(name).pending_prompts == 1
    send(task_a, {:release, :a})
    assert_receive {:completed, ^ref_a}
    assert_receive {:turn_started, :ask, task_ask}
    assert server_data(name).ask_monitors == %{}
    ask_ref = server_data(name).current_request.request_ref
    assert {:error, :not_found} = GenAgent.cancel_request(name, ask_ref)
    send(task_ask, {:release, :ask})
    assert_receive {:completed, _ask_ref}
    assert backend_history(name) == ["A", "ask"]
    send(caller, :done)
  end

  test "normally dispatched queued ask removes its monitor" do
    name = start_agent([blocked_turn(:a), blocked_turn(:ask)])
    assert {:ok, ref_a} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, task_a}
    caller = Task.async(fn -> GenAgent.ask(name, "ask") end)
    eventually(fn -> map_size(server_data(name).ask_monitors) == 1 end)
    send(task_a, {:release, :a})
    assert_receive {:completed, ^ref_a}
    assert_receive {:turn_started, :ask, task_ask}
    assert server_data(name).ask_monitors == %{}
    send(task_ask, {:release, :ask})
    assert {:ok, %{text: "ask"}} = Task.await(caller)
    assert backend_history(name) == ["A", "ask"]
  end
end
