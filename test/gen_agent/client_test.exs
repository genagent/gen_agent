defmodule GenAgent.ClientTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias GenAgent.{Client, Event}

  defmodule Backend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts), do: {:ok, Keyword.fetch!(opts, :observer)}

    @impl true
    def prompt(observer, prompt) do
      send(observer, {:backend, prompt, self()})

      receive do
        :release -> {:ok, [Event.new(:result, %{text: prompt})], observer}
        {:finish, events} -> {:ok, events, observer}
      after
        5_000 -> {:error, :fixture_deadline}
      end
    end

    @impl true
    def terminate_session(_session), do: :ok
  end

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, opts, Map.new(opts)}

    @impl true
    def pre_run(state) do
      if state[:gate_pre_run], do: gate(state.observer, :pre_run)
      {:ok, state}
    end

    @impl true
    def pre_turn(prompt, state) do
      if state[:gate_prompt] == prompt, do: gate(state.observer, :pre_turn)

      case prompt do
        "skip" -> {:skip, state}
        "halt" -> {:halt, state}
        "invalid" -> :invalid
        "crash" -> raise "fixture"
        _ -> {:ok, prompt, state}
      end
    end

    @impl true
    def handle_response(ref, _response, state) do
      send(state.observer, {:decision, ref})
      {:noreply, state}
    end

    @impl true
    def handle_error(ref, reason, state) do
      send(state.observer, {:error_callback, ref, reason})
      if state[:retry], do: {:prompt, "retry", state}, else: {:noreply, state}
    end

    @impl true
    def handle_event(:halt, state), do: {:halt, state}

    def handle_event(event, state) do
      send(state.observer, {:notification, self(), event})
      {:noreply, state}
    end

    @impl true
    def post_turn(outcome, ref, state) do
      send(state.observer, {:post_turn, ref, outcome})
      {:ok, state}
    end

    @impl true
    def post_run(state) do
      if state[:gate_post_run], do: gate(state.observer, :post_run)
      :ok
    end

    defp gate(observer, label) do
      send(observer, {:gate, label, self()})

      receive do
        :release -> :ok
      after
        5_000 -> exit(:fixture_deadline)
      end
    end
  end

  defp start_agent(opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: {:submission, make_ref()},
          backend: Backend,
          observer: self(),
          watchdog_ms: 10_000
        ],
        opts
      )

    name = Keyword.fetch!(opts, :name)
    {:ok, pid} = GenAgent.start_agent(Agent, opts)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {name, pid}
  end

  # Select across protocol kinds, rather than skipping an unexpected admission,
  # completion or DOWN while waiting for an expected one.
  defp next_message do
    receive do
      {:gen_agent, _, _, _, _} = message -> message
      {:DOWN, _, :process, _, _} = message -> message
    after
      1_000 -> flunk("missing agent protocol message")
    end
  end

  defp next_lifecycle_message do
    receive do
      {:decision, _} = message -> message
      {:post_turn, _, _} = message -> message
      {:gen_agent, _, _, _, _} = message -> message
    after
      1_000 -> flunk("missing lifecycle observation")
    end
  end

  defp accept(name, ref) do
    assert {:gen_agent, :admission, ^name, ^ref, :ok} = next_message()
  end

  defp complete(name, ref, text) do
    assert {:gen_agent, :completion, ^name, ^ref, {:ok, %{text: ^text}}} = next_message()
  end

  defp data(pid) do
    {_phase, data} = :sys.get_state(pid)
    data
  end

  defp empty_pending(pid) do
    state = data(pid)
    assert state.pending_prompt_bytes == 0
    assert :queue.is_empty(state.mailbox)
    assert state.stream_recipients == %{}
  end

  test "submissions return correlated refs while idle pre_turn is held" do
    {name, pid} = start_agent(gate_prompt: "held")
    {:submitted, first} = Client.submit_with_completion(pid, "held")
    assert_receive {:gate, :pre_turn, ^pid}
    {:submitted, second} = Client.submit_with_completion(pid, "queued")
    assert first != second
    refute_received {:gen_agent, _, ^name, _, _}

    send(pid, :release)
    accept(name, first)
    accept(name, second)
    assert_receive {:backend, "held", task}
    assert {:ok, :pending} = Client.poll(pid, first)
    assert {:ok, :pending} = Client.poll(pid, second)
    send(task, :release)
    complete(name, first, "held")
    assert_receive {:backend, "queued", queued}
    send(queued, :release)
    complete(name, second, "queued")
    assert {:ok, :completed, %{text: "held"}} = Client.poll(pid, first)
    assert {:ok, :completed, %{text: "queued"}} = Client.poll(pid, second)
    empty_pending(pid)
  end

  test "submission also returns while pre_run is held" do
    {name, pid} = start_agent(gate_pre_run: true)
    assert_receive {:gate, :pre_run, ^pid}
    {:submitted, ref} = Client.submit_with_completion(pid, "go")
    refute_received {:gen_agent, _, ^name, ^ref, _}
    send(pid, :release)
    accept(name, ref)
    assert_receive {:backend, "go", task}
    send(task, :release)
    complete(name, ref, "go")
  end

  test "queued count and byte overloads reject without retaining a recipient or result" do
    for opts <- [
          [max_pending_prompts: 1],
          [max_pending_prompt_bytes: :erlang.external_size("queued")]
        ] do
      {name, pid} = start_agent(opts)
      {:submitted, active} = Client.submit_with_completion(pid, "held")
      accept(name, active)
      assert_receive {:backend, "held", task}

      {:submitted, queued} =
        Client.submit_with_completion(pid, "queued", self(), stream_to: self())

      accept(name, queued)

      {:submitted, rejected} =
        Client.submit_with_completion(pid, "overflow", self(), stream_to: self())

      assert {:gen_agent, :admission, ^name, ^rejected, {:error, {:overloaded, info}}} =
               next_message()

      assert info.queue == :prompts

      assert info.limit ==
               if(Keyword.has_key?(opts, :max_pending_prompts), do: :count, else: :bytes)

      assert {:error, :not_found} = Client.poll(pid, rejected)
      assert data(pid).stream_recipients == %{queued => self()}
      assert data(pid).pending_prompt_bytes == :erlang.external_size("queued")
      assert {:ok, :cancelled} = Client.cancel_request(pid, queued)
      assert {:gen_agent, :completion, ^name, ^queued, {:error, :cancelled}} = next_message()
      assert {:ok, :cancelled} = Client.cancel_request(pid, queued)
      empty_pending(pid)
      send(task, :release)
      complete(name, active, "held")
      assert {:error, :not_found} = Client.poll(pid, rejected)
      refute_received {:gen_agent, _, ^name, ^rejected, _}
    end
  end

  test "idle dispatch bypasses zero pending budgets and completions survive a zero cache" do
    {name, pid} =
      start_agent(max_pending_prompts: 0, max_pending_prompt_bytes: 0, max_tell_results: 0)

    {:submitted, ref} = Client.submit_with_completion(pid, "larger than zero")
    accept(name, ref)
    assert_receive {:backend, "larger than zero", task}
    send(task, :release)
    complete(name, ref, "larger than zero")
    assert {:error, :not_found} = Client.poll(pid, ref)
    assert data(pid).tell_results == %{}
    empty_pending(pid)
  end

  test "idle hook rejection completes before admission and never starts a turn" do
    for {prompt, reason} <- [
          {"skip", :pre_turn_skipped},
          {"halt", :pre_turn_halted},
          {"invalid", :pre_turn_invalid},
          {"crash", :pre_turn_skipped}
        ] do
      {name, pid} = start_agent()
      {:submitted, ref} = Client.submit_with_completion(pid, prompt, self(), stream_to: self())
      assert {:gen_agent, :completion, ^name, ^ref, {:error, ^reason}} = next_message()
      accept(name, ref)
      assert {:error, ^reason} = Client.poll(pid, ref)
      refute_received {:backend, _, _}
      refute_received {:post_turn, ^ref, _}
      empty_pending(pid)
    end
  end

  test "unavailable task supervisor also completes before admission" do
    {:ok, supervisor} = Task.Supervisor.start_link()

    spec =
      GenAgent.child_spec(Agent,
        name: {:no_tasks, make_ref()},
        backend: Backend,
        observer: self(),
        task_supervisor: supervisor
      )

    {:ok, pid} = start_supervised(spec)
    Supervisor.stop(supervisor)
    {:submitted, ref} = Client.submit_with_completion(pid, "go")

    assert {:gen_agent, :completion, _, ^ref, {:error, :task_supervisor_unavailable}} =
             next_message()

    assert {:gen_agent, :admission, _, ^ref, :ok} = next_message()
    empty_pending(pid)
  end

  test "halted admission rejects fail-aware work and queues ordinary work until resume" do
    {name, pid} = start_agent()
    {:submitted, halt} = Client.submit_with_completion(pid, "halt")
    assert {:gen_agent, :completion, ^name, ^halt, {:error, :pre_turn_halted}} = next_message()
    accept(name, halt)

    {:submitted, rejected} =
      Client.submit_with_completion(pid, "rejected", self(), on_halt: :fail)

    assert {:gen_agent, :admission, ^name, ^rejected, {:error, :halted}} = next_message()
    {:submitted, queued} = Client.submit_with_completion(pid, "queued")
    accept(name, queued)
    assert {:ok, :pending} = Client.poll(pid, queued)
    assert {:error, :not_found} = Client.poll(pid, rejected)
    GenAgent.resume(name)
    assert_receive {:backend, "queued", task}
    send(task, :release)
    complete(name, queued, "queued")
    empty_pending(pid)
  end

  test "accepted fail-aware queued work receives a halted completion" do
    {name, pid} = start_agent()
    {:submitted, active} = Client.submit_with_completion(pid, "held")
    accept(name, active)
    assert_receive {:backend, "held", task}
    {:submitted, halt} = Client.submit_with_completion(pid, "halt")
    accept(name, halt)

    {:submitted, failed} =
      Client.submit_with_completion(pid, "fail", self(), on_halt: :fail, stream_to: self())

    accept(name, failed)
    send(task, :release)
    complete(name, active, "held")
    assert {:gen_agent, :completion, ^name, ^halt, {:error, :pre_turn_halted}} = next_message()
    assert {:gen_agent, :completion, ^name, ^failed, {:error, :halted}} = next_message()
    assert {:error, :halted} = Client.poll(pid, failed)
    empty_pending(pid)
  end

  test "drain fails admitted queued work and rejects later submissions while active finishes" do
    {name, pid} = start_agent()
    monitor = Process.monitor(pid)
    {:submitted, active} = Client.submit_with_completion(pid, "held")
    accept(name, active)
    assert_receive {:backend, "held", task}
    {:submitted, queued} = Client.submit_with_completion(pid, "queued", self(), stream_to: self())
    accept(name, queued)
    # The existing server drain call is an explicit admission barrier; public
    # GenAgent.drain additionally waits for exit.
    assert :ok = :gen_statem.call(pid, :drain)
    assert {:gen_agent, :completion, ^name, ^queued, {:error, :draining}} = next_message()
    {:submitted, rejected} = Client.submit_with_completion(pid, "rejected")
    assert {:gen_agent, :admission, ^name, ^rejected, {:error, :draining}} = next_message()
    assert {:error, :not_found} = Client.poll(pid, rejected)
    empty_pending(pid)
    send(task, :release)
    complete(name, active, "held")
    assert {:DOWN, ^monitor, :process, ^pid, :normal} = next_message()
    refute_received {:gen_agent, _, ^name, ^rejected, _}
  end

  test "queued cancellation and exact interruption preserve unrelated refs" do
    {name, pid} = start_agent()
    {:submitted, active} = Client.submit_with_completion(pid, "held")
    accept(name, active)
    assert_receive {:backend, "held", _task}

    {:submitted, cancelled} =
      Client.submit_with_completion(pid, "cancel", self(), stream_to: self())

    accept(name, cancelled)
    {:submitted, survivor} = Client.submit_with_completion(pid, "survivor")
    accept(name, survivor)
    assert {:ok, :cancelled} = Client.cancel_request(pid, cancelled)
    assert {:gen_agent, :completion, ^name, ^cancelled, {:error, :cancelled}} = next_message()
    assert {:error, :current} = Client.cancel_request(pid, active)
    assert {:ok, :accepted} = Client.interrupt_request(pid, active)
    assert {:gen_agent, :completion, ^name, ^active, {:error, :interrupted}} = next_message()
    assert_receive {:backend, "survivor", surviving_task}
    assert {:error, :not_current} = Client.interrupt_request(pid, active)
    assert {:ok, :cancelled} = Client.cancel_request(pid, cancelled)
    assert {:ok, :pending} = Client.poll(pid, survivor)
    send(surviving_task, :release)
    complete(name, survivor, "survivor")
    refute_received {:backend, "cancel", _}
    refute_received {:post_turn, ^cancelled, _}
    empty_pending(pid)
  end

  test "cleanup cannot be confirmed while pre_turn blocks; timeout remains uncertainty" do
    {name, pid} = start_agent(gate_prompt: "held")
    {:submitted, ref} = Client.submit_with_completion(pid, "held")
    assert_receive {:gate, :pre_turn, ^pid}
    caller = Task.async(fn -> catch_exit(Client.cancel_request(pid, ref, 0)) end)
    assert {:timeout, {:gen_statem, :call, _}} = Task.await(caller)
    # No replacement submission: the same physical ref still owns this slot.
    refute_received {:gen_agent, _, ^name, ^ref, _}
    send(pid, :release)
    accept(name, ref)
    assert_receive {:backend, "held", _task}
    assert {:error, :current} = Client.cancel_request(pid, ref)
    assert {:ok, :accepted} = Client.interrupt_request(pid, ref)
    assert {:gen_agent, :completion, ^name, ^ref, {:error, :interrupted}} = next_message()
    empty_pending(pid)
  end

  test "stream events from retries keep the original ref, with one admission and completion" do
    {name, pid} = start_agent(retry: true, max_events_per_turn: 1)
    {:submitted, ref} = Client.submit_with_completion(pid, "first", self(), stream_to: self())
    accept(name, ref)
    assert_receive {:backend, "first", first}
    {:submitted, queued} = Client.submit_with_completion(pid, "queued")
    accept(name, queued)

    send(
      first,
      {:finish, [Event.new(:text, %{text: "first"}), Event.new(:error, %{reason: :again})]}
    )

    assert {:gen_agent, :event, ^name, ^ref, %Event{kind: :text}} = next_message()
    assert {:gen_agent, :event, ^name, ^ref, %Event{kind: :error}} = next_message()
    assert_receive {:backend, "retry", retry}
    assert {:ok, :pending} = Client.poll(pid, ref)
    assert GenAgent.runtime_snapshot(name).current_request.ref == ref

    send(
      retry,
      {:finish, [Event.new(:text, %{text: "second"}), Event.new(:result, %{text: "done"})]}
    )

    assert {:gen_agent, :event, ^name, ^ref, %Event{kind: :text}} = next_message()
    assert {:gen_agent, :event, ^name, ^ref, %Event{kind: :result}} = next_message()
    assert {:gen_agent, :completion, ^name, ^ref, {:ok, response}} = next_message()
    assert response.text == "done"
    assert response.event_coverage.mode == :compact
    assert_receive {:backend, "queued", task}
    send(task, :release)
    complete(name, queued, "queued")
    assert {:ok, :completed, _} = Client.poll(pid, ref)
    refute_received {:gen_agent, _, ^name, ^ref, _}
    empty_pending(pid)
  end

  test "monitor observes death before handling without invented admission or completion" do
    {name, pid} = start_agent(gate_pre_run: true)
    assert_receive {:gate, :pre_run, ^pid}
    monitor = Process.monitor(pid)
    {:submitted, ref} = Client.submit_with_completion(pid, "go")
    Process.exit(pid, :kill)
    assert {:DOWN, ^monitor, :process, ^pid, :killed} = next_message()
    refute_received {:gen_agent, _, ^name, ^ref, _}
  end

  test "death during pre_turn or after acceptance leaves only the known protocol state" do
    for phase <- [:pre_turn, :backend] do
      {name, pid} = start_agent(gate_prompt: if(phase == :pre_turn, do: "held"))
      monitor = Process.monitor(pid)
      {:submitted, ref} = Client.submit_with_completion(pid, "held")

      if phase == :pre_turn do
        assert_receive {:gate, :pre_turn, ^pid}
      else
        accept(name, ref)
        assert_receive {:backend, "held", _task}
      end

      Process.exit(pid, :kill)
      assert {:DOWN, ^monitor, :process, ^pid, :killed} = next_message()
      refute_received {:gen_agent, _, ^name, ^ref, _}
    end
  end

  test "completion may be known before death even when admission never arrives" do
    {name, pid} = start_agent(gate_post_run: true)
    monitor = Process.monitor(pid)
    {:submitted, ref} = Client.submit_with_completion(pid, "halt")
    assert {:gen_agent, :completion, ^name, ^ref, {:error, :pre_turn_halted}} = next_message()
    assert_receive {:gate, :post_run, ^pid}
    Process.exit(pid, :kill)
    assert {:DOWN, ^monitor, :process, ^pid, :killed} = next_message()
    refute_received {:gen_agent, :admission, ^name, ^ref, _}
  end

  test "normal completion follows lifecycle callbacks and remains known before DOWN" do
    {name, pid} = start_agent()
    monitor = Process.monitor(pid)
    {:submitted, ref} = Client.submit_with_completion(pid, "go")
    accept(name, ref)
    assert_receive {:backend, "go", task}
    send(task, :release)

    # Consume callback observations along with protocol messages, so an early
    # completion cannot be skipped by a selective lifecycle receive.
    assert {:decision, ^ref} = next_lifecycle_message()
    assert {:post_turn, ^ref, {:ok, %{text: "go"}}} = next_lifecycle_message()
    complete(name, ref, "go")
    assert :ok = GenAgent.stop(name)
    assert {:DOWN, ^monitor, :process, ^pid, :shutdown} = next_message()
    refute_received {:gen_agent, _, ^name, ^ref, _}
  end

  test "an explicit recipient receives both admission and completion directly from the child" do
    {name, pid} = start_agent()
    observer = self()

    recipient =
      spawn(fn ->
        for _ <- 1..2 do
          receive do
            message -> send(observer, {:recipient, message})
          end
        end
      end)

    monitor = Process.monitor(recipient)
    {:submitted, ref} = Client.submit_with_completion(pid, "go", recipient)
    assert_receive {:recipient, {:gen_agent, :admission, ^name, ^ref, :ok}}
    assert_receive {:backend, "go", task}
    send(task, :release)
    assert_receive {:recipient, {:gen_agent, :completion, ^name, ^ref, {:ok, %{text: "go"}}}}
    assert_receive {:DOWN, ^monitor, :process, ^recipient, :normal}
    assert {:ok, :completed, _} = Client.poll(pid, ref)
    refute_received {:gen_agent, _, ^name, ^ref, _}
  end

  test "notify delivers to the captured live PID without waiting for callbacks" do
    {_name, pid} = start_agent(gate_pre_run: true)
    assert_receive {:gate, :pre_run, ^pid}
    caller = Task.async(fn -> Client.notify(pid, {:event, 1}) end)
    assert :ok = Task.await(caller, 1_000)
    send(pid, :release)
    assert_receive {:notification, ^pid, {:event, 1}}
  end

  test "notify rejects a dead captured PID without delivering to its named replacement" do
    {name, old} = start_agent()
    assert :ok = Client.notify(old, :original)
    assert_receive {:notification, ^old, :original}
    monitor = Process.monitor(old)
    assert :ok = GenAgent.stop(name)
    assert_receive {:DOWN, ^monitor, :process, ^old, _}
    {^name, replacement} = start_agent(name: name)
    assert GenAgent.whereis(name) == replacement

    caller = Task.async(fn -> Client.notify(old, :lost) end)
    assert {:error, :not_alive} = Task.await(caller, 1_000)
    # Same-sender barrier proves the replacement processed all preceding casts.
    assert :ok = Client.notify(replacement, :barrier)
    assert_receive {:notification, ^replacement, :barrier}
    refute_received {:notification, ^replacement, :lost}
  end

  test "named notify still resolves a PID-valued Registry name" do
    name = self()
    {^name, pid} = start_agent(name: name)
    assert :ok = GenAgent.notify(name, :named)
    assert_receive {:notification, ^pid, :named}
    refute_received {:"$gen_cast", {:notify, :named}}
    assert :ok = Client.notify(name, :direct)
    assert_received {:"$gen_cast", {:notify, :direct}}
  end

  test "dead PID submission and controls never retarget a replacement under the same name" do
    {name, old} = start_agent()
    monitor = Process.monitor(old)
    assert :ok = GenAgent.stop(name)
    assert {:DOWN, ^monitor, :process, ^old, _} = next_message()
    {^name, replacement} = start_agent(name: name)
    {:submitted, ref} = Client.submit_with_completion(old, "lost")

    for operation <- [&Client.poll/2, &Client.cancel_request/2, &Client.interrupt_request/2] do
      assert {:noproc, {:gen_statem, :call, _}} = catch_exit(operation.(old, ref))
    end

    assert GenAgent.status(name).current_request == nil
    assert GenAgent.whereis(name) == replacement
    refute_received {:backend, "lost", _}
    refute_received {:gen_agent, _, ^name, ^ref, _}
  end

  test "PID-valued and tuple-valued names keep existing name interpretation" do
    for name <- [self(), {:pid, self()}] do
      {^name, pid} = start_agent(name: name)
      assert GenAgent.whereis(name) == pid
      assert {:ok, named_ref} = GenAgent.tell_with_completion(name, "named")
      assert_receive {:backend, "named", named_task}
      send(named_task, :release)
      # The named API emits no new admission message.
      complete(name, named_ref, "named")
      assert {:error, :not_found} = GenAgent.poll(pid, named_ref)
      assert {:ok, :completed, _} = Client.poll(pid, named_ref)
      {:submitted, pinned_ref} = Client.submit_with_completion(pid, "pinned")
      accept(name, pinned_ref)
      assert_receive {:backend, "pinned", pinned_task}
      send(pinned_task, :release)
      complete(name, pinned_ref, "pinned")
      GenAgent.stop(name)
    end
  end

  test "invalid public input is rejected before sending" do
    for args <- [
          [:name, "go", self(), []],
          [self(), :bad_prompt, self(), []],
          [self(), "go", :bad_recipient, []],
          [self(), "go", self(), :bad_options],
          [self(), "go", self(), [:bad_options]],
          [self(), "go", self(), [on_halt: :bad]],
          [self(), "go", self(), [stream_to: :bad]],
          [self(), "go", self(), [ref: make_ref()]]
        ] do
      assert_raise ArgumentError, fn -> apply(Client, :submit_with_completion, args) end
      refute_received {:"$gen_cast", _}
    end

    # External term encoding lets this local-only test construct a remote PID
    # without starting distribution or connecting to another node.
    node_name = "remote@invalid"

    remote =
      :erlang.binary_to_term(
        <<131, 103, 100, byte_size(node_name)::16, node_name::binary, 0::32, 0::32, 0>>
      )

    assert is_pid(remote) and node(remote) != node()
    assert_raise ArgumentError, fn -> Client.submit_with_completion(remote, "go") end

    for target <- [:name, "name", {:pid, self()}, nil, 42, remote] do
      assert_raise ArgumentError, "expected a local agent pid", fn ->
        Client.notify(target, :event)
      end
    end

    refute_received {:"$gen_cast", {:notify, _}}

    for operation <- [&Client.poll/2, &Client.cancel_request/2, &Client.interrupt_request/2] do
      assert_raise ArgumentError, fn -> operation.(remote, make_ref()) end
      assert_raise ArgumentError, fn -> operation.(self(), :bad_ref) end
    end
  end
end
