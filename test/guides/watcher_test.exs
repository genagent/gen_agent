# Compile the copyable modules so the guide itself is the implementation under test.
# The older scenario test keeps its separate topology fixture; this file
# replaces it as the source of truth for the guide's state and error handling.
guide = Path.expand("../../guides/patterns/watcher.md", __DIR__)

[code] =
  for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
      String.starts_with?(code, "defmodule Watcher.Agent do"),
      do: code

Code.compile_string(code, guide)

defmodule GenAgent.WatcherGuideTest do
  use ExUnit.Case, async: false

  defmodule Backend do
    @behaviour GenAgent.Backend
    @impl true
    def start_session(_opts), do: {:ok, Process.whereis(GenAgent.WatcherGuideTest)}
    @impl true
    def prompt(observer, prompt) do
      send(observer, {:started, prompt, self()})

      receive do
        :release -> {:ok, [GenAgent.Event.new(:result, %{text: prompt})], observer}
        :fail -> {:error, :controlled_failure}
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

  defp start_agent(opts \\ []) do
    name = Keyword.get(opts, :name, "watcher-#{System.unique_integer([:positive])}")
    assert {:ok, _} = GenAgent.start_agent(Watcher.Agent, [name: name, backend: Backend] ++ opts)
    on_exit(fn -> if GenAgent.whereis(name), do: GenAgent.stop(name) end)
    name
  end

  defp state(name), do: GenAgent.status(name).agent_state

  defp await(check, attempts \\ 1_000)
  defp await(check, 0), do: assert(check.())

  defp await(check, attempts) do
    if check.() do
      :ok
    else
      Process.sleep(1)
      await(check, attempts - 1)
    end
  end

  defp halt(name) do
    # Test-only hook: this depends on the internal GenAgent.Server.Data shape.
    # The copyable guide intentionally has no event that halts the agent.
    :sys.replace_state(GenAgent.whereis(name), fn {:idle, data} ->
      {:idle, %{data | halted: true}}
    end)
  end

  test "failed diagnosis and welcome retain their originating events, success records an action" do
    name = start_agent()
    events = [{:ci_result, :failed, "broken build"}, {:pr_opened, "alice", "fix"}]

    for {event, count} <- Enum.with_index(events, 1) do
      :ok = GenAgent.notify_ack(name, event)
      assert_receive {:started, _, task}
      send(task, :fail)
      await(fn -> length(state(name).failures) == count end)
    end

    assert Enum.map(state(name).failures, & &1.event) == events
    assert Enum.all?(state(name).failures, &(&1.reason == :controlled_failure))
    assert state(name).actions == []
    event = {:pr_opened, "bob", "success"}
    :ok = GenAgent.notify_ack(name, event)
    assert_receive {:started, _, task}
    send(task, :release)
    await(fn -> length(state(name).actions) == 1 end)
    assert [%{event: ^event}] = state(name).actions
    assert state(name).pending == []
    assert state(name).active == nil
  end

  test "halted prompt overload records the newest event without consuming an older one" do
    name = start_agent(max_pending_prompts: 1)
    halt(name)
    first = {:pr_opened, "alice", "queued"}
    rejected = {:ci_result, :failed, "rejected"}
    :ok = GenAgent.notify_ack(name, first)
    assert {:error, {:overloaded, _}} = GenAgent.notify_ack(name, rejected)
    assert [%{event: ^rejected, reason: {:overloaded, _}}] = state(name).failures
    assert [{^first, _prompt}] = state(name).pending
    GenAgent.resume(name)
    assert_receive {:started, _, task}
    send(task, :release)
    await(fn -> length(state(name).actions) == 1 end)
    assert [%{event: ^first}] = state(name).actions
  end

  test "a direct prompt queued before an event cannot claim that event" do
    name = start_agent()
    halt(name)
    {:ok, _ref} = GenAgent.tell(name, "unrelated direct prompt")
    event = {:pr_opened, "alice", "event prompt"}
    :ok = GenAgent.notify_ack(name, event)

    GenAgent.resume(name)
    assert_receive {:started, prompt, task}, 1_000
    assert prompt =~ "event prompt"
    send(task, :release)
    await(fn -> length(state(name).actions) == 1 end)
    assert [%{event: ^event}] = state(name).actions
    assert state(name).pending == []
  end

  test "admitted deferred events can later fail prompt admission and retain correct identities" do
    name = start_agent(max_pending_prompts: 1)
    active = {:pr_opened, "alice", "active"}
    queued = {:pr_opened, "bob", "queued"}
    rejected = {:ci_result, :failed, "overflow"}
    :ok = GenAgent.notify_ack(name, active)
    assert_receive {:started, _, task}
    :ok = GenAgent.notify_ack(name, queued)
    :ok = GenAgent.notify_ack(name, rejected)
    send(task, :release)
    assert_receive {:started, _, next_task}
    assert [%{event: ^rejected, reason: {:overloaded, _}}] = state(name).failures
    send(next_task, :fail)
    await(fn -> length(state(name).failures) == 2 end)
    assert Enum.map(state(name).failures, & &1.event) == [rejected, queued]
    assert [%{event: ^active}] = state(name).actions
    assert state(name).pending == []
  end

  test "notification byte limits reject input before the event enters agent state" do
    event = {:ci_result, :failed, "too large"}
    name = start_agent(max_pending_notification_bytes: :erlang.external_size(event) - 1)
    :ok = GenAgent.notify_ack(name, {:pr_opened, "alice", "active"})
    assert_receive {:started, _, task}
    assert {:error, {:overloaded, %{limit: :bytes}}} = GenAgent.notify_ack(name, event)
    assert GenAgent.runtime_snapshot(name).pending_notifications == 0
    send(task, :release)
    await(fn -> length(state(name).actions) == 1 end)
    assert state(name).pending == []
    assert state(name).failures == []
  end
end
