defmodule GenAgentEnsemble.AskTimeoutTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.Solo

  defp start do
    name = "ask-timeout-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      E.start_link(
        name: name,
        strategy: Solo,
        opts: [
          agent: {"a", ControlledAgent, backend: ControlledBackend, observer: self(), tag: "a"}
        ]
      )

    on_exit(fn ->
      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    {name, pid}
  end

  defp put_ask_timeout(value) do
    previous = Application.fetch_env(:gen_agent_ensemble, :ask_timeout)
    Application.put_env(:gen_agent_ensemble, :ask_timeout, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:gen_agent_ensemble, :ask_timeout, old)
        :error -> Application.delete_env(:gen_agent_ensemble, :ask_timeout)
      end
    end)
  end

  defp await_prompt(prompt) do
    assert_receive {:controlled_prompt, "a", ^prompt, worker}
    worker
  end

  defp ask_in_task(name, prompt, opts) do
    Task.async(fn -> E.ask(name, prompt, opts) end)
  end

  test "per-call timeout expiry exits the caller but the work continues" do
    {name, pid} = start()

    assert {:timeout, {GenServer, :call, _}} =
             catch_exit(E.ask(name, "slow", timeout: 0))

    # The gated backend is still running the request after the caller exited.
    worker = await_prompt("slow")
    assert Process.alive?(pid)
    assert Process.alive?(worker)

    send(worker, {:result, "done"})

    # The ensemble stays usable and processes subsequent work.
    task = ask_in_task(name, "next", timeout: :infinity)
    next_worker = await_prompt("next")
    send(next_worker, {:result, "ok"})
    assert {:ok, %{text: "ok"}} = Task.await(task)
  end

  test "an uncaught expiry that kills the start_link owner stops the ensemble and its work" do
    test_pid = self()
    name = "ask-timeout-owner-#{System.unique_integer([:positive])}"

    owner =
      spawn(fn ->
        {:ok, ensemble} =
          E.start_link(
            name: name,
            strategy: Solo,
            opts: [
              agent:
                {"a", ControlledAgent, backend: ControlledBackend, observer: test_pid, tag: "a"}
            ]
          )

        send(test_pid, {:started, ensemble})

        receive do
          :go -> E.ask(name, "expires", timeout: 0)
        end
      end)

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)

      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    owner_ref = Process.monitor(owner)
    assert_receive {:started, ensemble}
    ensemble_ref = Process.monitor(ensemble)

    # Gate in-flight work from a non-owner caller before the owner's ask expires.
    assert {:ok, _token} = E.tell(name, "in-flight")
    worker = await_prompt("in-flight")
    worker_ref = Process.monitor(worker)

    send(owner, :go)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, {:timeout, {GenServer, :call, _}}},
                   5_000

    assert_receive {:DOWN, ^ensemble_ref, :process, ^ensemble, _reason}, 5_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 5_000
  end

  test "application default applies when no per-call timeout is given" do
    put_ask_timeout(0)
    {name, pid} = start()

    task = Task.async(fn -> catch_exit(E.ask(name, "slow")) end)
    assert {:timeout, {GenServer, :call, _}} = Task.await(task, 1_000)

    worker = await_prompt("slow")
    assert Process.alive?(pid)
    send(worker, {:result, "done"})
  end

  test "per-call timeout takes precedence over the application default" do
    put_ask_timeout(0)
    {name, _pid} = start()

    task = ask_in_task(name, "q", timeout: :infinity)
    worker = await_prompt("q")
    send(worker, {:result, "answer"})

    assert {:ok, %{text: "answer"}} = Task.await(task)
  end

  test "a finite per-call timeout overrides a zero application default" do
    put_ask_timeout(0)
    {name, _pid} = start()
    task = ask_in_task(name, "q", timeout: 10_000)
    send(await_prompt("q"), {:result, "answer"})
    assert {:ok, %{text: "answer"}} = Task.await(task)
  end

  test "application default may be :infinity" do
    put_ask_timeout(:infinity)
    {name, _pid} = start()

    task = ask_in_task(name, "q", [])
    worker = await_prompt("q")
    send(worker, {:result, "answer"})

    assert {:ok, %{text: "answer"}} = Task.await(task)
  end

  test "per-call timeout can shorten a longer application default" do
    put_ask_timeout(:infinity)
    {name, _pid} = start()

    assert {:timeout, {GenServer, :call, _}} = catch_exit(E.ask(name, "slow", timeout: 0))
    send(await_prompt("slow"), {:result, "done"})
  end

  test "without configuration ask still works with the built-in default" do
    previous = Application.fetch_env(:gen_agent_ensemble, :ask_timeout)
    Application.delete_env(:gen_agent_ensemble, :ask_timeout)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:gen_agent_ensemble, :ask_timeout, old)
        :error -> :ok
      end
    end)

    {name, _pid} = start()
    task = ask_in_task(name, "q", [])
    worker = await_prompt("q")
    send(worker, {:result, "answer"})
    assert {:ok, %{text: "answer"}} = Task.await(task)
  end

  describe "invalid timeouts" do
    for bad <- [-1, 1.5, :soon, "100", nil] do
      test "per-call #{inspect(bad)} raises before submitting work" do
        {name, pid} = start()

        assert_raise ArgumentError, ~r/ask timeout/, fn ->
          E.ask(name, "never", timeout: unquote(Macro.escape(bad)))
        end

        assert :sys.get_state(pid).pending == %{}
        refute_receive {:controlled_prompt, _, "never", _}, 0
      end
    end

    test "invalid application setting raises before submitting work" do
      put_ask_timeout(-5)
      {name, pid} = start()

      assert_raise ArgumentError, ~r/ask timeout/, fn -> E.ask(name, "never") end
      assert :sys.get_state(pid).pending == %{}
      refute_receive {:controlled_prompt, _, "never", _}, 0
    end

    test "a valid per-call timeout overrides an invalid application setting" do
      put_ask_timeout(:bad)
      {name, _pid} = start()

      task = ask_in_task(name, "q", timeout: :infinity)
      send(await_prompt("q"), {:result, "answer"})

      assert {:ok, %{text: "answer"}} = Task.await(task)
    end

    test "validation happens before the session is looked up" do
      assert_raise ArgumentError, fn -> E.ask("no-such-ensemble", "x", timeout: -1) end
    end
  end
end
