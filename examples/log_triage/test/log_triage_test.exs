defmodule LogTriageTest do
  use ExUnit.Case, async: false

  defp start_agent(opts \\ []) do
    name = {__MODULE__, make_ref()}
    sink = start_supervised!({LogTriage.Sink, agent: name, observer: self()})
    tasks = start_supervised!({Task.Supervisor, []})

    start_supervised!(
      GenAgent.child_spec(
        LogTriage.Agent,
        Keyword.merge(
          [
            name: name,
            backend: LogTriage.Backend,
            backend_opts: [observer: self(), hold: true],
            sink: sink,
            task_supervisor: tasks
          ],
          opts
        )
      )
    )

    {name, sink}
  end

  defp notification_limit(:count, _event), do: [max_pending_notifications: 1]

  defp notification_limit(:bytes, event),
    do: [max_pending_notification_bytes: :erlang.external_size(event)]

  defp first_turn(name) do
    assert :ok = GenAgent.notify(name, {:log, "first", "initial failure"})
    assert_receive {:turn_started, "1x first: initial failure", task}
    task
  end

  defp finish(name, task) do
    send(task, :release)
    assert_receive {:note, note}
    # The synchronous snapshot is processed after handle_response and the
    # internal process-next event, so it also detects any unwanted extra turn.
    assert %{phase: :idle, pending_notifications: 0, pending_prompts: 0} =
             GenAgent.runtime_snapshot(name)

    note
  end

  test "one in-flight report followed by five notifications produces exactly two turns" do
    {name, sink} = start_agent()
    first = first_turn(name)

    for sample <- ["first retained sample", "second", "third", "fourth", "fifth"] do
      assert :ok = GenAgent.notify(name, {:log, "duplicate", sample})
    end

    assert GenAgent.runtime_snapshot(name).pending_notifications == 5
    send(first, :release)
    assert_receive {:note, first_note}
    assert first_note =~ "Incident: 1 reports across 1 fingerprints."
    assert_receive {:turn_started, "5x duplicate: first retained sample", second}
    assert finish(name, second) =~ "Incident: 5 reports across 1 fingerprints."
    assert %{notes: [^first_note, _], drops: 0} = LogTriage.Sink.snapshot(sink)
  end

  for limit <- [:count, :bytes] do
    test "#{limit} notification bound acknowledges overload and counts cast rejection telemetry" do
      event = {:log, "queued", "failure"}
      limit = unquote(limit)

      opts = notification_limit(limit, event)

      {name, sink} = start_agent(opts)
      first = first_turn(name)
      assert :ok = GenAgent.notify_ack(name, event)
      assert {:error, {:overloaded, info}} = GenAgent.notify_ack(name, event)
      assert info.queue == :notifications
      assert info.limit == limit
      assert info.pending_count == 1
      assert info.pending_bytes == :erlang.external_size(event)
      assert info.incoming_bytes == :erlang.external_size(event)
      assert_receive {:drop, %{agent: ^name, reason: {:overloaded, ^info}}}
      assert :ok = GenAgent.notify(name, event)
      assert_receive {:drop, %{agent: ^name, reason: {:overloaded, ^info}}}
      assert GenAgent.runtime_snapshot(name).pending_notifications == 1
      assert LogTriage.Sink.snapshot(sink).drops == 2

      # Other agents and prompt-queue rejections do not affect this counter.
      for metadata <- [
            %{agent: :another_agent, reason: {:overloaded, info}},
            %{agent: name, reason: {:overloaded, %{info | queue: :prompts}}}
          ] do
        :telemetry.execute([:gen_agent, :input, :rejected], %{}, metadata)
      end

      assert LogTriage.Sink.snapshot(sink).drops == 2
      send(first, :release)
      assert_receive {:note, _}
      assert_receive {:turn_started, "1x queued: failure", second}
      finish(name, second)
    end
  end

  test "handler filters feedback and lower levels before notifying" do
    {name, _sink} = start_agent()
    first = first_turn(name)
    config = %{config: %{agent: name}}

    for event <- [
          %{level: :warning, msg: {:string, "warning"}, meta: %{}},
          %{level: :error, msg: {:string, "own"}, meta: %{log_triage: true}},
          %{level: :error, msg: {:string, "core"}, meta: %{application: :gen_agent}},
          %{level: :error, msg: {:string, "core"}, meta: %{mfa: {GenAgent.Server, :init, 1}}}
        ] do
      assert :ok = LogTriage.Handler.log(event, config)
    end

    assert GenAgent.runtime_snapshot(name).pending_notifications == 0

    for level <- [:error, :critical, :alert, :emergency] do
      assert :ok =
               LogTriage.Handler.log(
                 %{level: level, msg: {:string, "failure"}, meta: %{}},
                 config
               )
    end

    assert GenAgent.runtime_snapshot(name).pending_notifications == 4
    send(first, :release)
    assert_receive {:note, _}
    assert_receive {:turn_started, prompt, second}
    assert prompt =~ "4x "
    finish(name, second)
  end

  test "report reduction removes volatile crash context and bounds binary payloads" do
    report = %{label: {:gen_server, :terminate}, reason: {:badmatch, :input}}
    one = Map.merge(report, %{pid: self(), time: 123, state: String.duplicate("x", 10_000)})
    two = Map.merge(report, %{pid: :other, time: 456, state: :different})
    assert LogTriage.Handler.reduce({:report, one}) == LogTriage.Handler.reduce({:report, two})

    refute LogTriage.Handler.reduce({:report, one}) ==
             LogTriage.Handler.reduce({:report, %{report | reason: :another_failure}})

    {fingerprint, sample} = LogTriage.Handler.reduce({:string, String.duplicate("🔥", 10_000)})
    assert byte_size(fingerprint) == 32
    assert byte_size(sample) <= 480
    assert String.valid?(sample)
  end

  test "malformed events are ignored and a rejected marker can be queued again" do
    {:ok, _, state} = LogTriage.Agent.init_agent(sink: self())
    assert {:noreply, ^state} = LogTriage.Agent.handle_event(:unrelated, state)
    assert {:skip, ^state} = LogTriage.Agent.pre_turn("FLUSH", state)

    assert {:prompt, "FLUSH", queued} =
             LogTriage.Agent.handle_event({:log, "fp", "sample"}, state)

    assert {:noreply, reset} =
             LogTriage.Agent.handle_error(make_ref(), {:overloaded, %{queue: :prompts}}, queued)

    assert {:prompt, "FLUSH", retried} =
             LogTriage.Agent.handle_event({:log, "fp", "later"}, reset)

    assert {:ok, "2x fp: sample", _} = LogTriage.Agent.pre_turn("FLUSH", retried)
  end

  test "application owns the agent and installs a working OTP logger handler" do
    assert GenAgent.whereis(:log_triage)
    assert {:ok, %{module: LogTriage.Handler}} = :logger.get_handler_config(:log_triage)
    assert Supervisor.which_children(LogTriage.Supervisor) |> length() == 4

    {name, _sink} = start_agent()
    start_supervised!({LogTriage.Handler, id: :log_triage_test, agent: name})
    on_exit(fn -> assert {:error, _} = :logger.get_handler_config(:log_triage_test) end)
    :logger.error("log triage integration fixture")
    assert_receive {:turn_started, prompt, task}
    assert prompt =~ "log triage integration fixture"
    finish(name, task)
  end
end
