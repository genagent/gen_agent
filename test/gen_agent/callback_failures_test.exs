defmodule GenAgent.CallbackFailuresTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgent.Server
  alias GenAgent.Support.TestAgent

  defmodule TerminatingAgent do
    use GenAgent

    @impl true
    def init_agent(_opts), do: {:ok, [], %{}}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}

    @impl true
    def terminate_agent(_reason, _state), do: raise("secret agent state")
  end

  defmodule TerminatingBackend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(_opts), do: {:ok, %{}}

    @impl true
    def prompt(_session, _prompt), do: {:error, :unused}

    @impl true
    def terminate_session(_session), do: raise("secret backend session")
  end

  setup do
    %{task_sup: start_supervised!({Task.Supervisor, []})}
  end

  defp start_server(task_sup, scripts, opts) do
    name = "callback-failures-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Server.start_link(
        name: name,
        backend: Keyword.get(opts, :backend, Mock),
        module: Keyword.get(opts, :module, TestAgent),
        task_supervisor: task_sup,
        init_opts: Keyword.merge([scripts: scripts], Keyword.get(opts, :init_opts, []))
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          :gen_statem.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {pid, name}
  end

  defp status(pid), do: :gen_statem.call(pid, :status)
  defp ask(pid), do: :gen_statem.call(pid, {:ask, "go"})

  test "malformed handle_event return leaves an idle agent alive", %{task_sup: task_sup} do
    {pid, name} =
      start_server(task_sup, [], init_opts: [event_handler: fn _event, state -> {:ok, state} end])

    log =
      capture_log(fn ->
        :gen_statem.cast(pid, {:notify, :note})
        assert %{agent_state: %{events: []}} = status(pid)
      end)

    assert Process.alive?(pid)
    assert log =~ name
    assert log =~ "handle_event/2 returned unexpected shape"
  end

  test "malformed handle_event return during drain does not lose an ask reply", %{
    task_sup: task_sup
  } do
    parent = self()

    script = fn _prompt ->
      send(parent, {:turn_blocked, self()})

      receive do
        :complete -> [Event.new(:result, %{text: "done"})]
      end
    end

    {pid, name} =
      start_server(task_sup, [script],
        init_opts: [event_handler: fn _event, state -> {:ok, state} end]
      )

    log =
      capture_log(fn ->
        caller = Task.async(fn -> ask(pid) end)
        assert_receive {:turn_blocked, task_pid}
        :gen_statem.cast(pid, {:notify, :note})
        assert status(pid).state == :processing
        send(task_pid, :complete)
        assert {:ok, %{text: "done"}} = Task.await(caller)
      end)

    assert Process.alive?(pid)
    assert status(pid).agent_state.events == []
    assert log =~ name
    assert log =~ "handle_event/2 returned unexpected shape"
  end

  test "malformed handle_error return preserves the original turn failure", %{
    task_sup: task_sup
  } do
    {pid, name} =
      start_server(task_sup, [{:error, :backend_down}],
        init_opts: [error_handler: fn _ref, _reason, state -> {:ok, state} end]
      )

    log = capture_log(fn -> assert {:error, :backend_down} = ask(pid) end)

    assert Process.alive?(pid)
    assert log =~ name
    assert log =~ "handle_error/3 returned unexpected shape"
  end

  test "a handle_error exception is logged without exposing its message", %{
    task_sup: task_sup
  } do
    {pid, name} =
      start_server(task_sup, [{:error, :backend_down}],
        init_opts: [error_handler: fn _ref, _reason, _state -> raise("secret reason") end]
      )

    log = capture_log(fn -> assert {:error, :backend_down} = ask(pid) end)

    assert Process.alive?(pid)
    assert log =~ name
    assert log =~ "handle_error/3 failed (error: RuntimeError)"
    assert log =~ "callback_failures_test.exs"
    refute log =~ "secret reason"
  end

  test "malformed handle_response still stops the agent with a bounded reason", %{
    task_sup: task_sup
  } do
    Process.flag(:trap_exit, true)

    {pid, _name} =
      start_server(task_sup, [[Event.new(:result, %{text: "ok"})]],
        init_opts: [responder: fn _ref, _response, _state -> :invalid_return end]
      )

    capture_log(fn ->
      caller =
        Task.async(fn ->
          try do
            ask(pid)
          catch
            :exit, reason -> {:exit, reason}
          end
        end)

      assert {:exit, _reason} = Task.await(caller)
      assert_receive {:EXIT, ^pid, {:callback_failed, :error, :other}}, 500
    end)
  end

  test "malformed pre_run return stops with a descriptive reason", %{task_sup: task_sup} do
    Process.flag(:trap_exit, true)

    log =
      capture_log(fn ->
        {pid, name} =
          start_server(task_sup, [], init_opts: [pre_run: fn _state -> :bad_return end])

        assert_receive {:EXIT, ^pid, :pre_run_invalid}
        assert name =~ "callback-failures-"
      end)

    assert log =~ "pre_run/1 returned unexpected shape"
  end

  test "malformed post_turn return is logged and ignored", %{task_sup: task_sup} do
    {pid, name} =
      start_server(task_sup, [[Event.new(:result, %{text: "ok"})]],
        init_opts: [post_turn: fn _outcome, _ref, _state -> :bad_return end]
      )

    log = capture_log(fn -> assert {:ok, %{text: "ok"}} = ask(pid) end)

    assert Process.alive?(pid)
    assert log =~ name
    assert log =~ "post_turn/3 returned unexpected shape"
  end

  test "termination callback failures are logged with redacted stack frames", %{
    task_sup: task_sup
  } do
    {pid, name} =
      start_server(task_sup, [], module: TerminatingAgent, backend: TerminatingBackend)

    log = capture_log(fn -> :gen_statem.stop(pid, :normal, 1_000) end)

    assert log =~ name
    assert log =~ "terminate_agent/2 failed"
    assert log =~ "terminate_session/1 failed"
    assert log =~ "RuntimeError"
    assert log =~ "TerminatingAgent"
    refute log =~ "secret agent state"
    refute log =~ "secret backend session"
  end
end
