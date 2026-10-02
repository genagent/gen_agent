defmodule GenAgent.HookBlockingTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgent.Support.TestAgent

  @blocked_ms 100

  defp start(opts) do
    name = "hook-blocking-#{System.unique_integer([:positive])}"

    base = [
      name: name,
      backend: Mock,
      scripts: [[Event.new(:result, %{text: "ok"})]],
      watchdog_ms: 5_000
    ]

    {:ok, pid} = GenAgent.start_agent(TestAgent, Keyword.merge(base, opts))

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(GenAgent.AgentSupervisor, pid)
    end)

    {name, pid}
  end

  # Announces that the hook started, then waits for :release.
  defp gate(parent) do
    fn state ->
      send(parent, {:gated, self()})

      receive do
        :release -> :ok
      end

      state
    end
  end

  defp assert_blocked(task) do
    assert Task.yield(task, @blocked_ms) == nil
  end

  describe "pre_run/1 gated" do
    test "delays synchronous calls but not start_agent/2, whereis/1 or notify/2" do
      hook = gate(self())

      # start_agent/2 returns while pre_run/1 is still blocked.
      {name, pid} = start(pre_run: fn state -> {:ok, hook.(state)} end)
      assert_receive {:gated, ^pid}, 1_000

      assert GenAgent.whereis(name) == pid
      assert GenAgent.notify(name, :ping) == :ok

      status = Task.async(fn -> GenAgent.status(name) end)
      snapshot = Task.async(fn -> GenAgent.runtime_snapshot(name) end)
      poll = Task.async(fn -> GenAgent.poll(name, make_ref()) end)
      notify_ack = Task.async(fn -> GenAgent.notify_ack(name, :ack) end)
      tell = Task.async(fn -> GenAgent.tell(name, "hello") end)
      calls = [status, snapshot, poll, notify_ack, tell]

      Enum.each(calls, &assert_blocked/1)

      send(pid, :release)

      assert Task.await(status, 2_000).name == name
      assert is_map(Task.await(snapshot, 2_000))
      assert {:error, :not_found} = Task.await(poll, 2_000)
      assert :ok = Task.await(notify_ack, 2_000)
      assert {:ok, _} = Task.await(tell, 2_000)
    end
  end

  describe "pre_turn/2 gated" do
    test "delays synchronous calls while the hook runs in the agent process" do
      hook = gate(self())

      {name, pid} =
        start(
          scripts: [
            [Event.new(:result, %{text: "ok"})],
            [Event.new(:result, %{text: "later"})]
          ],
          pre_turn: fn prompt, state ->
            if prompt == "go", do: {:ok, prompt, hook.(state)}, else: {:ok, prompt, state}
          end
        )

      ask = Task.async(fn -> GenAgent.ask(name, "go") end)
      assert_receive {:gated, ^pid}, 1_000

      assert GenAgent.whereis(name) == pid
      assert GenAgent.notify(name, :ping) == :ok

      status = Task.async(fn -> GenAgent.status(name) end)
      snapshot = Task.async(fn -> GenAgent.runtime_snapshot(name) end)
      poll = Task.async(fn -> GenAgent.poll(name, make_ref()) end)
      notify_ack = Task.async(fn -> GenAgent.notify_ack(name, :ack) end)
      tell = Task.async(fn -> GenAgent.tell(name, "later") end)
      Enum.each([status, snapshot, poll, notify_ack, tell], &assert_blocked/1)

      send(pid, :release)

      assert Task.await(status, 2_000).name == name
      assert is_map(Task.await(snapshot, 2_000))
      assert {:error, :not_found} = Task.await(poll, 2_000)
      assert :ok = Task.await(notify_ack, 2_000)
      assert {:ok, _} = Task.await(tell, 2_000)
      assert {:ok, _} = Task.await(ask, 2_000)
    end
  end
end
