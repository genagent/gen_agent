defmodule GenAgentEnsemble.CompletionTest do
  use ExUnit.Case, async: false

  alias GenAgent.Response
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}

  defmodule ManualStrategy do
    def init(_opts), do: {:ok, nil, []}

    def handle_tell(:reject, _opts, token, state),
      do: {:ok, [{:dispatch, "missing", "prompt", token}], state}

    def handle_tell(_prompt, opts, token, state) do
      send(Keyword.fetch!(opts, :observer), {:accepted, token})
      {:ok, [], state}
    end

    def handle_notify(ops, state), do: {:ok, ops, state}
  end

  setup do
    name = "completion-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    %{name: name}
  end

  defp start(name, strategy \\ ManualStrategy, opts \\ []) do
    {:ok, pid} = E.start_link(name: name, strategy: strategy, opts: opts)
    pid
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

  defp assert_clean(pid) do
    state = :sys.get_state(pid)
    assert state.waiters == %{}
    assert state.waiter_monitors == %{}
  end

  test "controlled success and backend error notify once and retain results", %{name: name} do
    pid =
      start(name, GenAgentEnsemble.Strategies.Solo,
        agent: {"w", ControlledAgent, backend: ControlledBackend, observer: self(), tag: :w}
      )

    for {delivery, expected} <- [
          {{:result, "done"}, {:ok, %Response{text: "done"}}},
          {{:error, :boom}, {:error, :boom}}
        ] do
      {:ok, token} = E.tell_with_completion(name, "go", self())
      assert_receive {:controlled_prompt, :w, "go", backend}
      task = waiter(pid, name, token)
      send(backend, delivery)
      assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, result}

      case expected do
        {:ok, %Response{text: text}} -> assert {:ok, %Response{text: ^text}} = result
        _ -> assert result == expected
      end

      assert Task.await(task) == result
      assert E.await(name, token, 0) == result
      assert {:ok, [{^token, ^result}]} = E.inbox(name)
      assert E.await(name, token) == {:error, :not_found}
      assert_clean(pid)
      refute_receive {:gen_agent_ensemble, :completion, ^name, ^token, _}, 0
    end
  end

  test "recipient validation occurs before dispatch", %{name: name} do
    for recipient <- [nil, :registered_name, "pid", make_ref()] do
      assert_raise FunctionClauseError, fn -> E.tell_with_completion(name, "go", recipient) end
    end

    for timeout <- [-1, nil, 1.5] do
      assert_raise FunctionClauseError, fn -> E.await(name, "token", timeout) end
    end
  end

  test "rejected dispatch produces a terminal notification immediately", %{name: name} do
    start(name)
    {:ok, token} = E.tell_with_completion(name, :reject, self())

    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token,
                    {:error, {:dispatch_rejected, "missing", {:agent_not_running, "missing"}}} =
                      result}

    assert E.await(name, token, 0) == result
    assert E.poll(name, token) == result
    assert E.poll(name, token) == {:error, :not_found}
  end

  test "completion recipient defaults to the caller", %{name: name} do
    start(name)
    {:ok, token} = E.tell_with_completion(name, :reject)

    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token,
                    {:error, {:dispatch_rejected, "missing", {:agent_not_running, "missing"}}}}
  end

  test "all simultaneous waiters receive one closure despite destructive polling", %{name: name} do
    pid = start(name)
    {:ok, token} = E.tell_with_completion(name, "go", self(), observer: self())
    assert_receive {:accepted, ^token}
    a = waiter(pid, name, token, 60_000)
    b = waiter(pid, name, token)
    state = :sys.get_state(pid)
    timers = for {_, {_, timer}} <- state.waiters[token], timer != nil, do: timer
    E.notify(name, [{:reply, token, :first}, {:reply_error, token, :duplicate}])
    assert E.poll(name, token) == {:ok, :completed, :first}
    assert Task.await(a) == {:ok, :first}
    assert Task.await(b) == {:ok, :first}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:ok, :first}}
    refute_receive {:gen_agent_ensemble, :completion, ^name, ^token, _}, 0
    assert E.await(name, token) == {:error, :not_found}
    assert_clean(pid)
    for timer <- timers, do: assert(Process.read_timer(timer) == false)
  end

  test "zero and finite timeouts remove only their waiter and retain late results", %{name: name} do
    pid = start(name)
    {:ok, token} = E.tell(name, "go", observer: self())
    assert E.await(name, token, 0) == {:error, :timeout}
    assert_clean(pid)
    expired = waiter(pid, name, token, 60_000)
    [{mref, {_, timer}}] = Map.to_list(:sys.get_state(pid).waiters[token])
    survivor = waiter(pid, name, token)
    send(pid, {:await_timeout, mref})
    assert Task.await(expired) == {:error, :timeout}
    assert Process.read_timer(timer) == false
    assert map_size(:sys.get_state(pid).waiters[token]) == 1
    send(pid, {:await_timeout, mref})
    assert E.poll(name, token) == {:ok, :pending}
    E.notify(name, [{:reply, token, :late}])
    assert Task.await(survivor) == {:ok, :late}
    assert E.await(name, token, 0) == {:ok, :late}
    assert E.poll(name, token) == {:ok, :completed, :late}
    assert_clean(pid)
    assert E.await(name, "unknown", 0) == {:error, :not_found}
  end

  test "caller death cleans up its monitor and timer", %{name: name} do
    pid = start(name)
    {:ok, token} = E.tell(name, "go", observer: self())
    task = waiter(pid, name, token, 60_000)
    [{mref, {_, timer}}] = Map.to_list(:sys.get_state(pid).waiters[token])
    Task.shutdown(task, :brutal_kill)
    # Explicit DOWN gives a deterministic barrier regardless of monitor delivery order.
    send(pid, {:DOWN, mref, :process, task.pid, :killed})
    assert_clean(pid)
    assert Process.read_timer(timer) == false
    E.notify(name, [{:reply, token, :late}])
    assert E.poll(name, token) == {:ok, :completed, :late}
  end

  test "waiter state is redacted from status", %{name: name} do
    pid = start(name)
    {:ok, token} = E.tell(name, "go", observer: self())
    task = waiter(pid, name, token)
    state = :sys.get_state(pid)
    %{state: redacted} = GenAgentEnsemble.Server.format_status(%{state: state})
    assert redacted.waiters == :redacted
    assert redacted.waiter_monitors == :redacted
    E.notify(name, [{:reply, token, :done}])
    assert Task.await(task) == {:ok, :done}
  end

  test "halt notifies recipients and waiters before session termination", %{name: name} do
    pid = start(name)
    {:ok, token} = E.tell_with_completion(name, "go", self(), observer: self())
    task = waiter(pid, name, token)
    mref = Process.monitor(pid)
    E.notify(name, [{:halt, :done}])
    assert Task.await(task) == {:error, {:halted, :done}}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:error, {:halted, :done}}}
    assert_receive {:DOWN, ^mref, :process, ^pid, :normal}
    refute_receive {:gen_agent_ensemble, :completion, ^name, ^token, _}, 0
    assert catch_exit(E.poll(name, token))
    assert catch_exit(E.await(name, token))
  end
end
