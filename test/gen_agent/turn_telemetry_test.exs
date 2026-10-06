defmodule GenAgent.TurnTelemetryTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgent.Server
  alias GenAgent.Support.TestAgent

  defmodule CrashingBackend do
    @behaviour GenAgent.Backend

    def start_session(_opts), do: {:ok, %{}}
    def prompt(_session, _prompt), do: exit(:fixture_crash)
    def terminate_session(_session), do: :ok
  end

  setup do
    name = "turn-telemetry-#{System.unique_integer([:positive])}"
    parent = self()
    handler = "turn-telemetry-handler-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        for(
          kind <- [:turn, :prompt],
          outcome <- [:start, :stop, :error, :rejected],
          do: [:gen_agent, kind, outcome]
        ),
        fn event, measurements, metadata, _ ->
          if metadata.agent == name do
            send(parent, {:telemetry, event, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{name: name, task_sup: start_supervised!({Task.Supervisor, []})}
  end

  defp start_agent(name, task_sup, scripts, opts \\ []) do
    {:ok, pid} =
      Server.start_link(
        name: name,
        backend: Keyword.get(opts, :backend, Mock),
        module: TestAgent,
        task_supervisor: task_sup,
        init_opts: Keyword.merge([scripts: scripts], Keyword.get(opts, :init_opts, [])),
        watchdog_ms: Keyword.get(opts, :watchdog_ms, 5_000),
        max_pending_prompts: Keyword.get(opts, :max_pending_prompts, 1_000)
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

    pid
  end

  defp ask(pid, prompt), do: :gen_statem.call(pid, {:ask, prompt}, 5_000)

  test "state, mailbox, and notification telemetry tracks a queued turn",
       %{name: name, task_sup: task_sup} do
    parent = self()
    handler = "runtime-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [
          [:gen_agent, :state, :changed],
          [:gen_agent, :mailbox, :queued],
          [:gen_agent, :event, :received]
        ],
        fn event, measurements, metadata, _ ->
          if metadata.agent == name,
            do: send(parent, {:runtime_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    pid =
      start_agent(name, task_sup, [
        Mock.gate(:active, [Event.new(:result, %{text: "active"})]),
        [Event.new(:result, %{text: "queued"})]
      ])

    assert_receive {:runtime_telemetry, [:gen_agent, :state, :changed], _,
                    %{from: nil, to: :idle}}

    assert {:ok, _} = :gen_statem.call(pid, {:tell, "active"})
    assert_receive {:mock_blocked, :active, turn_pid}

    assert_receive {:runtime_telemetry, [:gen_agent, :state, :changed], _,
                    %{from: :idle, to: :processing}}

    assert {:ok, queued_ref} = :gen_statem.call(pid, {:tell, "queued"})

    assert_receive {:runtime_telemetry, [:gen_agent, :mailbox, :queued], %{depth: 1},
                    %{agent: ^name}}

    assert :ok = :gen_statem.call(pid, {:notify_ack, :note})

    assert_receive {:runtime_telemetry, [:gen_agent, :event, :received], _,
                    %{agent: ^name, event: :note}}

    send(turn_pid, {:mock_release, :active})
    assert {:ok, :completed, %{text: "queued"}} = wait_for_completion(pid, queued_ref)
  end

  defp wait_for_completion(pid, ref, attempts \\ 50)
  defp wait_for_completion(_pid, _ref, 0), do: flunk("queued turn did not complete")

  defp wait_for_completion(pid, ref, attempts) do
    case :gen_statem.call(pid, {:poll, ref}) do
      {:ok, :pending} ->
        Process.sleep(10)
        wait_for_completion(pid, ref, attempts - 1)

      result ->
        result
    end
  end

  test "completed turns emit content-free start and stop with matching refs and wall time",
       %{name: name, task_sup: task_sup} do
    pid = start_agent(name, task_sup, [[Event.new(:result, %{text: "ok"})]])
    assert {:ok, %{text: "ok"}} = ask(pid, "secret prompt")

    assert_receive {:telemetry, [:gen_agent, :turn, :start], %{system_time: time}, start}, 500
    assert is_integer(time)
    assert start == %{agent: name, attempt: 1, ref: start.ref, origin: :ask}
    assert is_reference(start.ref)

    assert_receive {:telemetry, [:gen_agent, :turn, :stop], %{duration_ms: duration}, stop}, 500
    assert duration >= 0
    assert stop == start
    refute inspect({start, stop}) =~ "secret prompt"
  end

  test "backend errors have terminal duration and a bounded reason kind",
       %{name: name, task_sup: task_sup} do
    pid = start_agent(name, task_sup, [{:error, :fixture_error}])
    assert {:error, :fixture_error} = ask(pid, "fail")

    assert_receive {:telemetry, [:gen_agent, :turn, :start], _, %{ref: ref}}, 500

    assert_receive {:telemetry, [:gen_agent, :prompt, :error], %{duration: legacy_ms}, _},
                   500

    assert is_integer(legacy_ms) and legacy_ms >= 0

    assert_receive {:telemetry, [:gen_agent, :turn, :error], %{duration_ms: duration}, meta},
                   500

    assert duration >= 0

    assert meta == %{
             agent: name,
             attempt: 1,
             ref: ref,
             origin: :ask,
             reason_kind: :backend_or_callback_error
           }
  end

  test "watchdog timeouts have the same terminal timing shape",
       %{name: name, task_sup: task_sup} do
    slow_script = fn _prompt ->
      Process.sleep(200)
      [Event.new(:result, %{text: "late"})]
    end

    pid = start_agent(name, task_sup, [slow_script], watchdog_ms: 40)
    assert {:error, :timeout} = ask(pid, "slow")
    assert_receive {:telemetry, [:gen_agent, :turn, :start], _, %{ref: ref}}, 500

    assert_receive {:telemetry, [:gen_agent, :turn, :error], %{duration_ms: duration}, meta},
                   500

    assert duration >= 40
    assert meta == %{agent: name, attempt: 1, ref: ref, origin: :ask, reason_kind: :timeout}
  end

  test "task crashes report a bounded reason kind", %{name: name, task_sup: task_sup} do
    pid = start_agent(name, task_sup, [], backend: CrashingBackend)
    assert {:error, {:task_crashed, :fixture_crash}} = ask(pid, "crash")
    assert_receive {:telemetry, [:gen_agent, :turn, :start], _, %{ref: ref}}, 500

    assert_receive {:telemetry, [:gen_agent, :turn, :error], %{duration_ms: duration}, meta},
                   500

    assert duration >= 0
    assert meta == %{agent: name, attempt: 1, ref: ref, origin: :ask, reason_kind: :task_crashed}
  end

  test "interrupts settle a started turn with an error", %{name: name, task_sup: task_sup} do
    parent = self()

    slow_script = fn _prompt ->
      send(parent, :backend_started)
      Process.sleep(500)
      [Event.new(:result, %{text: "late"})]
    end

    pid = start_agent(name, task_sup, [slow_script])
    caller = Task.async(fn -> ask(pid, "stop") end)
    assert_receive :backend_started, 500
    :gen_statem.cast(pid, :interrupt)
    assert {:error, :interrupted} = Task.await(caller, 1_000)

    assert_receive {:telemetry, [:gen_agent, :turn, :start], _, %{ref: ref}}, 500

    assert_receive {:telemetry, [:gen_agent, :turn, :error], %{duration_ms: duration}, meta},
                   500

    assert duration >= 0
    assert meta == %{agent: name, attempt: 1, ref: ref, origin: :ask, reason_kind: :interrupted}
  end

  test "queued prompt overload is rejected without starting that ref",
       %{name: name, task_sup: task_sup} do
    parent = self()

    held_script = fn _prompt ->
      send(parent, :backend_started)
      Process.sleep(500)
      [Event.new(:result, %{text: "late"})]
    end

    pid = start_agent(name, task_sup, [held_script], max_pending_prompts: 0)
    caller = Task.async(fn -> ask(pid, "held") end)
    assert_receive :backend_started, 500
    assert {:error, {:overloaded, _}} = ask(pid, "rejected")

    assert_receive {:telemetry, [:gen_agent, :turn, :start], _, %{ref: started_ref}}, 500

    assert_receive {:telemetry, [:gen_agent, :turn, :rejected], _, rejected}, 500

    assert rejected == %{
             agent: name,
             attempt: 1,
             ref: rejected.ref,
             origin: :ask,
             reason_kind: :overloaded
           }

    assert rejected.ref != started_ref
    :gen_statem.cast(pid, :interrupt)
    assert {:error, :interrupted} = Task.await(caller, 1_000)
  end

  test "pre-dispatch skips are rejected without a start event", %{
    name: name,
    task_sup: task_sup
  } do
    pid =
      start_agent(name, task_sup, [[Event.new(:result, %{text: "unused"})]],
        init_opts: [pre_turn: fn _prompt, state -> {:skip, state} end]
      )

    assert {:error, :pre_turn_skipped} = ask(pid, "never sent")

    assert_receive {:telemetry, [:gen_agent, :turn, :rejected], %{system_time: time}, meta},
                   500

    assert is_integer(time)

    assert meta == %{
             agent: name,
             attempt: 1,
             ref: meta.ref,
             origin: :ask,
             reason_kind: :pre_turn_skipped
           }

    refute_received {:telemetry, [:gen_agent, :turn, :start], _, _}
    refute_received {:telemetry, [:gen_agent, :turn, :error], _, _}
  end
end
