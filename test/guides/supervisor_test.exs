guide = Path.expand("../../guides/patterns/supervisor.md", __DIR__)

for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
    String.starts_with?(code, "defmodule Fanout.") do
  Code.compile_string(code, guide)
end

defmodule GenAgent.SupervisorGuideTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  defmodule Backend do
    @behaviour GenAgent.Backend
    def start_session(opts) do
      observer = Process.whereis(GenAgent.SupervisorGuideTest)
      session = {observer, self(), Keyword.get(opts, :tag, :coordinator)}
      send(observer, {:session, session})
      {:ok, session}
    end

    def prompt({observer, _, tag} = session, prompt) do
      send(observer, {:prompt, tag, prompt, self()})

      receive do
        {:text, text} -> {:ok, [GenAgent.Event.new(:result, %{text: text})], session}
        :fail -> {:error, :scripted_failure}
        {:fail, reason} -> {:error, reason}
      after
        5_000 -> {:error, :fixture_timeout}
      end
    end

    def terminate_session({observer, _, _} = session) do
      send(observer, {:terminated, session})
      :ok
    end
  end

  defmodule WorkerBackend do
    @behaviour GenAgent.Backend
    def start_session(opts), do: Backend.start_session(Keyword.put(opts, :tag, :worker))
    defdelegate prompt(session, prompt), to: Backend
    defdelegate terminate_session(session), to: Backend
  end

  defmodule FailSecondBackend do
    @behaviour GenAgent.Backend
    def start_session(opts) do
      n = Agent.get_and_update(GenAgent.SupervisorGuideTest.Counter, &{&1, &1 + 1})
      if n == 0, do: WorkerBackend.start_session(opts), else: {:error, :start_failed}
    end

    defdelegate prompt(session, prompt), to: Backend
    defdelegate terminate_session(session), to: Backend
  end

  setup do
    Process.register(self(), __MODULE__)

    start_supervised!(%{
      id: :counter,
      start: {Agent, :start_link, [fn -> 0 end, [name: __MODULE__.Counter]]}
    })

    :ok
  end

  defp start(opts \\ []) do
    name = Keyword.get(opts, :name, "fanout-#{System.unique_integer([:positive])}")

    assert {:ok, _} =
             GenAgent.start_agent(
               Fanout.Coordinator,
               Keyword.merge(
                 [
                   name: name,
                   coordinator_name: name,
                   topic: "topic",
                   backend: Backend,
                   worker_backend: WorkerBackend,
                   collect_timeout: 2_000
                 ],
                 opts
               )
             )

    on_exit(fn -> if GenAgent.whereis(name), do: GenAgent.stop(name) end)
    name
  end

  defp state(name), do: GenAgent.status(name).agent_state
  defp await(fun, n \\ 2_000)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(1)
          await(fun, n - 1)
        )
  end

  defp plan(name, text \\ "one\ntwo") do
    assert {:ok, _} = GenAgent.tell(name, "plan")
    assert_receive {:prompt, :coordinator, "plan", task}
    send(task, {:text, text})
  end

  defp worker(task_text) do
    assert_receive {:prompt, :worker, ^task_text, task}, 1_000
    task
  end

  defp cleaned(s) do
    await(fn -> Enum.all?(s.workers, &(GenAgent.whereis(&1) == nil)) end)
    if s.watcher, do: await(fn -> not Process.alive?(s.watcher) end)
  end

  defp synthesize(name) do
    assert_receive {:prompt, :coordinator, prompt, task}, 1_000
    assert prompt =~ "Synthesize"
    send(task, {:text, "final"})
    await(fn -> state(name).phase == :done end)
    assert state(name).final_output == "final"
    cleaned(state(name))
  end

  test "success cleans sessions and registrations and permits immediate same-name rerun" do
    name = start()

    for _ <- 1..2 do
      plan(name)
      for text <- ["one", "two"], do: send(worker(text), {:text, text <> " result"})
      synthesize(name)
      assert map_size(state(name).results) == 2
      for _ <- 1..2, do: assert_receive({:terminated, {_, _, :worker}}, 1_000)
      GenAgent.stop(name)
      assert GenAgent.whereis(name) == nil
      start(name: name)
    end
  end

  test "partial failure synthesizes; duplicate, unknown and stale reports do not complete collection" do
    name = start()
    plan(name)
    one = worker("one")
    two = worker("two")
    s = state(name)
    [first, _] = s.workers

    for event <- [
          {:worker_result, s.run - 1, first, "stale"},
          {:worker_result, s.run, "unknown", "unknown"}
        ] do
      :ok = GenAgent.notify_ack(name, event)
    end

    assert state(name).results == %{}
    send(one, {:text, "ok"})
    await(fn -> map_size(state(name).results) == 1 end)
    :ok = GenAgent.notify_ack(name, {:worker_failed, s.run, first, :duplicate})
    assert state(name).failures == %{}
    send(two, :fail)
    synthesize(name)
    assert map_size(state(name).failures) == 1
  end

  test "all failures halt and clean up" do
    name = start()
    plan(name)
    for text <- ["one", "two"], do: send(worker(text), :fail)
    await(fn -> state(name).phase == :failed end)
    assert state(name).error == :all_workers_failed
    cleaned(state(name))
    before = state(name)

    for reply <- [{:text, "ignored"}, :fail] do
      GenAgent.resume(name)
      caller = Task.async(fn -> GenAgent.ask(name, "after failure") end)
      assert_receive {:prompt, :coordinator, "after failure", task}
      send(task, reply)
      Task.await(caller)
      await(fn -> GenAgent.status(name).halted end)
      assert state(name) == before
    end
  end

  test "worker crash is reported without waiting for the deadline" do
    name = start(collect_timeout: 60_000)
    plan(name, "one")
    worker("one")
    [worker_name] = state(name).workers
    Process.exit(GenAgent.whereis(worker_name), :kill)
    await(fn -> state(name).phase == :failed end)
    assert state(name).failures[worker_name] == :killed
    cleaned(state(name))
  end

  test "deadline stops a blocked worker" do
    name = start(collect_timeout: 100)
    plan(name, "one")
    worker("one")
    await(fn -> state(name).phase == :failed end)
    assert Map.values(state(name).failures) == [:timeout]
    cleaned(state(name))
  end

  test "dropped report and rejected deadline retry eventually finish collection" do
    name = start(collect_timeout: 200, max_pending_notifications: 0)
    plan(name, "one")
    task = worker("one")
    assert {:ok, _} = GenAgent.tell(name, "extra")
    assert_receive {:prompt, :coordinator, "extra", extra}
    s = state(name)
    assert {:error, {:overloaded, _}} = GenAgent.notify_ack(name, {:collect_timeout, s.run})
    send(task, {:text, "dropped"})
    await(fn -> GenAgent.whereis(hd(s.workers)) == nil end)
    assert Process.alive?(s.watcher)
    send(extra, {:text, "ignored"})
    await(fn -> state(name).phase == :failed end)
    assert state(name).results == %{}
    cleaned(state(name))
  end

  test "external stop or crash cleans workers and immediate replacement uses distinct names" do
    for action <- [:stop, :kill] do
      name = start()
      plan(name, "one")
      worker("one")
      old = state(name)

      if action == :stop,
        do: GenAgent.stop(name),
        else: Process.exit(GenAgent.whereis(name), :kill)

      await(fn -> GenAgent.whereis(name) == nil end)
      start(name: name)
      plan(name, "one")
      task = worker("one")
      assert state(name).workers != old.workers
      cleaned(old)
      send(task, {:text, "ok"})
      synthesize(name)
      GenAgent.stop(name)
    end
  end

  test "partial worker startup failure stops already started sessions" do
    name = start(worker_backend: FailSecondBackend)
    plan(name)
    await(fn -> state(name).phase == :failed end)
    assert {:worker_start, _} = state(name).error
    assert_receive {:terminated, {_, pid, :worker}}, 1_000
    refute Process.alive?(pid)
    cleaned(state(name))
  end

  test "extra ask during collection and resumed terminal turns preserve state" do
    name = start()
    plan(name, "one")
    task = worker("one")
    caller = Task.async(fn -> GenAgent.ask(name, "extra") end)
    assert_receive {:prompt, :coordinator, "extra", extra}
    send(extra, {:text, "ignored"})
    assert {:ok, _} = Task.await(caller)
    assert state(name).phase == :collecting
    caller = Task.async(fn -> GenAgent.ask(name, "extra failure") end)
    assert_receive {:prompt, :coordinator, "extra failure", extra}
    send(extra, :fail)
    assert {:error, :scripted_failure} = Task.await(caller)
    assert state(name).phase == :collecting
    send(task, {:text, "ok"})
    synthesize(name)
    GenAgent.resume(name)
    assert {:ok, _} = GenAgent.tell(name, "after done")
    assert_receive {:prompt, :coordinator, "after done", terminal}
    send(terminal, {:text, "ignored"})
    await(fn -> GenAgent.status(name).halted end)
    assert state(name).final_output == "final"
  end

  for outcome <- [:success, :error, :provider_overload] do
    @queued_outcome outcome
    test "queued extra turn #{@queued_outcome} cannot finish synthesis" do
      name = start(collect_timeout: 60_000)
      plan(name, "one")
      worker("one")
      s = state(name)
      [worker_name] = s.workers

      assert {:ok, _} = GenAgent.tell(name, "in-flight extra")
      assert_receive {:prompt, :coordinator, "in-flight extra", in_flight}
      assert {:ok, _} = GenAgent.tell(name, "queued extra")

      # Admission is synchronous: the final report is buffered while the
      # first extra turn is blocked, with the second already in the queue.
      assert :ok =
               GenAgent.notify_ack(name, {:worker_result, s.run, worker_name, "worker finding"})

      assert state(name).phase == :collecting
      send(in_flight, {:text, "in-flight answer"})
      assert_receive {:prompt, :coordinator, "queued extra", queued}
      assert state(name).phase == :synthesizing
      assert state(name).final_output == nil

      queued_reply =
        case @queued_outcome do
          :success -> {:text, "wrong answer"}
          :error -> :fail
          :provider_overload -> {:fail, {:overloaded, %{provider: :fixture}}}
        end

      send(queued, queued_reply)

      assert_receive {:prompt, :coordinator, prompt, synthesis}, 1_000
      assert prompt =~ "Synthesize these"
      assert prompt =~ "Result: worker finding"
      assert state(name).phase == :synthesizing
      assert state(name).final_output == nil
      send(synthesis, {:text, "answer from synthesis prompt"})
      await(fn -> state(name).phase == :done end)
      assert state(name).final_output == "answer from synthesis prompt"
      assert state(name).error == nil
      cleaned(state(name))
    end
  end

  test "full prompt queue rejects buffered synthesis and fails with cleanup" do
    name = start(collect_timeout: 60_000, max_pending_prompts: 1)
    plan(name, "one")
    worker("one")
    s = state(name)
    [worker_name] = s.workers

    assert {:ok, _} = GenAgent.tell(name, "in-flight extra")
    assert_receive {:prompt, :coordinator, "in-flight extra", in_flight}
    assert {:ok, _} = GenAgent.tell(name, "queued extra")

    assert :ok =
             GenAgent.notify_ack(name, {:worker_result, s.run, worker_name, "worker finding"})

    assert state(name).phase == :collecting
    send(in_flight, {:text, "in-flight answer"})
    await(fn -> state(name).phase == :failed end)
    assert GenAgent.status(name).halted
    assert {:overloaded, _} = state(name).error
    assert state(name).synthesis_turn == false
    assert state(name).final_output == nil
    cleaned(s)
    assert_receive {:terminated, {_, _, :worker}}, 1_000

    # Halting retains ordinary queued tells. Release that turn after resume
    # and verify it cannot replace the terminal overload failure.
    failed = state(name)
    GenAgent.resume(name)
    assert_receive {:prompt, :coordinator, "queued extra", queued}
    send(queued, {:text, "queued answer"})
    await(fn -> GenAgent.status(name).halted end)
    assert state(name) == failed
  end

  test "empty plan, planning error and synthesis error all halt with cleanup" do
    for mode <- [:empty, :planning_error, :synthesis_error] do
      name = start()

      if mode == :planning_error do
        GenAgent.tell(name, "plan")
        assert_receive {:prompt, :coordinator, "plan", task}
        send(task, :fail)
      else
        plan(name, if(mode == :empty, do: "", else: "one"))

        if mode == :synthesis_error do
          send(worker("one"), {:text, "ok"})
          assert_receive {:prompt, :coordinator, _, task}
          send(task, :fail)
        end
      end

      await(fn -> state(name).phase == :failed end)
      cleaned(state(name))
    end
  end
end
