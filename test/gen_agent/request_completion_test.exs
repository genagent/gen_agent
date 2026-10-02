defmodule GenAgent.RequestCompletionTest do
  use ExUnit.Case, async: false

  alias GenAgent.Event

  defmodule Backend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts), do: {:ok, opts}

    @impl true
    def prompt(session, prompt) do
      send(session[:observer], {:started, prompt, self()})

      case prompt do
        "error" -> {:error, :backend_failed}
        "held" -> wait_for_release(session, prompt)
        _ -> {:ok, [Event.new(:result, %{text: prompt})], session}
      end
    end

    defp wait_for_release(session, prompt) do
      receive do
        :release -> {:ok, [Event.new(:result, %{text: prompt})], session}
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
    def init_agent(opts), do: {:ok, opts, %{observer: Keyword.fetch!(opts, :observer)}}

    @impl true
    def pre_turn("skip", state), do: {:skip, state}
    def pre_turn("halt", state), do: {:halt, state}
    def pre_turn("invalid", _state), do: :invalid
    def pre_turn(prompt, state), do: {:ok, prompt, state}

    @impl true
    def handle_response(_ref, %{text: "crash"}, _state), do: raise("decision crashed")

    def handle_response(ref, _response, state) do
      send(state.observer, {:decision, ref})
      {:noreply, state}
    end

    @impl true
    def handle_error(ref, reason, state) do
      send(state.observer, {:error_callback, ref, reason})
      {:noreply, state}
    end

    @impl true
    def post_turn(outcome, ref, state) do
      send(state.observer, {:post_turn, ref, outcome})
      {:ok, state}
    end
  end

  defp start_agent(opts \\ []) do
    name = "completion-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      GenAgent.start_agent(
        Agent,
        Keyword.merge([name: name, backend: Backend, observer: self(), watchdog_ms: 10_000], opts)
      )

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    {name, pid}
  end

  test "fast completion is correlated and follows decision and post-turn callbacks" do
    {name, _pid} = start_agent()
    assert {:ok, ref} = GenAgent.tell_with_completion(name, "fast")
    assert_receive {:started, "fast", _task}, 1_000
    assert_receive {:decision, ^ref}, 1_000
    assert_receive {:post_turn, ^ref, {:ok, %{text: "fast"}}}, 1_000
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, %{text: "fast"}}}, 1_000
    refute_receive {:gen_agent, :completion, ^name, ^ref, _}, 50
  end

  test "completion survives result-cache eviction for a late consumer" do
    {name, _pid} = start_agent(max_tell_results: 1)
    assert {:ok, first} = GenAgent.tell_with_completion(name, "first")
    assert {:ok, second} = GenAgent.tell_with_completion(name, "second")
    assert_eventually(fn -> match?({:ok, :completed, _}, GenAgent.poll(name, second)) end)
    assert {:error, :not_found} = GenAgent.poll(name, first)
    assert_receive {:gen_agent, :completion, ^name, ^first, {:ok, %{text: "first"}}}, 1_000
    assert_receive {:gen_agent, :completion, ^name, ^second, {:ok, %{text: "second"}}}, 1_000
  end

  test "pre-turn gate outcomes complete without starting a backend turn" do
    for {prompt, reason} <- [
          skip: :pre_turn_skipped,
          halt: :pre_turn_halted,
          invalid: :pre_turn_invalid
        ] do
      {name, _pid} = start_agent()
      assert {:ok, ref} = GenAgent.tell_with_completion(name, Atom.to_string(prompt))
      assert_receive {:gen_agent, :completion, ^name, ^ref, {:error, ^reason}}, 1_000
      assert {:error, ^reason} = GenAgent.poll(name, ref)
      refute_receive {:started, _, _}, 0
      refute_receive {:post_turn, ^ref, _}, 0
    end
  end

  test "queued request retains recipient and overload does not create a completion" do
    {name, _pid} = start_agent(max_pending_prompts: 1)
    assert {:ok, first} = GenAgent.tell_with_completion(name, "held")
    assert_receive {:started, "held", task}, 1_000
    assert {:ok, second} = GenAgent.tell_with_completion(name, "queued")
    assert {:error, {:overloaded, _}} = GenAgent.tell_with_completion(name, "rejected")
    refute_receive {:gen_agent, :completion, ^name, ^second, _}, 0
    send(task, :release)
    assert_receive {:gen_agent, :completion, ^name, ^first, {:ok, _}}, 1_000
    assert_receive {:gen_agent, :completion, ^name, ^second, {:ok, %{text: "queued"}}}, 1_000
  end

  test "halt-aware admission rejects atomically while halted without affecting ordinary queued work" do
    {name, pid} = start_agent()
    assert {:ok, halt_ref} = GenAgent.tell_with_completion(name, "halt")
    assert_receive {:gen_agent, :completion, ^name, ^halt_ref, {:error, :pre_turn_halted}}

    assert {:error, :halted} =
             GenAgent.tell_with_completion(name, "rejected", self(), :infinity, on_halt: :fail)

    refute_receive {:started, "rejected", _}, 0
    assert {:ok, queued_ref} = GenAgent.tell_with_completion(name, "ordinary")
    assert {:ok, :pending} = GenAgent.poll(name, queued_ref)
    assert Process.alive?(pid)

    :ok = GenAgent.resume(name)
    assert_receive {:gen_agent, :completion, ^name, ^queued_ref, {:ok, %{text: "ordinary"}}}
  end

  test "halting fails only opted-in queued completions, once, while preserving FIFO survivors" do
    {name, _pid} = start_agent()
    assert {:ok, active_ref} = GenAgent.tell_with_completion(name, "held")
    assert_receive {:started, "held", task}, 1_000

    assert {:ok, halt_ref} = GenAgent.tell_with_completion(name, "halt")

    assert {:ok, failed_a} =
             GenAgent.tell_with_completion(name, "failed-a", self(), :infinity, on_halt: :fail)

    assert {:ok, surviving} = GenAgent.tell_with_completion(name, "surviving")

    assert {:ok, failed_b} =
             GenAgent.tell_with_completion(name, "failed-b", self(), :infinity, on_halt: :fail)

    send(task, :release)
    assert_receive {:gen_agent, :completion, ^name, ^active_ref, {:ok, _}}
    assert_receive {:gen_agent, :completion, ^name, ^halt_ref, {:error, :pre_turn_halted}}
    assert_receive {:gen_agent, :completion, ^name, ^failed_a, {:error, :halted}}
    assert_receive {:gen_agent, :completion, ^name, ^failed_b, {:error, :halted}}
    assert {:error, :halted} = GenAgent.poll(name, failed_a)
    assert {:error, :halted} = GenAgent.poll(name, failed_b)
    assert {:ok, :pending} = GenAgent.poll(name, surviving)
    assert GenAgent.runtime_snapshot(name).pending_prompts == 1
    refute_receive {:started, "failed-a", _}, 0
    refute_receive {:started, "failed-b", _}, 0

    :ok = GenAgent.resume(name)
    assert_receive {:gen_agent, :completion, ^name, ^surviving, {:ok, %{text: "surviving"}}}
    refute_receive {:gen_agent, :completion, ^name, ^failed_a, _}, 0
    refute_receive {:gen_agent, :completion, ^name, ^failed_b, _}, 0
  end

  test "halt-aware queued completion can still be cancelled by exact ref" do
    {name, _pid} = start_agent()
    assert {:ok, active_ref} = GenAgent.tell_with_completion(name, "held")
    assert_receive {:started, "held", task}, 1_000

    assert {:ok, queued_ref} =
             GenAgent.tell_with_completion(name, "queued", self(), :infinity, on_halt: :fail)

    assert {:ok, :cancelled} = GenAgent.cancel_request(name, queued_ref)
    assert_receive {:gen_agent, :completion, ^name, ^queued_ref, {:error, :cancelled}}
    assert {:error, :cancelled} = GenAgent.poll(name, queued_ref)

    send(task, :release)
    assert_receive {:gen_agent, :completion, ^name, ^active_ref, {:ok, _}}
    refute_receive {:gen_agent, :completion, ^name, ^queued_ref, _}, 0
  end

  test "backend error, interrupt, and watchdog each deliver one error outcome" do
    {name, _pid} = start_agent()
    assert {:ok, error_ref} = GenAgent.tell_with_completion(name, "error")
    assert_receive {:gen_agent, :completion, ^name, ^error_ref, {:error, :backend_failed}}, 1_000

    assert {:ok, interrupted_ref} = GenAgent.tell_with_completion(name, "held")
    assert_receive {:started, "held", task}, 1_000
    assert {:ok, :accepted} = GenAgent.interrupt_request(name, interrupted_ref)

    assert_receive {:gen_agent, :completion, ^name, ^interrupted_ref, {:error, :interrupted}},
                   1_000

    refute Process.alive?(task)
    refute_receive {:gen_agent, :completion, ^name, ^interrupted_ref, _}, 50

    {timeout_name, _pid} = start_agent(watchdog_ms: 50)
    assert {:ok, timeout_ref} = GenAgent.tell_with_completion(timeout_name, "held")
    assert_receive {:started, "held", _task}, 1_000

    assert_receive {:gen_agent, :completion, ^timeout_name, ^timeout_ref, {:error, :timeout}},
                   1_000

    refute_receive {:gen_agent, :completion, ^timeout_name, ^timeout_ref, _}, 50
  end

  test "recipient can be another process" do
    {name, _pid} = start_agent()
    parent = self()

    recipient =
      spawn(fn ->
        receive do
          message -> send(parent, {:forwarded, message})
        end
      end)

    assert {:ok, ref} = GenAgent.tell_with_completion(name, "fast", recipient)
    assert_receive {:forwarded, {:gen_agent, :completion, ^name, ^ref, {:ok, _}}}, 1_000
    refute_receive {:gen_agent, :completion, ^name, ^ref, _}, 0
  end

  test "recipient death does not stop the agent" do
    {name, pid} = start_agent()
    recipient = spawn(fn -> :ok end)
    recipient_monitor = Process.monitor(recipient)
    assert_receive {:DOWN, ^recipient_monitor, :process, ^recipient, _}, 1_000

    assert {:ok, ref} = GenAgent.tell_with_completion(name, "fast", recipient)
    assert_eventually(fn -> match?({:ok, :completed, _}, GenAgent.poll(name, ref)) end)
    assert Process.alive?(pid)
  end

  test "a completion and exact-request interrupt race has one outcome" do
    {name, _pid} = start_agent()

    for _ <- 1..12 do
      assert {:ok, ref} = GenAgent.tell_with_completion(name, "held")
      assert_receive {:started, "held", task}, 1_000
      send(task, :release)

      assert GenAgent.interrupt_request(name, ref) in [
               {:ok, :accepted},
               {:error, :not_current},
               {:error, :idle}
             ]

      assert_receive {:gen_agent, :completion, ^name, ^ref, outcome}, 1_000
      assert match?({:ok, _}, outcome) or outcome == {:error, :interrupted}
      refute_receive {:gen_agent, :completion, ^name, ^ref, _}, 0
    end
  end

  test "stopping an agent leaves queued accepted work without invented completion" do
    {name, pid} = start_agent()
    monitor = Process.monitor(pid)
    assert {:ok, active_ref} = GenAgent.tell_with_completion(name, "held")
    assert_receive {:started, "held", _task}, 1_000
    assert {:ok, queued_ref} = GenAgent.tell_with_completion(name, "queued")
    assert :ok = GenAgent.stop(name)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
    refute_receive {:gen_agent, :completion, ^name, ^active_ref, _}, 50
    refute_receive {:gen_agent, :completion, ^name, ^queued_ref, _}, 50
  end

  test "callback crash and agent death leave outcome uncertain; replacement uses a new ref" do
    {name, pid} = start_agent()
    monitor = Process.monitor(pid)
    assert {:ok, crashed_ref} = GenAgent.tell_with_completion(name, "crash")
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    refute_receive {:gen_agent, :completion, ^name, ^crashed_ref, _}, 50

    {:ok, _replacement} =
      GenAgent.start_agent(Agent,
        name: name,
        backend: Backend,
        observer: self(),
        watchdog_ms: 10_000
      )

    assert {:ok, replacement_ref} = GenAgent.tell_with_completion(name, "fast")
    refute replacement_ref == crashed_ref
    assert_receive {:gen_agent, :completion, ^name, ^replacement_ref, {:ok, _}}, 1_000
    refute_receive {:gen_agent, :completion, ^name, ^crashed_ref, _}, 0
  end

  defp assert_eventually(fun, attempts \\ 30)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
