defmodule GenAgentEnsemble.Strategies.SupervisorTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.Queue
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

  defp start_session(name, coord_scripts, worker_scripts, extra_opts \\ []) do
    coord = {"#{name}-coord", TestAgent, [backend: Mock, scripts: coord_scripts]}
    worker = {"#{name}-w", TestAgent, [backend: Mock, scripts: worker_scripts]}

    GenAgentEnsemble.start_link(
      name: name,
      strategy: SupStrat,
      opts:
        Keyword.merge(
          [
            coordinator: coord,
            worker_template: worker,
            decomposer: decomposer_newlines()
          ],
          extra_opts
        )
    )
  end

  test "fans out to N workers and labels their responses", %{name: name} do
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

    assert resp.text ==
             "### what\n\nanswer: what\n\n### why\n\nanswer: why\n\n### how\n\nanswer: how"
  end

  test "default synthesizer keeps decomposition order with two-digit worker names", %{name: name} do
    prompts = Enum.map(1..12, &"task-#{&1}")
    coord_script = [Event.new(:result, %{text: Enum.join(prompts, "\n")})]
    worker_script = fn prompt -> [Event.new(:result, %{text: "answer: #{prompt}"})] end

    {:ok, _} =
      start_session(name, [coord_script], List.duplicate(worker_script, 12), max_subtasks: 12)

    {:ok, resp} = GenAgentEnsemble.ask(name, "q", timeout: 5_000)
    assert resp.text == Enum.map_join(prompts, "\n\n", &"### #{&1}\n\nanswer: #{&1}")
  end

  test "two-argument synthesizer receives subtasks aligned with ordered outputs", %{name: name} do
    prompts = Enum.map(1..12, &"task-#{&1}")
    coord_script = [Event.new(:result, %{text: Enum.join(prompts, "\n")})]
    worker_script = fn _prompt -> [Event.new(:result, %{text: "same answer"})] end
    synthesizer = fn outputs, subtasks -> inspect(Enum.zip(outputs, subtasks)) end

    {:ok, _} =
      start_session(name, [coord_script], List.duplicate(worker_script, 12),
        synthesizer: synthesizer,
        max_subtasks: 12
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "q", timeout: 5_000)

    expected =
      Enum.with_index(prompts, 1)
      |> Enum.map(fn {prompt, index} -> {{"#{name}-w-#{index}", "same answer"}, prompt} end)

    assert resp.text == inspect(expected)
  end

  test "custom synthesizer receives outputs in decomposition order", %{name: name} do
    prompts = Enum.map(1..12, &"task-#{&1}")
    coord_script = [Event.new(:result, %{text: Enum.join(prompts, "\n")})]
    worker_script = fn prompt -> [Event.new(:result, %{text: "answer: #{prompt}"})] end
    synthesizer = &inspect/1

    {:ok, _} =
      start_session(name, [coord_script], List.duplicate(worker_script, 12),
        synthesizer: synthesizer,
        max_subtasks: 12
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "q", timeout: 5_000)

    expected =
      Enum.with_index(prompts, 1)
      |> Enum.map(fn {prompt, index} -> {"#{name}-w-#{index}", "answer: #{prompt}"} end)

    assert resp.text == inspect(expected)
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
    coord_script = [Event.new(:result, %{text: "coordinator answer"})]
    synthesizer = fn _, _ -> flunk("empty decomposition should skip synthesis") end

    {:ok, _} =
      start_session(name, [coord_script], [],
        decomposer: fn _ -> [] end,
        synthesizer: synthesizer
      )

    {:ok, resp} = GenAgentEnsemble.ask(name, "q", timeout: 5_000)
    assert resp.text == "coordinator answer"
  end

  test "decomposition at max_subtasks fans out", %{name: name} do
    coord_script = [Event.new(:result, %{text: "a\nb"})]
    worker_script = fn prompt -> [Event.new(:result, %{text: "w:#{prompt}"})] end

    {:ok, _} =
      start_session(name, [coord_script], [worker_script, worker_script], max_subtasks: 2)

    {:ok, resp} = GenAgentEnsemble.ask(name, "q", timeout: 5_000)
    assert resp.text == "### a\n\nw:a\n\n### b\n\nw:b"
  end

  test "decomposition over max_subtasks errors and starts no workers", %{name: name} do
    coord_script = [Event.new(:result, %{text: "a\nb\nc"})]

    {:ok, _} = start_session(name, [coord_script], [], max_subtasks: 2)

    assert {:error, {:too_many_subtasks, 3, 2}} = GenAgentEnsemble.ask(name, "q", timeout: 5_000)

    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.agents == ["#{name}-coord"]
    assert info.phase == :idle
  end

  test "default max_subtasks rejects an oversized decomposition", %{name: name} do
    text = Enum.map_join(1..11, "\n", &"t#{&1}")

    {:ok, _} = start_session(name, [[Event.new(:result, %{text: text})]], [])

    assert {:error, {:too_many_subtasks, 11, 10}} =
             GenAgentEnsemble.ask(name, "q", timeout: 5_000)
  end

  test "empty decomposition is within the limit", %{name: name} do
    coord_script = [Event.new(:result, %{text: "coordinator answer"})]

    {:ok, _} =
      start_session(name, [coord_script], [], decomposer: fn _ -> [] end, max_subtasks: 1)

    {:ok, resp} = GenAgentEnsemble.ask(name, "q", timeout: 5_000)
    assert resp.text == "coordinator answer"
  end

  test "init rejects invalid max_subtasks", %{name: name} do
    Process.flag(:trap_exit, true)

    for bad <- [0, -1, 1.5, "3", nil] do
      assert {:error, {:init_failed, :error, ArgumentError}} =
               start_session(name, [], [], max_subtasks: bad)
    end
  end

  test "queued run continues after an over-limit run" do
    {:ok, state, _} =
      SupStrat.init(
        coordinator: {"coord", TestAgent, []},
        worker_template: {"w", TestAgent, [backend: Mock]},
        decomposer: decomposer_newlines(),
        max_subtasks: 2
      )

    {:ok, [{:dispatch, "coord", "first", :t1}], state} =
      SupStrat.handle_tell("first", [], :t1, state)

    {:ok, [], state} = SupStrat.handle_tell("second", [], :t2, state)

    response = %GenAgent.Response{text: "x\ny\nz"}

    assert {:ok, ops, state} = SupStrat.handle_response("coord", response, state)

    assert ops == [
             {:reply_error, :t1, {:too_many_subtasks, 3, 2}},
             {:dispatch, "coord", "second", :t2}
           ]

    assert state.phase == {:decomposing, :t2}
  end

  defp init_strategy(extra \\ []) do
    {:ok, state, _} =
      SupStrat.init(
        Keyword.merge(
          [
            coordinator: {"coord", TestAgent, []},
            worker_template: {"w", TestAgent, [backend: Mock]},
            decomposer: decomposer_newlines()
          ],
          extra
        )
      )

    state
  end

  # Two workers fanned out for :t1 with :t2 queued behind it.
  defp fanned_out_state do
    state = init_strategy()
    {:ok, _, state} = SupStrat.handle_tell("first", [], :t1, state)
    {:ok, [], state} = SupStrat.handle_tell("second", [], :t2, state)
    response = %GenAgent.Response{text: "x\ny"}
    {:ok, _ops, state} = SupStrat.handle_response("coord", response, state)
    state
  end

  test "death of a completed worker preserves the active run and queue" do
    state = fanned_out_state()
    done = %GenAgent.Response{text: "one"}

    {:ok, [], state} = SupStrat.handle_response("w-1", done, state)

    assert {:ok, [], state} = SupStrat.handle_agent_down("w-1", :killed, state)
    assert {:fanning_out, :t1, _} = state.phase
    assert Queue.len(state.queue) == 1

    assert {:ok, ops, state} =
             SupStrat.handle_response("w-2", %GenAgent.Response{text: "two"}, state)

    assert [{:reply, :t1, %GenAgent.Response{}} | _] = ops
    assert state.phase == {:decomposing, :t2}
  end

  test "death of a pending worker fails the run and queued requests" do
    state = fanned_out_state()

    {:ok, [], state} = SupStrat.handle_response("w-1", %GenAgent.Response{text: "one"}, state)

    assert {:ok, ops, state} = SupStrat.handle_agent_down("w-2", :killed, state)
    failure = {:worker_down, "w-2", :killed}

    assert Enum.sort(ops) ==
             Enum.sort([
               {:stop, "w-1"},
               {:reply_error, :t1, failure},
               {:reply_error, :t2, failure}
             ])

    assert state.phase == :idle
    assert Queue.len(state.queue) == 0
  end

  test "reply precedes worker stops and stops precede the next queued dispatch" do
    state = fanned_out_state()

    {:ok, [], state} = SupStrat.handle_response("w-1", %GenAgent.Response{text: "one"}, state)
    {:ok, ops, _state} = SupStrat.handle_response("w-2", %GenAgent.Response{text: "two"}, state)

    assert [{:reply, :t1, _}, stop_a, stop_b, {:dispatch, "coord", "second", :t2}] = ops
    assert Enum.sort([stop_a, stop_b]) == [{:stop, "w-1"}, {:stop, "w-2"}]
  end

  test "init rejects a coordinator name that collides with a generated worker name" do
    for name <- ["w-1", "w-10"] do
      assert_raise ArgumentError, ~r/collides/, fn ->
        init_strategy(coordinator: {name, TestAgent, []}, max_subtasks: 10)
      end
    end
  end

  test "init allows similar coordinator names outside the generated range" do
    for name <- ["w-0", "w-11", "w-01", "w-x", "w", "w-1-b", "other-1"] do
      assert %SupStrat{} = init_strategy(coordinator: {name, TestAgent, []}, max_subtasks: 10)
    end
  end

  test "collision check does not allocate for a huge max_subtasks" do
    assert %SupStrat{} =
             init_strategy(coordinator: {"coord", TestAgent, []}, max_subtasks: 1_000_000_000)

    assert_raise ArgumentError, ~r/collides/, fn ->
      init_strategy(coordinator: {"w-999999999", TestAgent, []}, max_subtasks: 1_000_000_000)
    end
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

    assert r1.text == "### x\n\nw:x\n\n### y\n\nw:y"
    assert r2.text == "### p\n\nw:p\n\n### q\n\nw:q"
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
    Process.exit(GenAgent.whereis("#{name}/#{name}-coord"), :kill)

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
