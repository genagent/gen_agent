defmodule ChaosLab.Assertions do
  defmacro observe(pattern) do
    quote do
      receive do
        unquote(pattern) = message ->
          IO.inspect(message, label: "observed")
          message
      after
        5_000 -> raise "Missing observation: #{unquote(Macro.to_string(pattern))}"
      end
    end
  end

  def check!(condition, label) do
    unless condition, do: raise(label)
  end

  def eventually(fun), do: eventually(fun, System.monotonic_time(:millisecond) + 5_000)

  defp eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      check!(
        System.monotonic_time(:millisecond) < deadline,
        "Timed out waiting for registry/tree"
      )

      Process.sleep(10)
      eventually(fun, deadline)
    end
  end
end

defmodule ChaosLab.Run do
  import ChaosLab.Assertions

  def run do
    a()
    b()
    c()
    d()
    e()
    f()
    g()
    h()
    i()
    unavailable_task_supervisor()
    IO.puts("chaos_lab: ok")
  end

  defp opts(name, extra) do
    Keyword.merge([name: name, backend: ChaosLab.SlowBackend, observer: self()], extra)
  end

  defp start(name, extra \\ []) do
    {:ok, pid} = GenAgent.start_agent(ChaosLab.Agent, opts(name, extra))
    pid
  end

  defp hold(name) do
    pid = GenAgent.whereis(name)
    {:ok, ref} = GenAgent.tell_with_completion(name, "hold")
    {:stream, ^pid, task, :text, "hold"} = observe({:stream, ^pid, _, :text, "hold"})
    {ref, task}
  end

  defp stopped(pid) do
    observe({:terminated_agent, ^pid, :shutdown})
    observe({:terminated_session, ^pid, _})
  end

  defp a do
    IO.puts("A: killed prompt task, caller-owned retry and final completion")
    pid = start(:chaos_a)
    {ref, task} = hold(:chaos_a)
    Process.exit(task, :kill)
    observe({:handle_error, ^pid, ^ref, {:task_crashed, :killed}})
    observe({:response, ^pid, ^ref, "retry after crash"})

    observe(
      {:gen_agent, :completion, :chaos_a, ^ref,
       {:ok, %GenAgent.Response{text: "retry after crash"}}}
    )

    %{agent_state: %{retried: true, responses: ["retry after crash"]}} = GenAgent.status(:chaos_a)
    check!(GenAgent.whereis(:chaos_a) == pid, "A: agent pid changed")
    :ok = GenAgent.stop(:chaos_a)
  end

  defp b do
    IO.puts("B: raising stream returns a task error to ask")
    pid = start(:chaos_b, retry: false)
    {:error, {:task_crashed, _}} = IO.inspect(GenAgent.ask(:chaos_b, "crash", 5_000))
    observe({:handle_error, ^pid, _, {:task_crashed, _}})
    {:ok, %{text: "still serving"}} = GenAgent.ask(:chaos_b, "still serving", 5_000)
    check!(GenAgent.whereis(:chaos_b) == pid, "B: agent pid changed")
    :ok = GenAgent.stop(:chaos_b)
  end

  defp c do
    IO.puts("C: killed agent has no completion and releases its name")
    pid = start(:chaos_c)
    {ref, task} = hold(:chaos_c)
    monitor = Process.monitor(pid)
    task_monitor = Process.monitor(task)
    Process.exit(pid, :kill)
    observe({:DOWN, ^monitor, :process, ^pid, :killed})
    observe({:DOWN, ^task_monitor, :process, ^task, :killed})
    eventually(fn -> GenAgent.whereis(:chaos_c) == nil end)

    # Both possible producers are dead. No sleep is needed to check their messages.
    receive do
      {:gen_agent, :completion, :chaos_c, ^ref, outcome} ->
        raise "C: unexpected completion #{inspect(outcome)}"

      {:terminated_agent, ^pid, _} ->
        raise "C: kill unexpectedly ran terminate_agent"

      {:terminated_session, ^pid, _} ->
        raise "C: kill unexpectedly ran terminate_session"
    after
      0 -> :ok
    end

    replacement = start(:chaos_c)
    check!(replacement != pid, "C: expected a new agent")
    :ok = GenAgent.stop(:chaos_c)
  end

  defp d do
    IO.puts("D: watchdog cancels a held turn and the agent keeps serving")
    pid = start(:chaos_d, watchdog_ms: 100)
    caller = Task.async(fn -> GenAgent.ask(:chaos_d, "hold", 5_000) end)
    observe({:stream, ^pid, _, :text, "hold"})
    {:error, :timeout} = IO.inspect(Task.await(caller, 5_000))
    observe({:handle_error, ^pid, _, :timeout})
    {:ok, %{text: "still serving"}} = GenAgent.ask(:chaos_d, "still serving", 5_000)
    check!(GenAgent.whereis(:chaos_d) == pid, "D: agent pid changed")
    :ok = GenAgent.stop(:chaos_d)
  end

  defp tree do
    children = [
      Supervisor.child_spec({Task.Supervisor, name: ChaosLab.Tasks}, id: :tasks),
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one}, id: :agents)
    ]

    {:ok, owner} = Supervisor.start_link(children, strategy: :rest_for_one)
    {owner, child(owner, :tasks), child(owner, :agents)}
  end

  defp child(owner, id) do
    {^id, pid, :supervisor, _} = List.keyfind(Supervisor.which_children(owner), id, 0)
    pid
  end

  defp spec(name, extra \\ []) do
    GenAgent.child_spec(ChaosLab.Agent, opts(name, [task_supervisor: ChaosLab.Tasks] ++ extra))
  end

  defp e do
    IO.puts("E: caller-owned duplicate start and explicit stop")
    {owner, _tasks, agents} = tree()

    try do
      {:ok, pid} = DynamicSupervisor.start_child(agents, spec(:chaos_e))

      {:error, {:already_started, ^pid}} =
        IO.inspect(DynamicSupervisor.start_child(agents, spec(:chaos_e)))

      :ok = GenAgent.stop(:chaos_e, agents)
      stopped(pid)
      eventually(fn -> GenAgent.whereis(:chaos_e) == nil end)
    after
      Supervisor.stop(owner)
    end
  end

  defp f do
    IO.puts("F: rest_for_one restarts both supervisors with an empty agent set")
    {owner, tasks, agents} = tree()

    try do
      {:ok, pid} = DynamicSupervisor.start_child(agents, spec(:chaos_f))
      task_monitor = Process.monitor(tasks)
      agent_supervisor_monitor = Process.monitor(agents)
      agent_monitor = Process.monitor(pid)
      Process.exit(tasks, :kill)
      observe({:DOWN, ^task_monitor, :process, ^tasks, :killed})
      observe({:DOWN, ^agent_supervisor_monitor, :process, ^agents, :shutdown})
      observe({:DOWN, ^agent_monitor, :process, ^pid, :shutdown})
      eventually(fn -> child(owner, :tasks) != tasks and child(owner, :agents) != agents end)
      [] = DynamicSupervisor.which_children(child(owner, :agents))
      eventually(fn -> GenAgent.whereis(:chaos_f) == nil end)
      IO.puts("supervisor: both replaced, no agents restarted")
    after
      Supervisor.stop(owner)
    end
  end

  defp g do
    IO.puts("G: owner shutdown during a turn runs both terminate callbacks")
    {owner, _tasks, agents} = tree()
    {:ok, pid} = DynamicSupervisor.start_child(agents, spec(:chaos_g))
    {_ref, task} = hold(:chaos_g)
    monitor = Process.monitor(task)
    :ok = Supervisor.stop(owner)
    stopped(pid)
    observe({:DOWN, ^monitor, :process, ^task, :killed})
    eventually(fn -> GenAgent.whereis(:chaos_g) == nil end)
  end

  defp h do
    IO.puts("H: permanent override restarts with fresh agent and session state")
    {owner, _tasks, agents} = tree()

    try do
      permanent = Supervisor.child_spec(spec(:chaos_h), restart: :permanent)
      {:ok, pid} = DynamicSupervisor.start_child(agents, permanent)
      {:session_started, ^pid, old_session} = observe({:session_started, ^pid, _})
      {:ok, _} = GenAgent.ask(:chaos_h, "before restart", 5_000)
      %{agent_state: %{responses: ["before restart"]}} = GenAgent.status(:chaos_h)
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      observe({:DOWN, ^monitor, :process, ^pid, :killed})

      eventually(fn ->
        is_pid(GenAgent.whereis(:chaos_h)) and GenAgent.whereis(:chaos_h) != pid
      end)

      replacement = GenAgent.whereis(:chaos_h)
      {:session_started, ^replacement, new_session} = observe({:session_started, ^replacement, _})
      check!(new_session != old_session, "H: backend session was reused")
      %{agent_state: %{responses: [], retried: false}} = GenAgent.status(:chaos_h)
      {:ok, _} = GenAgent.ask(:chaos_h, "after restart", 5_000)
      observe({:backend_prompt, _, ^new_session, 0, "after restart"})
    after
      Supervisor.stop(owner)
    end
  end

  defp i do
    IO.puts("I: bounded notification and prompt admission during a held turn")
    start(:chaos_i, max_pending_notifications: 5, max_pending_prompts: 2)
    {ref, task} = hold(:chaos_i)
    for n <- 1..5, do: :ok = GenAgent.notify_ack(:chaos_i, {:notice, n}, 5_000)

    {:error, {:overloaded, notifications}} = GenAgent.notify_ack(:chaos_i, {:notice, 6}, 5_000)
    %{queue: :notifications, limit: :count, pending_count: 5, max_count: 5} = notifications
    IO.inspect(notifications, label: "notification overload")
    {:ok, first} = GenAgent.tell(:chaos_i, "queued one", 5_000)
    {:ok, second} = GenAgent.tell(:chaos_i, "queued two", 5_000)
    {:error, {:overloaded, prompts}} = GenAgent.tell(:chaos_i, "rejected", 5_000)
    %{queue: :prompts, limit: :count, pending_count: 2, max_count: 2} = prompts
    IO.inspect(prompts, label: "prompt overload")

    %{
      phase: :processing,
      pending_prompts: 2,
      pending_notifications: 5,
      self_chain_pending: false,
      current_request: %{ref: ^ref}
    } =
      IO.inspect(GenAgent.runtime_snapshot(:chaos_i, 5_000), label: "runtime snapshot")

    send(task, :release)
    observe({:gen_agent, :completion, :chaos_i, ^ref, {:ok, _}})
    pid = GenAgent.whereis(:chaos_i)
    observe({:response, ^pid, ^first, "queued one"})
    observe({:response, ^pid, ^second, "queued two"})
    %{pending_prompts: 0, pending_notifications: 0} = GenAgent.runtime_snapshot(:chaos_i, 5_000)
    :ok = GenAgent.stop(:chaos_i)
  end

  defp unavailable_task_supervisor do
    IO.puts("Gap probe: retry while the caller-owned task supervisor is unavailable")
    {owner, _tasks, agents} = tree()

    try do
      {:ok, pid} = DynamicSupervisor.start_child(agents, spec(:chaos_gap))
      {ref, _task} = hold(:chaos_gap)
      monitor = Process.monitor(pid)
      # Freeze delivery of task DOWN until the supervisor is definitely absent.
      :ok = :sys.suspend(pid)
      :ok = Supervisor.terminate_child(owner, :tasks)
      :ok = :sys.resume(pid)
      observe({:handle_error, ^pid, ^ref, {:task_crashed, :shutdown}})
      observe({:handle_error, ^pid, ^ref, :task_supervisor_unavailable})
      observe({:gen_agent, :completion, :chaos_gap, ^ref, {:error, :task_supervisor_unavailable}})
      check!(GenAgent.whereis(:chaos_gap) == pid, "gap probe: agent stopped")
      Process.demonitor(monitor, [:flush])
    after
      Supervisor.stop(owner)
    end
  end
end

ChaosLab.Run.run()
