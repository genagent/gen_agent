# Compile the copyable modules directly from the guide, avoiding a second implementation.
guide = Path.expand("../../guides/patterns/retry.md", __DIR__)

for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
    String.starts_with?(code, ["defmodule Retry.Agent do", "defmodule Retry.FlakyBackend do"]) do
  Code.compile_string(code, guide)
end

defmodule GenAgent.RetryGuideTest do
  use ExUnit.Case, async: false

  alias Retry.Agent

  # Blocks every prompt until the test process kills the task.
  defmodule HangBackend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts), do: {:ok, Keyword.fetch!(opts, :observer)}

    @impl true
    def prompt(observer, prompt) do
      send(observer, {:prompt, prompt})
      Process.sleep(:infinity)
    end

    @impl true
    def terminate_session(observer) do
      send(observer, :session_terminated)
      :ok
    end
  end

  defp start(opts) do
    name = "retry-guide-#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [name: name, agent_name: name, task: "write a haiku", backend: Retry.FlakyBackend],
        opts
      )

    assert {:ok, _pid} = GenAgent.start_agent(Agent, opts)

    on_exit(fn -> if GenAgent.whereis(name), do: GenAgent.stop(name) end)
    name
  end

  defp agent_state(name), do: GenAgent.status(name).agent_state

  defp await_phase(name, phase, tries \\ 200) do
    cond do
      agent_state(name).phase == phase ->
        agent_state(name)

      tries == 0 ->
        flunk("expected phase #{inspect(phase)}, got #{inspect(agent_state(name).phase)}")

      true ->
        Process.sleep(10)
        await_phase(name, phase, tries - 1)
    end
  end

  defp state(attrs), do: struct!(Agent.State, [agent_name: "none", max_attempts: 5] ++ attrs)

  describe "callbacks" do
    test "retryable errors schedule a timer instead of sleeping" do
      st = state(base_backoff_ms: 60_000, task: "t")

      {time, result} =
        :timer.tc(fn -> Agent.handle_error(make_ref(), {:http_error, 429, %{}}, st) end)

      assert {:noreply, %Agent.State{phase: :waiting, attempts: 1} = waiting} = result
      assert time < 100_000
      assert is_reference(waiting.token)
      :timer.cancel(waiting.timer)
    end

    test "backoff doubles per attempt" do
      name =
        start(
          max_attempts: 6,
          base_backoff_ms: 200,
          backend_opts: [fail_first: 3, observer: self()]
        )

      {:ok, _} = GenAgent.tell(name, "write a haiku")

      stamps =
        for n <- 1..4 do
          assert_receive {:prompt, ^n, _, stamp}, 4_000
          stamp
        end

      gaps = stamps |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

      # The backend stamps dispatch time, so mailbox delivery lag cannot make
      # a constant delay look exponential. Expected gaps are 200, 400, 800 ms.
      assert [first, second, third] = gaps
      assert first >= 180
      assert second - first >= 100
      assert third - second >= 200
    end

    test "interrupted and timeout halt without scheduling a retry" do
      st = state(base_backoff_ms: 60_000)

      assert {:halt, %Agent.State{phase: :interrupted, timer: nil, errors: [:interrupted]}} =
               Agent.handle_error(make_ref(), :interrupted, st)

      assert {:halt, %Agent.State{phase: :timed_out, timer: nil, errors: [:timeout]}} =
               Agent.handle_error(make_ref(), :timeout, st)
    end

    test "attempt cap halts as failed" do
      st = state(attempts: 4, max_attempts: 5)

      assert {:halt, %Agent.State{phase: :failed, attempts: 5}} =
               Agent.handle_error(make_ref(), :boom, st)
    end

    test "only the pending token triggers a retry prompt" do
      {:noreply, waiting} =
        Agent.handle_error(make_ref(), :boom, state(base_backoff_ms: 60_000, task: "t"))

      assert {:noreply, ^waiting} = Agent.handle_event({:retry, make_ref()}, waiting)

      assert {:prompt, prompt, %{phase: :running, timer: nil}} =
               Agent.handle_event({:retry, waiting.token}, waiting)

      assert prompt =~ "Retry the task: t"

      assert {:halt, %{phase: :cancelled, timer: nil, token: nil}} =
               Agent.handle_event(:cancel_retry, waiting)
    end
  end

  describe "runtime" do
    test "retries through failures and succeeds" do
      name =
        start(
          max_attempts: 5,
          base_backoff_ms: 10,
          backend_opts: [fail_first: 2, observer: self()]
        )

      {:ok, _} = GenAgent.tell(name, "write a haiku")

      state = await_phase(name, :succeeded)
      assert state.attempts == 3
      assert length(state.errors) == 2
      assert state.result == "Persistence."
      assert_received {:prompt, 1, "write a haiku", _}

      assert_received {:prompt, 2, "The previous attempt failed. Retry the task: write a haiku",
                       _}

      assert_received {:prompt, 3, _, _}
    end

    test "gives up at the cap" do
      name =
        start(
          max_attempts: 2,
          base_backoff_ms: 10,
          backend_opts: [fail_first: 10, observer: self()]
        )

      {:ok, _} = GenAgent.tell(name, "write a haiku")
      assert %{attempts: 2} = await_phase(name, :failed)
    end

    test "agent stays responsive during backoff and cancel prevents the retry" do
      name =
        start(
          max_attempts: 5,
          base_backoff_ms: 300,
          backend_opts: [fail_first: 1, observer: self()]
        )

      {:ok, _} = GenAgent.tell(name, "write a haiku")
      assert_receive {:prompt, 1, _, _}, 1_000
      await_phase(name, :waiting)

      {time, %{agent_state: %{phase: :waiting}}} = :timer.tc(fn -> GenAgent.status(name) end)
      assert time < 200_000

      :ok = GenAgent.notify(name, :cancel_retry)
      await_phase(name, :cancelled)
      refute_receive {:prompt, 2, _, _}, 600
      assert agent_state(name).attempts == 1
    end

    test "interrupt during backoff is ignored and the retry still runs" do
      name =
        start(
          max_attempts: 5,
          base_backoff_ms: 200,
          backend_opts: [fail_first: 1, observer: self()]
        )

      {:ok, _} = GenAgent.tell(name, "write a haiku")
      await_phase(name, :waiting)

      :ok = GenAgent.interrupt(name)

      assert agent_state(name).phase in [:waiting, :running, :succeeded]
      assert_receive {:prompt, 2, _, _}, 1_000
      assert %{result: "Persistence."} = await_phase(name, :succeeded)
    end

    test "a stale timer token delivered after cancel starts no prompt" do
      name =
        start(
          max_attempts: 5,
          base_backoff_ms: 60_000,
          backend_opts: [fail_first: 10, observer: self()]
        )

      {:ok, _} = GenAgent.tell(name, "write a haiku")
      %{token: token} = await_phase(name, :waiting)
      assert is_reference(token)
      assert_receive {:prompt, 1, _, _}, 1_000

      :ok = GenAgent.notify(name, :cancel_retry)
      await_phase(name, :cancelled)

      # The original timer notification arrives after cancellation.
      :ok = GenAgent.notify(name, {:retry, token})

      refute_receive {:prompt, 2, _, _}, 300
      assert %{phase: :cancelled, attempts: 1} = agent_state(name)
    end

    test "stop during a long backoff completes promptly and runs termination" do
      name =
        start(
          max_attempts: 5,
          base_backoff_ms: 60_000,
          backend_opts: [fail_first: 10, observer: self()]
        )

      {:ok, _} = GenAgent.tell(name, "write a haiku")
      await_phase(name, :waiting)
      pid = GenAgent.whereis(name)
      ref = Process.monitor(pid)

      {time, :ok} = :timer.tc(fn -> GenAgent.stop(name) end)

      assert time < 2_000_000
      assert_receive :session_terminated, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
      assert reason in [:normal, :shutdown]
    end

    test "interrupt does not retry" do
      name =
        start(
          backend: HangBackend,
          max_attempts: 5,
          base_backoff_ms: 10,
          backend_opts: [observer: self()]
        )

      {:ok, _} = GenAgent.tell(name, "write a haiku")
      assert_receive {:prompt, "write a haiku"}, 1_000

      :ok = GenAgent.interrupt(name)

      assert %{errors: [:interrupted]} = await_phase(name, :interrupted)
      refute_receive {:prompt, _}, 300
    end

    test "watchdog timeout does not retry" do
      name =
        start(
          backend: HangBackend,
          max_attempts: 5,
          base_backoff_ms: 10,
          watchdog_ms: 100,
          backend_opts: [observer: self()]
        )

      {:ok, _} = GenAgent.tell(name, "write a haiku")
      assert_receive {:prompt, "write a haiku"}, 1_000

      assert %{errors: [:timeout]} = await_phase(name, :timed_out)
      refute_receive {:prompt, _}, 300
    end
  end
end
