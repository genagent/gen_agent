defmodule GenAgentEnsemble.Strategies.SupervisorTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.Strategies.Supervisor, as: SupStrat
  alias GenAgentEnsemble.TestAgent

  setup do
    name = "sup-#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(name) end)
    %{name: name}
  end

  defp safe_stop(name) do
    GenAgentEnsemble.stop(name)
  catch
    :exit, _ -> :ok
  end

  defp decomposer_newlines, do: fn text -> String.split(text, "\n", trim: true) end

  defp start_session(name, coord_scripts, worker_scripts) do
    coord = {"#{name}-coord", TestAgent, [backend: Mock, scripts: coord_scripts]}
    worker = {"#{name}-w", TestAgent, [backend: Mock, scripts: worker_scripts]}

    GenAgentEnsemble.start_link(
      name: name,
      strategy: SupStrat,
      opts: [
        coordinator: coord,
        worker_template: worker,
        decomposer: decomposer_newlines()
      ]
    )
  end

  test "fans out to N workers and concatenates", %{name: name} do
    coord_script = [Event.new(:result, %{text: "what\nwhy\nhow"})]

    worker_script =
      fn prompt -> [Event.new(:result, %{text: "answer: #{prompt}"})] end

    {:ok, _} =
      start_session(
        name,
        [coord_script],
        # three workers each consume one script; reuse the same function
        [worker_script, worker_script, worker_script]
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "big question", timeout: 5_000)

    # Worker names sort as w-1, w-2, w-3; each got one prompt in order.
    assert resp.text ==
             "answer: what\n\nanswer: why\n\nanswer: how"
  end

  test "status reports phase transitions", %{name: name} do
    coord_script = [Event.new(:result, %{text: "a\nb"})]
    worker_script = fn _p -> [Event.new(:result, %{text: "ok"})] end

    {:ok, _} = start_session(name, [coord_script], [worker_script, worker_script])

    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.phase == :idle

    {:ok, _resp} = GenAgentEnsemble.ask(name, "q", timeout: 5_000)

    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.phase == :idle
  end

  test "stops workers after fan-in completes", %{name: name} do
    coord_script = [Event.new(:result, %{text: "a\nb"})]
    worker_script = fn _p -> [Event.new(:result, %{text: "ok"})] end

    {:ok, _} = start_session(name, [coord_script], [worker_script, worker_script])

    {:ok, _} = GenAgentEnsemble.ask(name, "q", timeout: 5_000)

    # Let {:stop, ...} ops drain.
    Process.sleep(50)
    {:ok, info} = GenAgentEnsemble.status(name)

    # Only the coordinator should remain.
    assert info.agents == ["#{name}-coord"]
  end

  test "empty decomposition replies with coordinator text", %{name: name} do
    # Coordinator returns empty text; decomposer yields no sub-prompts.
    coord_script = [Event.new(:result, %{text: ""})]
    {:ok, _} = start_session(name, [coord_script], [])

    {:ok, resp} = GenAgentEnsemble.ask(name, "q", timeout: 5_000)
    assert resp.text == ""
  end

  test "second tell queues behind an in-flight fan-out", %{name: name} do
    # First coord response triggers 2 workers; second coord response also 2 workers.
    coord_scripts = [
      [Event.new(:result, %{text: "x\ny"})],
      [Event.new(:result, %{text: "p\nq"})]
    ]

    worker_script = fn prompt -> [Event.new(:result, %{text: "w:#{prompt}"})] end
    worker_scripts = List.duplicate(worker_script, 4)

    {:ok, _} = start_session(name, coord_scripts, worker_scripts)

    {:ok, t1} = GenAgentEnsemble.tell(name, "first")
    {:ok, t2} = GenAgentEnsemble.tell(name, "second")

    r1 = await_completion(name, t1)
    r2 = await_completion(name, t2)

    assert r1.text == "w:x\n\nw:y"
    assert r2.text == "w:p\n\nw:q"
  end

  test "worker turn error fails the outer token and stops siblings", %{name: name} do
    coord_script = [Event.new(:result, %{text: "ok1\nok2"})]
    # Worker 1 errors; worker 2's script won't matter.
    worker_scripts = [{:error, :worker_boom}, fn _ -> [Event.new(:result, %{text: "ok"})] end]

    {:ok, _} = start_session(name, [coord_script], worker_scripts)

    assert {:error, {_, :worker_boom}} = GenAgentEnsemble.ask(name, "q", timeout: 5_000)

    # Both workers should be torn down; coordinator remains.
    Process.sleep(50)
    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.agents == ["#{name}-coord"]
    assert info.phase == :idle
  end

  test "coordinator death halts the session", %{name: name} do
    coord_script = [Event.new(:result, %{text: "a\nb"})]
    worker_script = fn _ -> [Event.new(:result, %{text: "ok"})] end

    {:ok, pid} = start_session(name, [coord_script], [worker_script, worker_script])
    ref = Process.monitor(pid)

    # Kill the coordinator; handle_agent_down should halt the session.
    GenAgent.stop("#{name}/#{name}-coord")

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  defp await_completion(name, token, retries \\ 100) do
    case GenAgentEnsemble.poll(name, token) do
      {:ok, :completed, response} ->
        response

      {:ok, :pending} when retries > 0 ->
        Process.sleep(20)
        await_completion(name, token, retries - 1)

      other ->
        flunk("expected completion, got: #{inspect(other)}")
    end
  end
end
