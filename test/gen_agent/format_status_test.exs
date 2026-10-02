defmodule GenAgent.FormatStatusTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GenAgent.Event
  alias GenAgent.Server
  alias GenAgent.Server.Data
  alias GenAgent.Support.TestAgent

  @secret "sk-test-SECRET-123"
  @prompt "PROMPT-SENTINEL"

  defmodule Backend do
    @behaviour GenAgent.Backend

    defmodule Session do
      defstruct [:api_key, :messages, :observer]
    end

    @impl true
    def start_session(opts) do
      {:ok,
       %Session{
         api_key: "sk-test-SECRET-123",
         messages: ["PROMPT-SENTINEL"],
         observer: Keyword.get(opts, :session_id)
       }}
    end

    @impl true
    def prompt(session, prompt) do
      send(session.observer, {:backend_prompt, self(), prompt})

      receive do
        :release -> {:ok, [Event.new(:result, %{text: "done"})], session}
      after
        5_000 -> {:error, :fixture_timeout}
      end
    end

    @impl true
    def update_session(session, _event_data), do: session

    @impl true
    def terminate_session(_session), do: :ok
  end

  setup do
    task_sup = start_supervised!(Task.Supervisor)
    name = "format-status-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Server.start_link(
        name: name,
        backend: Backend,
        module: TestAgent,
        task_supervisor: task_sup,
        init_opts: [session_id: self()],
        register: {:via, Registry, {GenAgent.Registry, name}}
      )

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: :gen_statem.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{pid: pid, name: name, task_sup: task_sup}
  end

  test ":sys.get_status redacts the session, current turn, and mailbox", %{pid: pid, name: name} do
    assert {:ok, _} = :gen_statem.call(pid, {:tell, @prompt})
    assert_receive {:backend_prompt, worker, @prompt}
    assert {:ok, _} = :gen_statem.call(pid, {:tell, "PROMPT-QUEUED"})

    status = :sys.get_status(pid) |> inspect(limit: :infinity)
    assert status =~ name
    refute status =~ @secret
    refute status =~ @prompt
    refute status =~ "PROMPT-QUEUED"

    assert %{state: :processing, agent_state: %TestAgent.State{}} = GenAgent.status(name)

    assert %{state: :processing, agent_state: %TestAgent.State{}} =
             :gen_statem.call(pid, :status)

    send(worker, :release)
  end

  test "termination status keeps the same keys and redacts event buffers" do
    raw = %{
      state: :processing,
      data: %Data{
        name: "safe-name",
        backend_session: %{api_key: @secret, messages: [@prompt]},
        agent_state: %{prompt: @prompt},
        current_request: %{prompt: @prompt},
        mailbox: :queue.from_list([@prompt]),
        pending_events: :queue.from_list([@prompt]),
        tell_results: %{one: @prompt},
        tell_result_order: :queue.from_list([@prompt]),
        ask_monitors: %{one: @prompt},
        self_chain: @prompt
      },
      queue: [{{:call, {self(), make_ref()}}, {:ask, @prompt}}],
      postponed: [{:cast, {:notify, @prompt}}],
      log: [{:in, {:cast, {:notify, @prompt}}, :processing}],
      timeouts: [state_timeout: 1_000],
      reason: {:backend_failed, @prompt}
    }

    formatted = Server.format_status(raw)
    assert Map.keys(formatted) == Map.keys(raw)
    assert formatted.data.name == "safe-name"
    assert formatted.queue == [{{:call, {:redacted, :redacted}}, :redacted}]
    assert formatted.postponed == [{:cast, :redacted}]
    assert formatted.timeouts == raw.timeouts
    assert formatted.reason == :redacted
    refute inspect(formatted, limit: :infinity) =~ @secret
    refute inspect(formatted, limit: :infinity) =~ @prompt
  end

  test "abnormal stop report does not render the session or agent state", %{task_sup: task_sup} do
    log =
      capture_log(fn ->
        {:ok, crashing_pid} =
          :gen_statem.start(
            Server,
            [
              name: "crashing-format-status",
              backend: Backend,
              module: TestAgent,
              task_supervisor: task_sup,
              init_opts: [
                session_id: self(),
                extra: %{prompt: @prompt},
                pre_run: fn _state -> {:error, :test_crash} end
              ]
            ],
            []
          )

        monitor = Process.monitor(crashing_pid)
        assert_receive {:DOWN, ^monitor, :process, ^crashing_pid, _reason}
        Logger.flush()
      end)

    assert log =~ "GenAgent.Server"
    refute log =~ @secret
    refute log =~ @prompt
  end

  test "runtime callback crash does not render callback arguments", %{pid: pid} do
    Process.unlink(pid)
    monitor = Process.monitor(pid)
    assert {:ok, _} = :gen_statem.call(pid, {:tell, @prompt})
    assert_receive {:backend_prompt, _worker, @prompt}
    assert {:ok, _} = :gen_statem.call(pid, {:tell, "PROMPT-QUEUED"})

    log =
      capture_log(fn ->
        catch_exit(:gen_statem.call(pid, {:unexpected, @prompt}))
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
        Logger.flush()
      end)

    assert log =~ "state callback failed"
    refute log =~ @secret
    refute log =~ @prompt
    refute log =~ "PROMPT-QUEUED"
  end

  test "initialization failure does not render start arguments" do
    log =
      capture_log(fn ->
        assert {:error, {:init_failed, :error, KeyError}} =
                 :gen_statem.start(Server, [name: @prompt, api_key: @secret], [])

        Logger.flush()
      end)

    assert log =~ "initialization failed"
    refute log =~ @secret
    refute log =~ @prompt
  end

  test "lifecycle callback errors do not render exception messages", %{task_sup: task_sup} do
    {:ok, pid} =
      Server.start_link(
        name: "redacted-hook-#{System.unique_integer([:positive])}",
        backend: Backend,
        module: TestAgent,
        task_supervisor: task_sup,
        init_opts: [
          pre_turn: fn prompt, _state -> raise "#{@secret}: #{prompt}" end
        ]
      )

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: :gen_statem.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    log =
      capture_log(fn ->
        assert {:error, :pre_turn_skipped} = :gen_statem.call(pid, {:ask, @prompt})
        Logger.flush()
      end)

    assert log =~ "pre_turn/2 raised RuntimeError"
    refute log =~ @secret
    refute log =~ @prompt
  end

  test "explicit pre_run error is redacted from OTP termination report", %{task_sup: task_sup} do
    log =
      capture_log(fn ->
        {:ok, pid} =
          :gen_statem.start(
            Server,
            [
              name: "redacted-pre-run-#{System.unique_integer([:positive])}",
              backend: Backend,
              module: TestAgent,
              task_supervisor: task_sup,
              init_opts: [pre_run: fn _state -> {:error, {@secret, @prompt}} end]
            ],
            []
          )

        monitor = Process.monitor(pid)
        assert_receive {:DOWN, ^monitor, :process, ^pid, {:pre_run_failed, _}}
        Logger.flush()
      end)

    refute log =~ @secret
    refute log =~ @prompt
  end

  test "malformed status maps remain safe and keep their keys" do
    for status <- [%{state: :idle}, %{data: %{api_key: @secret}, log: @prompt}] do
      formatted = Server.format_status(status)
      assert Map.keys(formatted) == Map.keys(status)
      refute inspect(formatted) =~ @secret
      refute inspect(formatted) =~ @prompt
    end

    assert Server.format_status(:malformed) == %{}
    assert Server.format_status(%{reason: {:shutdown, :normal}}).reason == {:shutdown, :normal}
  end
end
