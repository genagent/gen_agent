defmodule GenAgent.ServerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias GenAgent.Backends.Mock
  alias GenAgent.{Event, Server}
  alias GenAgent.Support.TestAgent

  @timeout 1_000
  @moduletag capture_log: true

  # Contract adjustments: completion messages belong only to opted-in tells;
  # asks use OTP call replies, and plain tells are observed through poll/2.
  # Interrupts affect active turns, while accepted queued work survives halts
  # under the :queue policy. Notification prompts have :event origin, not
  # :self_chain origin. This fixture deliberately has no callback retries.
  # Reproduce with: mix test test/gen_agent/server_property_test.exs --seed 134
  # StreamData uses ExUnit's seed; commands and payloads both shrink.
  property "held server turns preserve request ownership and queue accounting" do
    check all(
            commands <- list_of(command(), max_length: 32),
            max_runs: 60,
            max_shrinking_steps: 30
          ) do
      run(commands)
    end
  end

  defp command do
    payload = string(:alphanumeric, max_length: 24)

    one_of([
      map(payload, &{:ask, &1}),
      tuple({constant(:tell), payload, member_of([:plain, :completion])}),
      map(payload, &{:notify, {:note, &1}}),
      map(payload, &{:notify, {:prompt, &1}}),
      constant({:notify, :halt}),
      constant(:release),
      constant(:interrupt),
      map(member_of([:current, :queued, :stale]), &{:interrupt_request, &1}),
      constant(:resume)
    ])
  end

  defp run(commands) do
    token = make_ref()
    owner = self()
    name = "server-property-#{System.unique_integer([:positive])}"
    {:ok, supervisor} = Task.Supervisor.start_link()
    Process.unlink(supervisor)

    # Only the backend task blocks. The server remains available for barriers.
    script = fn prompt ->
      send(owner, {:gate, token, prompt, self()})

      receive do
        {:release, ^token} -> [Event.new(:result, %{text: prompt})]
      after
        5_000 -> raise "property gate was not released"
      end
    end

    {:ok, pid} =
      Server.start_link(
        name: name,
        backend: Mock,
        module: TestAgent,
        task_supervisor: supervisor,
        watchdog_ms: 10_000,
        init_opts: [
          scripts: List.duplicate(script, length(commands) + 16),
          event_handler: fn
            :halt, state -> {:halt, state}
            {:prompt, prompt}, state -> {:prompt, prompt, state}
            _event, state -> {:noreply, state}
          end,
          post_turn: fn outcome, ref, state ->
            send(owner, {:finished, token, ref, outcome})
            {:ok, state}
          end,
          post_run: fn _state ->
            send(owner, {:post_run, token})
            :ok
          end
        ]
      )

    # Crashes must become shrinkable assertion failures, not kill the runner.
    Process.unlink(pid)

    try do
      model = %{
        pid: pid,
        name: name,
        token: token,
        deadline: System.monotonic_time(:millisecond) + 10_000,
        active: nil,
        queue: [],
        notifications: [],
        events: [],
        halted: false,
        halts: 0,
        post_runs: 0,
        done: [],
        completions: %{}
      }

      # A small fixed prefix guarantees all contracts even after shrinking.
      # The generated suffix varies release points, payloads and interleavings.
      prefix = [
        {:ask, "held"},
        {:tell, "queued", :completion},
        {:notify, {:prompt, "event"}},
        {:notify, :halt},
        {:notify, :halt},
        {:interrupt_request, :queued},
        {:interrupt_request, :current},
        :interrupt,
        {:ask, "halted"},
        :resume,
        {:interrupt_request, :stale},
        :release,
        :interrupt,
        :release,
        {:tell, "tail", :plain}
      ]

      model = Enum.reduce(prefix ++ commands, assert_model(model), &step/2)
      model = settle(model, 48)
      assert model.active == nil
      assert model.queue == []
      assert model.notifications == []
      refute model.halted
      assert_empty_mailbox(pid, 32)
      refute_receive {:gate, ^token, _, _}, 0
      refute_receive {:finished, ^token, _, _}, 0
    catch
      :exit, reason -> flunk("server fixture exited: #{inspect(reason)}")
    after
      # Per-sample cleanup also runs on assertion failures and during shrinking.
      if Process.alive?(pid), do: :gen_statem.stop(pid, :normal, @timeout)
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, @timeout)
    end
  end

  defp step({:ask, prompt}, model) do
    # OTP's asynchronous call API submits the actual Server ask contract from
    # the test process, so the subsequent snapshot is a same-sender barrier.
    request = :gen_statem.send_request(model.pid, {:ask, prompt})
    model |> enqueue(:ask, prompt, nil, request, false) |> dispatch() |> assert_model()
  end

  defp step({:tell, prompt, delivery}, model) do
    message =
      if delivery == :completion,
        do: {:tell_with_completion, prompt, self(), :queue},
        else: {:tell, prompt}

    assert {:ok, ref} = call(model, message)

    model
    |> enqueue(:tell, prompt, ref, nil, delivery == :completion)
    |> dispatch()
    |> assert_model()
  end

  defp step({:notify, event}, model) do
    :gen_statem.cast(model.pid, {:notify, event})

    model =
      if model.active,
        do: %{model | notifications: model.notifications ++ [event]},
        else: apply_event(event, model)

    model |> dispatch() |> assert_model()
  end

  defp step(:resume, model), do: model |> step_resume() |> assert_model()
  defp step(:release, %{active: nil} = model), do: assert_model(model)

  defp step(:release, model) do
    send(model.active.task, {:release, model.token})
    model |> finish({:ok, model.active.prompt}) |> assert_model()
  end

  defp step(:interrupt, model) do
    :gen_statem.cast(model.pid, :interrupt)
    model = if model.active, do: finish(model, {:error, :interrupted}), else: model
    assert_model(model)
  end

  defp step({:interrupt_request, target}, model) do
    ref = target_ref(target, model)

    expected =
      cond do
        is_nil(model.active) -> {:error, :idle}
        ref == model.active.ref -> {:ok, :accepted}
        true -> {:error, :not_current}
      end

    assert call(model, {:interrupt_request, ref}) == expected

    model =
      if expected == {:ok, :accepted}, do: finish(model, {:error, :interrupted}), else: model

    assert_model(model)
  end

  defp target_ref(:current, %{active: %{ref: ref}}), do: ref
  defp target_ref(:stale, %{done: [entry | _]}), do: entry.ref

  defp target_ref(:queued, model) do
    case Enum.find(model.queue, &is_reference(&1.ref)) do
      nil -> make_ref()
      entry -> entry.ref
    end
  end

  defp target_ref(_target, _model), do: make_ref()

  defp enqueue(model, origin, prompt, ref \\ nil, request \\ nil, completion \\ false) do
    entry = %{origin: origin, prompt: prompt, ref: ref, request: request, completion: completion}
    %{model | queue: model.queue ++ [entry]}
  end

  defp dispatch(%{active: nil, halted: false, queue: [entry | rest]} = model) do
    snapshot = call(model, :runtime_snapshot)
    assert %{ref: ref, origin: origin} = snapshot.current_request
    assert origin == entry.origin
    if entry.ref, do: assert(ref == entry.ref)
    token = model.token
    prompt = entry.prompt
    assert_receive {:gate, ^token, ^prompt, task}, @timeout
    active = Map.merge(entry, %{ref: ref, task: task, monitor: Process.monitor(task)})
    %{model | active: active, queue: rest}
  end

  defp dispatch(model), do: model

  defp finish(model, outcome) do
    %{ref: ref, task: task, monitor: monitor} = entry = model.active
    token = model.token
    assert_receive {:finished, ^token, ^ref, actual}, @timeout
    assert normalize(actual) == outcome
    assert_receive {:DOWN, ^monitor, :process, ^task, reason}, @timeout
    assert reason == if(outcome == {:error, :interrupted}, do: :killed, else: :normal)

    if entry.request do
      assert {:reply, reply} = :gen_statem.wait_response(entry.request, @timeout)
      assert normalize(reply) == outcome
      # OTP deactivates this reply alias; callback/ref uniqueness below
      # supplies duplicate-outcome coverage instead of another alias read.
    end

    model = %{model | active: nil, done: [Map.put(entry, :outcome, outcome) | model.done]}
    model = Enum.reduce(model.notifications, model, &apply_event/2)
    %{model | notifications: []} |> dispatch()
  end

  defp apply_event(event, model) do
    model = %{model | events: model.events ++ [event]}

    case event do
      :halt when not model.halted -> %{model | halted: true, halts: model.halts + 1}
      {:prompt, prompt} -> enqueue(model, :event, prompt)
      _ -> model
    end
  end

  defp step_resume(model) do
    :gen_statem.cast(model.pid, :resume)
    %{model | halted: false} |> dispatch()
  end

  defp settle(%{active: nil, queue: [], halted: false} = model, _remaining),
    do: assert_model(model)

  defp settle(_model, 0), do: flunk("bounded drain exhausted")

  defp settle(model, remaining) do
    model = if model.halted, do: model |> step_resume() |> assert_model(), else: model
    settle(step(:release, model), remaining - 1)
  end

  defp assert_model(model) do
    assert System.monotonic_time(:millisecond) < model.deadline
    snapshot = call(model, :runtime_snapshot)
    status = call(model, :status)
    assert snapshot.pending_prompts == length(model.queue)
    assert status.queued == snapshot.pending_prompts
    assert snapshot.pending_notifications == length(model.notifications)
    assert snapshot.halted == model.halted
    refute snapshot.halt_pending
    refute snapshot.self_chain_pending
    assert snapshot.phase == if(model.active, do: :processing, else: :idle)
    assert status.current_request == if(model.active, do: model.active.ref, else: nil)

    # Neither public observation API exposes bytes. Read only the counters,
    # never derive expectations from private queues or transition functions.
    {_phase, counters} = :sys.get_state(model.pid, @timeout)
    assert counters.pending_prompt_bytes == bytes(Enum.map(model.queue, & &1.prompt))
    assert counters.pending_notification_bytes == bytes(model.notifications)

    actual =
      Enum.map(status.agent_state.responses, fn {ref, response} -> {ref, {:ok, response.text}} end) ++
        Enum.map(status.agent_state.errors, fn {ref, reason} -> {ref, {:error, reason}} end)

    expected = Enum.map(model.done, &{&1.ref, &1.outcome})
    assert Enum.sort(actual) == Enum.sort(expected)
    assert length(Enum.uniq_by(actual, &elem(&1, 0))) == length(actual)
    assert status.agent_state.events == model.events

    for entry <- model.queue ++ List.wrap(model.active), entry.request do
      assert :gen_statem.wait_response(entry.request, 0) == :timeout
    end

    for entry <- model.queue ++ List.wrap(model.active), entry.origin == :tell do
      assert call(model, {:poll, entry.ref}) == {:ok, :pending}
    end

    for entry <- model.done, entry.origin == :tell do
      assert normalize_poll(call(model, {:poll, entry.ref})) == entry.outcome
    end

    model = deliveries(model, 128)

    expected_completions =
      for entry <- model.done, entry.completion, into: %{}, do: {entry.ref, entry.outcome}

    assert model.completions == expected_completions
    assert model.post_runs == model.halts

    # Idle while halted may retain prompts; interruption is not queue cancellation.
    # Unhalted quiescence has neither queued prompts nor buffered notifications.
    if is_nil(model.active) and not model.halted do
      assert snapshot.pending_prompts == 0
      assert snapshot.pending_notifications == 0
      assert counters.pending_prompt_bytes == 0
      assert counters.pending_notification_bytes == 0
    end

    model
  end

  defp deliveries(_model, 0), do: flunk("bounded delivery drain exhausted")

  defp deliveries(model, remaining) do
    name = model.name
    token = model.token

    receive do
      {:gen_agent, :completion, ^name, ref, outcome} ->
        refute Map.has_key?(model.completions, ref)
        completions = Map.put(model.completions, ref, normalize(outcome))
        deliveries(%{model | completions: completions}, remaining - 1)

      {:post_run, ^token} ->
        deliveries(%{model | post_runs: model.post_runs + 1}, remaining - 1)
    after
      0 -> model
    end
  end

  defp assert_empty_mailbox(_pid, 0), do: flunk("server mailbox did not settle")

  defp assert_empty_mailbox(pid, remaining) do
    # Advance queued EXIT/DOWN signals with an ordered barrier, without sleeps.
    :sys.get_state(pid, @timeout)

    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, 0} -> :ok
      {:message_queue_len, _} -> assert_empty_mailbox(pid, remaining - 1)
      nil -> flunk("server stopped before mailbox quiescence")
    end
  end

  defp bytes(inputs), do: Enum.sum(Enum.map(inputs, &:erlang.external_size/1))
  defp normalize({:ok, response}), do: {:ok, response.text}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize_poll({:ok, :completed, response}), do: {:ok, response.text}
  defp normalize_poll({:error, reason}), do: {:error, reason}
  defp call(model, message), do: :gen_statem.call(model.pid, message, @timeout)
end
