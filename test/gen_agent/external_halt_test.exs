defmodule GenAgent.ExternalHaltTest do
  use ExUnit.Case, async: true

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgent.Support.TestAgent

  setup do
    name = "external-halt-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    %{name: name}
  end

  defp start(name, scripts, observer) do
    GenAgent.start_agent(TestAgent,
      name: name,
      backend: Mock,
      scripts: scripts,
      post_run: fn state ->
        send(observer, {:post_run, length(state.responses)})
        :ok
      end
    )
  end

  test "halt pauses an idle agent and is idempotent", %{name: name} do
    {:ok, _pid} = start(name, [[Event.new(:result, %{text: "after resume"})]], self())

    assert :ok = GenAgent.halt(name)
    assert :ok = GenAgent.halt(name)
    assert %{halted: true, halt_pending: false} = GenAgent.status(name)
    assert_receive {:post_run, 0}
    refute_receive {:post_run, _}, 0

    assert :ok = GenAgent.resume(name)
    assert {:ok, response} = GenAgent.ask(name, "go")
    assert response.text == "after resume"
  end

  test "halt during a turn waits for its callbacks and pauses queued work", %{name: name} do
    scripts = [
      Mock.gate(:first, [Event.new(:result, %{text: "first"})]),
      [Event.new(:result, %{text: "second"})]
    ]

    {:ok, _pid} = start(name, scripts, self())
    assert {:ok, first_ref} = GenAgent.tell_with_completion(name, "first")
    assert_receive {:mock_blocked, :first, task_pid}
    assert {:ok, second_ref} = GenAgent.tell_with_completion(name, "second")

    assert :ok = GenAgent.halt(name)

    assert %{phase: :processing, halted: false, halt_pending: true, pending_prompts: 1} =
             GenAgent.runtime_snapshot(name)

    send(task_pid, {:mock_release, :first})
    assert_receive {:gen_agent, :completion, ^name, ^first_ref, {:ok, %{text: "first"}}}
    assert_receive {:post_run, 1}
    assert %{halted: true, halt_pending: false, queued: 1} = GenAgent.status(name)
    assert {:ok, :pending} = GenAgent.poll(name, second_ref)
    assert Mock.history(name) == ["first"]

    assert :ok = GenAgent.resume(name)
    assert_receive {:gen_agent, :completion, ^name, ^second_ref, {:ok, %{text: "second"}}}
  end

  test "resume cancels a pending external halt", %{name: name} do
    {:ok, _pid} =
      start(name, [Mock.gate(:turn, [Event.new(:result, %{text: "done"})])], self())

    assert {:ok, ref} = GenAgent.tell_with_completion(name, "turn")
    assert_receive {:mock_blocked, :turn, task_pid}
    assert :ok = GenAgent.halt(name)
    assert GenAgent.runtime_snapshot(name).halt_pending
    assert :ok = GenAgent.resume(name)
    refute GenAgent.runtime_snapshot(name).halt_pending

    send(task_pid, {:mock_release, :turn})
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, %{text: "done"}}}
    refute GenAgent.status(name).halted
    refute_receive {:post_run, _}, 0
  end
end
