defmodule GenAgent.InterruptRequestTest do
  use ExUnit.Case, async: true

  alias GenAgent.Event
  import GenAgent.TestDownAssertions
  import GenAgent.TestPollingAssertions

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      {:ok, [scripts: Keyword.fetch!(opts, :scripts)],
       %{outcomes: [], observer: Keyword.fetch!(opts, :observer)}}
    end

    @impl true
    def handle_response(ref, response, state) do
      send(state.observer, {:completed, ref})
      {:noreply, %{state | outcomes: [{ref, {:ok, response.text}} | state.outcomes]}}
    end

    @impl true
    def handle_error(ref, reason, state) do
      send(state.observer, {:completed, ref})
      {:noreply, %{state | outcomes: [{ref, {:error, reason}} | state.outcomes]}}
    end
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

  defp start_agent(scripts, name \\ nil) do
    name = name || "interrupt-ref-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      GenAgent.start_agent(Agent,
        name: name,
        backend: GenAgent.Backends.Mock,
        scripts: scripts,
        observer: self()
      )

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    name
  end

  test "matching active request is interrupted and acknowledged once" do
    name = start_agent([blocked_turn(:a)])
    assert {:ok, ref} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, task_pid}
    assert GenAgent.status(name).current_request == ref
    task_monitor = Process.monitor(task_pid)

    assert {:ok, :accepted} = GenAgent.interrupt_request(name, ref)
    assert_killed_or_gone(task_monitor, task_pid)
    assert_receive {:completed, ^ref}
    assert {:error, :interrupted} = GenAgent.poll(name, ref)
    assert GenAgent.status(name).agent_state.outcomes == [{ref, {:error, :interrupted}}]

    assert {:error, :idle} = GenAgent.interrupt_request(name, ref)
    assert GenAgent.status(name).agent_state.outcomes == [{ref, {:error, :interrupted}}]
  end

  test "stale A reference cannot interrupt successor B" do
    name = start_agent([blocked_turn(:a), blocked_turn(:b)])
    assert {:ok, ref_a} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, task_a}
    assert {:ok, ref_b} = GenAgent.tell(name, "B")

    send(task_a, {:release, :a})
    assert_receive {:turn_started, :b, task_b}
    assert {:ok, :completed, %{text: "a"}} = GenAgent.poll(name, ref_a)

    assert {:error, :not_current} = GenAgent.interrupt_request(name, ref_a)
    assert {:ok, :pending} = GenAgent.poll(name, ref_b)
    assert Process.alive?(task_b)

    send(task_b, {:release, :b})
    assert_receive {:completed, ^ref_b}
    assert {:ok, :completed, %{text: "b"}} = GenAgent.poll(name, ref_b)

    assert GenAgent.status(name).agent_state.outcomes == [
             {ref_b, {:ok, "b"}},
             {ref_a, {:ok, "a"}}
           ]
  end

  test "idle agent reports no active request" do
    name = start_agent([])
    assert {:error, :idle} = GenAgent.interrupt_request(name, make_ref())
  end

  test "old request reference cannot interrupt a replacement with the same name" do
    name = start_agent([blocked_turn(:a)])
    assert {:ok, old_ref} = GenAgent.tell(name, "A")
    assert_receive {:turn_started, :a, old_task}
    old_task_monitor = Process.monitor(old_task)

    assert :ok = GenAgent.stop(name)
    assert_killed_or_gone(old_task_monitor, old_task)
    wait_until(fn -> GenAgent.whereis(name) == nil end, interval: 5)

    start_agent([blocked_turn(:b)], name)
    assert {:ok, new_ref} = GenAgent.tell(name, "B")
    assert_receive {:turn_started, :b, new_task}

    assert {:error, :not_current} = GenAgent.interrupt_request(name, old_ref)
    assert {:ok, :pending} = GenAgent.poll(name, new_ref)
    assert Process.alive?(new_task)

    send(new_task, {:release, :b})
    assert_receive {:completed, ^new_ref}
    assert {:ok, :completed, %{text: "b"}} = GenAgent.poll(name, new_ref)
  end
end
