defmodule GenAgent.PendingInputsTest do
  use ExUnit.Case, async: false

  alias GenAgent.Event

  defmodule Backend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts), do: {:ok, opts}

    @impl true
    def prompt(session, prompt) do
      send(session[:observer], {:started, prompt, self()})

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
    def handle_response(_ref, %{text: "chain"}, state),
      do: {:prompt, String.duplicate("x", 200), state}

    def handle_response(_ref, _response, state), do: {:noreply, state}

    @impl true
    def handle_error(_ref, reason, state) do
      send(state.observer, {:callback_error, reason})
      {:noreply, state}
    end

    @impl true
    def handle_event(:halt, state), do: {:halt, state}
    def handle_event({:prompt, prompt}, state), do: {:prompt, prompt, state}

    def handle_event(event, state) do
      send(state.observer, {:handled, event})
      {:noreply, state}
    end
  end

  defp start_agent(opts) do
    name = "input-bounds-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      GenAgent.start_agent(
        Agent,
        [name: name, backend: Backend, observer: self(), watchdog_ms: 10_000] ++ opts
      )

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    name
  end

  defp start_held(name, prompt \\ "held") do
    assert {:ok, ref} = GenAgent.tell(name, prompt)
    assert_receive {:started, ^prompt, task}, 1_000
    {ref, task}
  end

  defp overloaded(result, queue, limit) do
    assert {:error, {:overloaded, info}} = result
    assert info.queue == queue
    assert info.limit == limit
    assert info.pending_count >= 0
    assert info.pending_bytes >= 0
    assert info.incoming_bytes > 0
    info
  end

  test "prompt count rejects ask and tell before issuing an accepted ref" do
    name = start_agent(max_pending_prompts: 1)
    {_first, task} = start_held(name)
    assert {:ok, second} = GenAgent.tell(name, "second")
    overloaded(GenAgent.tell(name, "third"), :prompts, :count)
    overloaded(GenAgent.ask(name, "third"), :prompts, :count)
    assert GenAgent.runtime_snapshot(name).pending_prompts == 1
    assert {:ok, :pending} = GenAgent.poll(name, second)

    send(task, :release)
    assert_receive {:started, "second", second_task}, 1_000
    assert {:ok, third} = GenAgent.tell(name, "third")
    assert {:ok, :pending} = GenAgent.poll(name, third)
    send(second_task, :release)
    assert_receive {:started, "third", third_task}, 1_000
    send(third_task, :release)
    assert_eventually(fn -> match?({:ok, :completed, _}, GenAgent.poll(name, third)) end)
  end

  test "byte caps and zero caps reject pending prompts and notifications" do
    small = "small"

    name =
      start_agent(max_pending_prompts: 2, max_pending_prompt_bytes: :erlang.external_size(small))

    {_first, _task} = start_held(name)
    assert {:ok, _ref} = GenAgent.tell(name, small)
    overloaded(GenAgent.tell(name, "x"), :prompts, :bytes)

    zero = start_agent(max_pending_prompts: 0, max_pending_notifications: 0)
    {_first, _task} = start_held(zero)
    overloaded(GenAgent.tell(zero, "queued"), :prompts, :count)
    overloaded(GenAgent.notify_ack(zero, :event), :notifications, :count)
  end

  test "acknowledged notifications enforce count and byte caps; legacy cast reports rejection" do
    event = {:update, 1}

    name =
      start_agent(
        max_pending_notifications: 1,
        max_pending_notification_bytes: :erlang.external_size(event)
      )

    {_first, task} = start_held(name)
    assert :ok = GenAgent.notify_ack(name, event)
    overloaded(GenAgent.notify_ack(name, {:update, 2}), :notifications, :count)
    assert GenAgent.runtime_snapshot(name).pending_notifications == 1

    handler = "input-rejected-#{System.unique_integer([:positive])}"
    observer = self()

    :ok =
      :telemetry.attach(
        handler,
        [:gen_agent, :input, :rejected],
        fn _event, _measurements, metadata, _config ->
          send(observer, {:rejected, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = GenAgent.notify(name, :cast_overload)

    assert_receive {:rejected, %{agent: ^name, reason: {:overloaded, %{queue: :notifications}}}},
                   1_000

    send(task, :release)
    assert_receive {:handled, ^event}, 1_000
    refute_receive {:handled, :cast_overload}, 50

    byte_name =
      start_agent(
        max_pending_notifications: 2,
        max_pending_notification_bytes: :erlang.external_size(event)
      )

    {_ref, _task} = start_held(byte_name)
    overloaded(GenAgent.notify_ack(byte_name, String.duplicate("x", 200)), :notifications, :bytes)
    assert :ok = GenAgent.notify_ack(byte_name, event)
  end

  test "concurrent submissions admit no more than configured capacity" do
    name = start_agent(max_pending_prompts: 3)
    {_first, _task} = start_held(name)

    outcomes =
      1..20
      |> Task.async_stream(fn n -> GenAgent.tell(name, "queued-#{n}") end,
        max_concurrency: 20,
        timeout: 2_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 3
    assert Enum.count(outcomes, &match?({:error, {:overloaded, _}}, &1)) == 17
    assert GenAgent.runtime_snapshot(name).pending_prompts == 3
  end

  test "halt and resume preserve accepted work and replenish capacity" do
    name = start_agent(max_pending_prompts: 1)
    assert :ok = GenAgent.notify_ack(name, :halt)
    assert {:ok, ref} = GenAgent.tell(name, "queued")
    overloaded(GenAgent.tell(name, "rejected"), :prompts, :count)
    assert {:ok, :pending} = GenAgent.poll(name, ref)
    assert :ok = GenAgent.resume(name)
    assert_receive {:started, "queued", task}, 1_000
    assert {:ok, next_ref} = GenAgent.tell(name, "next")
    send(task, :release)
    assert_receive {:started, "next", next_task}, 1_000
    send(next_task, :release)
    assert_eventually(fn -> match?({:ok, :completed, _}, GenAgent.poll(name, next_ref)) end)
  end

  test "deferred callback prompts observe queue bounds and report overload" do
    name = start_agent(max_pending_prompts: 1)
    {_first, task} = start_held(name)
    assert {:ok, queued_ref} = GenAgent.tell(name, "queued")
    assert :ok = GenAgent.notify_ack(name, {:prompt, "generated"})
    send(task, :release)
    assert_receive {:callback_error, {:overloaded, %{queue: :prompts}}}, 1_000
    assert_receive {:started, "queued", queued_task}, 1_000
    refute_receive {:started, "generated", _}, 50
    assert {:ok, :pending} = GenAgent.poll(name, queued_ref)
    send(queued_task, :release)
  end

  test "self-chain uses a reserved slot but obeys the prompt byte cap" do
    name = start_agent(max_pending_prompts: 0, max_pending_prompt_bytes: 100)
    {_ref, task} = start_held(name, "chain")
    send(task, :release)
    assert_receive {:callback_error, {:overloaded, %{queue: :self_chain, limit: :bytes}}}, 1_000
    refute_receive {:started, _, _}, 50

    allowed = start_agent(max_pending_prompts: 0, max_pending_prompt_bytes: 300)
    {_ref, task} = start_held(allowed, "chain")
    send(task, :release)
    assert_receive {:started, generated, generated_task}, 1_000
    assert generated == String.duplicate("x", 200)
    send(generated_task, :release)
  end

  test "interruption replenishes pending notification capacity" do
    name = start_agent(max_pending_notifications: 1)
    {ref, task} = start_held(name)
    assert :ok = GenAgent.notify_ack(name, :one)
    overloaded(GenAgent.notify_ack(name, :two), :notifications, :count)
    assert {:ok, :accepted} = GenAgent.interrupt_request(name, ref)
    assert_receive {:handled, :one}, 1_000
    assert :ok = GenAgent.notify_ack(name, :two)
    assert_receive {:handled, :two}, 1_000
    refute Process.alive?(task)
  end

  test "invalid negative or noninteger limits fail startup" do
    for key <- [
          :max_pending_prompts,
          :max_pending_prompt_bytes,
          :max_pending_notifications,
          :max_pending_notification_bytes
        ],
        value <- [-1, :infinity] do
      name = "invalid-input-bound-#{System.unique_integer([:positive])}"

      assert {:error, _reason} =
               GenAgent.start_agent(
                 Agent,
                 [name: name, backend: Backend, observer: self()] ++ [{key, value}]
               )
    end
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
