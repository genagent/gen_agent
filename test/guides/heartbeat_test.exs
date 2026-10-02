# Compile the copyable modules so the guide itself is the implementation under test.
# The older scenario test keeps its separate topology fixture; this file
# replaces it as the source of truth for the guide's state and ticker.
guide = Path.expand("../../guides/patterns/heartbeat.md", __DIR__)

[code] =
  for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
      String.starts_with?(code, "defmodule Heartbeat.Agent do"),
      do: code

Code.compile_string(code, guide)

defmodule GenAgent.HeartbeatGuideTest do
  use ExUnit.Case, async: false

  def tick_handler(_event, _measurements, metadata, observer),
    do: send(observer, {:tick_event, metadata})

  defmodule Backend do
    @behaviour GenAgent.Backend
    @impl true
    def start_session(_opts), do: {:ok, Process.whereis(GenAgent.HeartbeatGuideTest)}
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

  defp start_agent(opts) do
    name = Keyword.get(opts, :name, "heartbeat-#{System.unique_integer([:positive])}")

    assert {:ok, _} =
             GenAgent.start_agent(Heartbeat.Agent, [name: name, backend: Backend] ++ opts)

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

  test "failure restores the batch before newer observations and a later tick retries" do
    name = start_agent(min_batch: 1)
    :ok = GenAgent.notify_ack(name, {:observation, :old})
    :ok = GenAgent.notify_ack(name, :tick)
    assert_receive {:started, prompt, task}
    assert state(name).in_flight == [:old]
    :ok = GenAgent.notify_ack(name, {:observation, :new})
    send(task, :fail)
    await(fn -> length(state(name).failures) == 1 end)

    assert %{
             observations: [:old, :new],
             in_flight: nil,
             failures: [%{observations: [:old], reason: :controlled_failure}]
           } = state(name)

    :ok = GenAgent.notify_ack(name, :tick)
    assert_receive {:started, retry, task}
    assert retry =~ ":old"
    assert retry =~ ":new"
    assert prompt =~ ":old"
    send(task, :release)
    await(fn -> length(state(name).summaries) == 1 end)
    assert state(name).in_flight == nil
    assert state(name).observations == []
  end

  test "halted ticks queue only one batch and insufficient observations queue nothing" do
    name = start_agent(min_batch: 2)
    halt(name)
    :ok = GenAgent.notify_ack(name, {:observation, :one})
    :ok = GenAgent.notify_ack(name, :tick)
    assert GenAgent.runtime_snapshot(name).pending_prompts == 0
    :ok = GenAgent.notify_ack(name, {:observation, :two})
    :ok = GenAgent.notify_ack(name, :tick)
    for _ <- 1..3, do: assert(:ok == GenAgent.notify_ack(name, :tick))
    assert GenAgent.runtime_snapshot(name).pending_prompts == 1
    assert state(name).in_flight == [:one, :two]
    GenAgent.resume(name)
    assert_receive {:started, _, task}
    send(task, :release)
    await(fn -> length(state(name).summaries) == 1 end)
    :ok = GenAgent.notify_ack(name, {:observation, :three})
    :ok = GenAgent.notify_ack(name, :tick)
    assert state(name).observations == [:three]
    assert GenAgent.runtime_snapshot(name).pending_prompts == 0
    refute_receive {:started, _, _}
  end

  test "prompt overload restores the rejected batch without immediate retry" do
    name = start_agent(min_batch: 1, max_pending_prompts: 0)
    halt(name)
    :ok = GenAgent.notify_ack(name, {:observation, :keep})
    assert {:error, {:overloaded, %{queue: :prompts}}} = GenAgent.notify_ack(name, :tick)
    assert %{observations: [:keep], in_flight: nil, failures: [_]} = state(name)
    GenAgent.resume(name)
    :ok = GenAgent.notify_ack(name, :tick)
    assert_receive {:started, _, task}
    send(task, :release)
    await(fn -> length(state(name).summaries) == 1 end)
  end

  test "deferred notification admission is bounded and notify silently drops overflow" do
    name = start_agent(min_batch: 1, max_pending_notifications: 1)
    :ok = GenAgent.notify_ack(name, {:observation, :first})
    :ok = GenAgent.notify_ack(name, :tick)
    assert_receive {:started, _, task}
    :ok = GenAgent.notify_ack(name, {:observation, :accepted})
    assert {:error, {:overloaded, _}} = GenAgent.notify_ack(name, {:observation, :rejected})
    assert :ok = GenAgent.notify(name, {:observation, :dropped})
    assert GenAgent.runtime_snapshot(name).pending_notifications == 1
    send(task, :release)
    await(fn -> length(state(name).summaries) == 1 end)
    assert state(name).observations == [:accepted]
  end

  test "supervised ticker stops with its agent and stale pulses cannot activate a replacement" do
    name = start_agent(min_batch: 1)
    old_pid = GenAgent.whereis(name)
    :ok = GenAgent.notify_ack(name, {:observation, :first})
    ticker = start_supervised!({Heartbeat.Ticker, agent: name, interval_ms: 10})
    monitor = Process.monitor(ticker)
    assert_receive {:started, _, task}, 1_000
    send(task, :release)
    await(fn -> length(state(name).summaries) == 1 end)
    :ok = GenAgent.stop(name)
    assert_receive {:DOWN, ^monitor, :process, ^ticker, :normal}, 1_000
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    await(fn -> Supervisor.which_children(supervisor) == [] end)

    ^name = start_agent(name: name, min_batch: 1)
    new_pid = GenAgent.whereis(name)
    :ok = GenAgent.notify_ack(name, {:observation, :replacement})
    refute Process.alive?(ticker)
    # Model the lookup/send race: the old ticker's targeted pulse reaches
    # the new registration, but the new agent rejects that incarnation.
    :ok = GenAgent.notify_ack(name, {:tick, old_pid})
    assert state(name).observations == [:replacement]
    refute_receive {:started, _, _}, 50
    observer = self()
    handler = "ticker-#{name}"

    :ok =
      :telemetry.attach(
        handler,
        [:gen_agent, :event, :received],
        &__MODULE__.tick_handler/4,
        observer
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    replacement = start_supervised!({Heartbeat.Ticker, agent: name, interval_ms: 60_000})
    send(replacement, :tick)
    assert_receive {:tick_event, %{agent: ^name, event: {:tick, ^new_pid}}}
    refute_receive {:tick_event, %{agent: ^name, event: {:tick, ^new_pid}}}, 50
    assert replacement != ticker
    assert_receive {:started, _, task}, 1_000
    send(task, :release)
    await(fn -> length(state(name).summaries) == 1 end)
    refute_receive {:started, _, _}, 50
    monitor = Process.monitor(replacement)
    :ok = GenAgent.stop(name)
    assert_receive {:DOWN, ^monitor, :process, ^replacement, :normal}, 1_000
  end
end
