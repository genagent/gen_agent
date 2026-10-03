defmodule GenAgent.ClientTargetTest do
  use ExUnit.Case, async: true

  test "synchronous calls return not_found for a missing registered name" do
    name = {:missing_agent, make_ref()}
    ref = make_ref()

    assert {:error, :not_found} = GenAgent.ask(name, "hello")
    assert {:error, :not_found} = GenAgent.tell(name, "hello")
    assert {:error, :not_found} = GenAgent.tell_with_completion(name, "hello")

    assert {:error, :not_found} =
             GenAgent.tell_with_completion(name, "hello", self(), 1_000, on_halt: :fail)

    assert {:error, :not_found} = GenAgent.poll(name, ref)
    assert {:error, :not_found} = GenAgent.notify_ack(name, :event)
    assert {:error, :not_found} = GenAgent.interrupt_request(name, ref)
    assert {:error, :not_found} = GenAgent.cancel_request(name, ref)
    assert {:error, :not_found} = GenAgent.status(name)
    assert {:error, :not_found} = GenAgent.runtime_snapshot(name)

    assert :ok = GenAgent.notify(name, :event)
    assert :ok = GenAgent.interrupt(name)
    assert :ok = GenAgent.resume(name)
    assert {:error, :not_found} = GenAgent.stop(name)
  end

  test "the pid returned at startup is not the registered client address" do
    name = {:named_agent, make_ref()}

    {:ok, pid} =
      GenAgent.start_agent(GenAgent.Support.TestAgent,
        name: name,
        backend: GenAgent.Backends.Mock
      )

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    assert GenAgent.whereis(name) == pid
    assert %{name: ^name} = GenAgent.status(name)
    assert {:error, :not_found} = GenAgent.status(pid)
    assert {:error, :not_found} = GenAgent.ask(pid, "hello")
    assert {:error, :not_found} = GenAgent.stop(pid)
    assert Process.alive?(pid)

    assert :ok = GenAgent.stop(name)
    assert {:error, :not_found} = GenAgent.status(name)
  end
end
