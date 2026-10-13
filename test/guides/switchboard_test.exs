# Compile the copyable modules directly from the guide, avoiding a second implementation.
guide = Path.expand("../../guides/patterns/switchboard.md", __DIR__)

modules =
  for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
      String.starts_with?(code, [
        "defmodule Switchboard.SessionAgent do",
        "defmodule Switchboard do"
      ]),
      do: code

2 = length(modules)
Enum.each(modules, &Code.compile_string(&1, guide))

defmodule GenAgent.SwitchboardGuideTest do
  use ExUnit.Case, async: false

  alias Switchboard.SessionAgent

  defmodule Backend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts) do
      observer = Process.whereis(GenAgent.SwitchboardGuideTest)
      send(observer, {:backend_opts, opts})
      {:ok, observer}
    end

    @impl true
    def prompt(observer, prompt) do
      send(observer, {:started, prompt, self()})

      receive do
        :release -> {:ok, [GenAgent.Event.new(:result, %{text: prompt})], observer}
      after
        5_000 -> {:error, :fixture_deadline}
      end
    end

    @impl true
    def terminate_session(_session), do: :ok
  end

  setup do
    Process.register(self(), __MODULE__)
    :ok
  end

  defp start_session(opts \\ []) do
    name = "switchboard-#{System.unique_integer([:positive])}"

    assert {:ok, ^name} =
             Switchboard.start_session(name, [path: "/tmp", backend: Backend] ++ opts)

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    name
  end

  defp complete(name, ref, task) do
    send(task, :release)
    await_result(name, ref, System.monotonic_time(:millisecond) + 2_000)
  end

  defp await_result(name, ref, deadline) do
    case Switchboard.poll(name, ref) do
      {:ok, :pending} ->
        assert System.monotonic_time(:millisecond) < deadline, "turn did not complete"

        receive do
        after
          1 -> await_result(name, ref, deadline)
        end

      result ->
        assert {:ok, :completed, _} = result
    end
  end

  test "missing names return errors for calls, while casts truthfully return ok" do
    name = "missing-#{System.unique_integer([:positive])}"
    assert {:error, :not_found} = Switchboard.submit(name, "hello")
    assert {:error, :not_found} = Switchboard.poll(name, make_ref())
    assert {:error, :not_found} = Switchboard.inbox(name)
    assert {:error, :not_found} = Switchboard.inbox(name, ack: true)
    assert {:error, :not_found} = Switchboard.summary_get(name)
    assert {:error, :not_found} = Switchboard.summary_update(name, "summary")
    assert {:error, :not_found} = Switchboard.transcript(name)
    assert {:error, :not_found} = Switchboard.halt(name)
    assert {:error, :not_found} = Switchboard.stop_session(name)
    assert :ok = Switchboard.interrupt(name)
    assert :ok = Switchboard.resume(name)
    refute function_exported?(Switchboard, :send, 2)
  end

  test "snapshot acknowledgment leaves an in-flight result unread" do
    name = start_session()
    assert_receive {:backend_opts, opts}
    assert opts[:cwd] == "/tmp"
    refute Keyword.has_key?(opts, :name)
    refute Keyword.has_key?(opts, :backend)
    assert :ok = Switchboard.summary_update(name, "## Status\nworking")
    assert {:ok, "## Status\nworking"} = Switchboard.summary_get(name)

    assert {:ok, first} = Switchboard.submit(name, "first")
    assert_receive {:started, "first", task}, 1_000
    complete(name, first, task)
    assert {:ok, second} = Switchboard.submit(name, "second")
    assert_receive {:started, "second", task}, 1_000

    assert {:ok, %{new_requests: [%{ref: ^first}], summary: "## Status\nworking"}} =
             Switchboard.inbox(name, ack: true)

    # Admission is synchronous, application is deferred until after handle_response.
    assert GenAgent.runtime_snapshot(name).pending_notifications == 1
    assert GenAgent.status(name).agent_state.inbox_cursor == 0
    complete(name, second, task)
    assert {:ok, %{new_requests: [%{ref: ^second}]}} = Switchboard.inbox(name)
    assert {:ok, [%{ref: ^first}, %{ref: ^second}]} = Switchboard.transcript(name)
    assert {:ok, [%{ref: ^second}]} = Switchboard.transcript(name, limit: 1)
    assert {:ok, %{new_requests: [%{ref: ^second}]}} = Switchboard.inbox(name, ack: true)
    assert {:ok, %{new_requests: []}} = Switchboard.inbox(name)

    # A delayed acknowledgment from an older reader cannot move the cursor backward.
    assert :ok = GenAgent.notify_ack(name, {:ack_inbox, 1})
    assert {:ok, %{new_requests: []}} = Switchboard.inbox(name)
  end

  test "busy submissions queue in order and broadcast retains overload and missing outcomes" do
    name = start_session(max_pending_prompts: 1)
    assert {:ok, first} = Switchboard.submit(name, "first")
    assert_receive {:started, "first", task}, 1_000
    assert [{^name, {:ok, second}}] = Switchboard.broadcast([name], "second")

    assert [
             {^name, {:error, {:overloaded, %{limit: :count}}}},
             {"missing-broadcast", {:error, :not_found}}
           ] = Switchboard.broadcast([name, "missing-broadcast"], "rejected")

    assert {:ok, :pending} = Switchboard.poll(name, second)
    complete(name, first, task)
    assert_receive {:started, "second", task}, 1_000
    complete(name, second, task)
    assert {:ok, [%{ref: ^first}, %{ref: ^second}]} = Switchboard.transcript(name)
  end

  test "halt admission is deferred during a turn and queued prompts wait for resume" do
    name = start_session()
    assert {:ok, first} = Switchboard.submit(name, "first")
    assert_receive {:started, "first", task}, 1_000
    assert :ok = Switchboard.halt(name)
    assert GenAgent.runtime_snapshot(name).pending_notifications == 1
    assert {:ok, second} = Switchboard.submit(name, "second")
    complete(name, first, task)
    assert %{halted: true, pending_prompts: 1} = GenAgent.runtime_snapshot(name)
    assert {:ok, third} = Switchboard.submit(name, "third")
    assert {:ok, :pending} = Switchboard.poll(name, second)
    assert {:ok, :pending} = Switchboard.poll(name, third)
    assert :ok = Switchboard.resume(name)
    assert_receive {:started, "second", task}, 1_000
    complete(name, second, task)
    assert_receive {:started, "third", task}, 1_000
    complete(name, third, task)
  end

  test "notification overload is surfaced and rejected acknowledgment keeps items unread" do
    name = start_session(max_pending_notifications: 0)
    assert {:ok, first} = Switchboard.submit(name, "first")
    assert_receive {:started, "first", task}, 1_000
    complete(name, first, task)
    assert {:ok, second} = Switchboard.submit(name, "second")
    assert_receive {:started, "second", task}, 1_000

    assert {:error, {:overloaded, %{queue: :notifications}}} = Switchboard.inbox(name, ack: true)
    assert {:error, {:overloaded, _}} = Switchboard.summary_update(name, "rejected")
    assert {:error, {:overloaded, _}} = Switchboard.halt(name)
    complete(name, second, task)
    assert {:ok, %{new_requests: [%{ref: ^first}, %{ref: ^second}]}} = Switchboard.inbox(name)
    assert {:ok, ""} = Switchboard.summary_get(name)
  end

  test "submit calls tell without copying status or doing a separate busy check" do
    name = start_session()
    :erlang.trace_pattern({GenAgent, :_, :_}, true, [:local])
    on_exit(fn -> :erlang.trace_pattern({GenAgent, :_, :_}, false, [:local]) end)

    submitter =
      Task.async(fn ->
        receive do
          :go -> Switchboard.submit(name, "traced")
        end
      end)

    :erlang.trace(submitter.pid, true, [:call, {:tracer, self()}])
    send(submitter.pid, :go)
    assert {:ok, ref} = Task.await(submitter)
    delivered = :erlang.trace_delivered(submitter.pid)
    assert_receive {:trace_delivered, _, ^delivered}
    assert_receive {:trace, _, :call, {GenAgent, :tell, [^name, "traced"]}}
    refute_received {:trace, _, :call, {GenAgent, :status, _}}
    refute_received {:trace, _, :call, {GenAgent, :runtime_snapshot, _}}
    assert_receive {:started, "traced", task}, 1_000
    complete(name, ref, task)
  end

  test "guide API list, options, broadcast advice, and newline stay accurate" do
    guide = File.read!(Path.expand("../../guides/patterns/switchboard.md", __DIR__))
    [_, api] = Regex.run(~r/## What the callback recipe exercises\n(.*?)\n## /s, guide)
    refute api =~ "`halt/1`"
    assert api =~ "`notify_ack/2`"
    refute guide =~ "Keyword.drop"
    refute guide =~ "enumerates the registry"
    refute guide =~ "Switchboard.send"
    refute guide =~ ~S(\\n)
    assert guide =~ ~S("## Status\nworking on auth.")

    assert {:ok, [cwd: "/tmp", custom: :kept], %SessionAgent.State{path: "/tmp"}} =
             SessionAgent.init_agent(cwd: "/tmp", custom: :kept)
  end
end
