defmodule GenAgentEnsemble.Strategies.FunctionContainmentTest do
  # Live sessions: a failing user function fails only its token, the session
  # survives and the queued successor runs.
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.{Consensus, Debate}
  alias GenAgentEnsemble.Strategies.Supervisor, as: SupStrat

  defmodule BlockingWorker do
    @moduledoc false
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, Keyword.take(opts, [:scripts]), %{observer: opts[:observer]}}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}

    @impl true
    def terminate_agent(reason, state) do
      send(state.observer, {:worker_stopping, self(), reason})

      receive do
        :release_worker -> :ok
      after
        3_000 -> :ok
      end
    end
  end

  setup do
    name = "contain-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      for worker <- ["#{name}/#{name}-w-1", "#{name}/worker-1"],
          pid = GenAgent.whereis(worker),
          do: send(pid, :release_worker)

      case Registry.lookup(GenAgentEnsemble.Registry, name) do
        [{server, _}] ->
          try do
            GenServer.stop(server, :normal, 10_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end
    end)

    {:ok, name: name}
  end

  defp spec(tag),
    do: {tag, ControlledAgent, [backend: ControlledBackend, observer: self(), tag: tag]}

  defp await_poll(name, token, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    case Ensemble.poll(name, token) do
      {:ok, :pending} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_poll(name, token, deadline)
        else
          flunk("token #{inspect(token)} did not complete")
        end

      other ->
        other
    end
  end

  defp await_agents(name, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    {:ok, status} = Ensemble.status(name)

    cond do
      Enum.sort(status.agents) == Enum.sort(expected) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        await_agents(name, expected, deadline)

      true ->
        flunk("agents did not become #{inspect(expected)}; got #{inspect(status.agents)}")
    end
  end

  defp refute_leak(reason), do: refute(inspect(reason) =~ "secret")

  describe "Consensus" do
    defp parse("raise"), do: raise("secret-payload")
    defp parse("throw"), do: throw({:secret, "payload"})
    defp parse("exit"), do: exit({:secret, "payload"})
    defp parse("abstain"), do: :error
    defp parse("bad-verdict-string"), do: {:ok, "approve", "x"}
    defp parse("bad-rationale-nil"), do: {:ok, :approve, nil}
    defp parse("bad-verdict-nil"), do: {:ok, nil, "x"}
    defp parse("bad-bare-atom"), do: :bogus
    defp parse("bad-nil"), do: nil
    defp parse("R:" <> _ = text), do: {:ok, :reject, text}
    defp parse(text), do: {:ok, :approve, text}

    defp start_consensus(name, extra \\ []) do
      Ensemble.start_link(
        name: name,
        strategy: Consensus,
        opts:
          Keyword.merge(
            [agents: [spec("a"), spec("b")], rounds: 1, verdict_parser: &parse/1],
            extra
          )
      )
    end

    cases = [
      {"raise", {:strategy_function_failed, :verdict_parser, :error, RuntimeError}},
      {"throw", {:strategy_function_failed, :verdict_parser, :throw, :other}},
      {"exit", {:strategy_function_failed, :verdict_parser, :exit, :other}},
      {"bad-verdict-string", {:invalid_strategy_result, :verdict_parser}},
      {"bad-rationale-nil", {:invalid_strategy_result, :verdict_parser}},
      {"bad-verdict-nil", {:invalid_strategy_result, :verdict_parser}},
      {"bad-bare-atom", {:invalid_strategy_result, :verdict_parser}},
      {"bad-nil", {:invalid_strategy_result, :verdict_parser}}
    ]

    for {trigger, expected} <- cases do
      test "parser #{trigger} fails the token, fences the sibling and runs the queue",
           %{name: name} do
        {:ok, pid} = start_consensus(name)
        {:ok, first} = Ensemble.tell(name, "first")
        assert_receive {:controlled_prompt, "a", "first", a1}, 2_000
        assert_receive {:controlled_prompt, "b", "first", b1}, 2_000
        {:ok, second} = Ensemble.tell(name, "second")

        send(a1, {:result, unquote(trigger)})
        assert {:error, reason} = await_poll(name, first)
        assert reason == unquote(Macro.escape(expected))
        refute_leak(reason)
        assert Process.alive?(pid)

        # The still-running sibling of the failed run cannot count toward
        # the successor.
        assert_receive {:controlled_prompt, "a", "second", a2}, 2_000
        send(b1, {:result, "LATE_B"})
        assert_receive {:controlled_prompt, "b", "second", b2}, 2_000
        assert {:ok, %{phase: %{responded: 0}}} = Ensemble.status(name)

        send(a2, {:result, "NEW_A"})
        send(b2, {:result, "NEW_B"})
        assert {:ok, :completed, response} = await_poll(name, second)
        assert response.text =~ "NEW_A"
        refute response.text =~ "LATE_B"
      end
    end

    test "an explicit :error abstain is a normal result, not a failure", %{name: name} do
      {:ok, _} = start_consensus(name)
      {:ok, token} = Ensemble.tell(name, "q")
      assert_receive {:controlled_prompt, "a", "q", a1}, 2_000
      assert_receive {:controlled_prompt, "b", "q", b1}, 2_000

      send(a1, {:result, "abstain"})
      send(b1, {:result, "fine"})

      assert {:ok, :completed, response} = await_poll(name, token)
      assert response.text =~ "a [abstain]"
      assert response.text =~ "b [APPROVE]"
    end

    test "a parser failure in round two fails the token mid-deliberation", %{name: name} do
      {:ok, pid} = start_consensus(name, rounds: 2, threshold: :unanimous)
      {:ok, first} = Ensemble.tell(name, "first")
      assert_receive {:controlled_prompt, "a", "first", a1}, 2_000
      assert_receive {:controlled_prompt, "b", "first", b1}, 2_000
      {:ok, second} = Ensemble.tell(name, "second")

      send(a1, {:result, "agree"})
      send(b1, {:result, "R: disagree"})
      assert_receive {:controlled_prompt, "a", "The other panelists" <> _, a2}, 2_000
      assert_receive {:controlled_prompt, "b", "The other panelists" <> _, b2}, 2_000

      send(a2, {:result, "raise"})
      assert {:error, reason} = await_poll(name, first)
      assert reason == {:strategy_function_failed, :verdict_parser, :error, RuntimeError}
      assert Process.alive?(pid)

      assert_receive {:controlled_prompt, "a", "second", a3}, 2_000
      send(b2, {:result, "LATE_ROUND_TWO_B"})
      assert_receive {:controlled_prompt, "b", "second", b3}, 2_000
      assert {:ok, %{phase: %{round: 1, responded: 0}}} = Ensemble.status(name)

      send(a3, {:result, "NEW_A"})
      send(b3, {:result, "NEW_B"})
      assert {:ok, :completed, response} = await_poll(name, second)
      refute response.text =~ "LATE_ROUND_TWO_B"
    end

    synth_cases = [
      {"boom", {:strategy_function_failed, :synthesizer_reply, :error, RuntimeError}},
      {"bad", {:invalid_strategy_result, :synthesizer_reply}}
    ]

    for {trigger, expected} <- synth_cases do
      test "{:synthesize, fun} #{trigger} fails the token and runs the queue", %{name: name} do
        synth = fn summary ->
          case Enum.map(summary.responses, &elem(&1, 3)) do
            ["boom" | _] -> raise "secret-payload"
            ["bad" | _] -> {:not, :a, :binary}
            _ -> "synthesized"
          end
        end

        {:ok, pid} = start_consensus(name, reply: {:synthesize, synth})
        {:ok, first} = Ensemble.tell(name, "first")
        assert_receive {:controlled_prompt, "a", "first", a1}, 2_000
        assert_receive {:controlled_prompt, "b", "first", b1}, 2_000
        {:ok, second} = Ensemble.tell(name, "second")

        send(a1, {:result, unquote(trigger)})
        send(b1, {:result, "x"})
        assert {:error, reason} = await_poll(name, first)
        assert reason == unquote(Macro.escape(expected))
        refute_leak(reason)
        assert Process.alive?(pid)

        assert_receive {:controlled_prompt, "a", "second", a2}, 2_000
        assert_receive {:controlled_prompt, "b", "second", b2}, 2_000
        send(a2, {:result, "ok"})
        send(b2, {:result, "ok"})
        assert {:ok, :completed, response} = await_poll(name, second)
        assert response.text == "synthesized"
      end
    end
  end

  describe "Debate" do
    defp start_debate(name, extra) do
      Ensemble.start_link(
        name: name,
        strategy: Debate,
        opts: Keyword.merge([agents: [spec("a"), spec("b")]], extra)
      )
    end

    cases = [
      {"raise", {:strategy_function_failed, :converge, :error, RuntimeError}},
      {"throw", {:strategy_function_failed, :converge, :throw, :other}},
      {"exit", {:strategy_function_failed, :converge, :exit, :other}}
    ]

    for {trigger, expected} <- cases do
      test "converge #{trigger} fails the token and runs the queue", %{name: name} do
        converge = fn
          "raise" -> raise "secret-payload"
          "throw" -> throw({:secret, "payload"})
          "exit" -> exit({:secret, "payload"})
          text -> text == "agreed"
        end

        {:ok, pid} = start_debate(name, converge: converge)
        {:ok, first} = Ensemble.tell(name, "first")
        assert_receive {:controlled_prompt, "a", "first", a1}, 2_000
        {:ok, second} = Ensemble.tell(name, "second")

        send(a1, {:result, "opening"})
        assert_receive {:controlled_prompt, "b", "first" <> _, b1}, 2_000
        send(b1, {:result, unquote(trigger)})

        assert {:error, reason} = await_poll(name, first)
        assert reason == unquote(Macro.escape(expected))
        refute_leak(reason)
        assert Process.alive?(pid)

        assert_receive {:controlled_prompt, "a", "second", a2}, 2_000
        send(a2, {:result, "opening"})
        assert_receive {:controlled_prompt, "b", "second" <> _, b2}, 2_000
        send(b2, {:result, "agreed"})
        assert {:ok, :completed, response} = await_poll(name, second)
        assert response.text =~ "b:\nagreed"
      end
    end

    test "a non-boolean converge return means not converged", %{name: name} do
      {:ok, _} = start_debate(name, rounds: 3, converge: fn _ -> :truthy end)
      {:ok, token} = Ensemble.tell(name, "q")

      assert_receive {:controlled_prompt, "a", "q", a1}, 2_000
      send(a1, {:result, "one"})
      assert_receive {:controlled_prompt, "b", "q" <> _, b1}, 2_000
      send(b1, {:result, "two"})

      # Still debating: the truthy atom did not end the debate at turn 2.
      assert_receive {:controlled_prompt, "a", _, a2}, 2_000
      send(a2, {:result, "three"})
      assert {:ok, :completed, response} = await_poll(name, token)
      assert response.text =~ "a:\nthree"
    end

    synth_cases = [
      {"boom", {:strategy_function_failed, :synthesizer_reply, :error, RuntimeError}},
      {"bad", {:invalid_strategy_result, :synthesizer_reply}}
    ]

    for {trigger, expected} <- synth_cases do
      test "{:synthesize, fun} #{trigger} fails the token and runs the queue", %{name: name} do
        synth = fn
          [{_, "boom"} | _] -> raise "secret-payload"
          [{_, "bad"} | _] -> 42
          transcript -> "turns=#{length(transcript)}"
        end

        {:ok, pid} = start_debate(name, rounds: 2, reply: {:synthesize, synth})
        {:ok, first} = Ensemble.tell(name, "first")
        assert_receive {:controlled_prompt, "a", "first", a1}, 2_000
        {:ok, second} = Ensemble.tell(name, "second")

        send(a1, {:result, unquote(trigger)})
        assert_receive {:controlled_prompt, "b", "first" <> _, b1}, 2_000
        send(b1, {:result, "x"})

        assert {:error, reason} = await_poll(name, first)
        assert reason == unquote(Macro.escape(expected))
        refute_leak(reason)
        assert Process.alive?(pid)

        assert_receive {:controlled_prompt, "a", "second", a2}, 2_000
        send(a2, {:result, "ok"})
        assert_receive {:controlled_prompt, "b", "second" <> _, b2}, 2_000
        send(b2, {:result, "ok"})
        assert {:ok, :completed, response} = await_poll(name, second)
        assert response.text == "turns=2"
      end
    end
  end

  describe "Supervisor" do
    defp decompose("raise"), do: raise("secret-payload")
    defp decompose("throw"), do: throw({:secret, "payload"})
    defp decompose("exit"), do: exit({:secret, "payload"})
    defp decompose("not-a-list"), do: :nope
    defp decompose("bad-element"), do: ["ok", 1]
    defp decompose("improper-list"), do: ["ok" | :tail]
    defp decompose(text), do: String.split(text, "\n", trim: true)

    defp start_supervisor(name, extra) do
      Ensemble.start_link(
        name: name,
        strategy: SupStrat,
        opts:
          Keyword.merge(
            [
              coordinator: spec("coordinator"),
              worker_template: spec("worker"),
              decomposer: &decompose/1
            ],
            extra
          )
      )
    end

    cases = [
      {"raise", {:strategy_function_failed, :decomposer, :error, RuntimeError}},
      {"throw", {:strategy_function_failed, :decomposer, :throw, :other}},
      {"exit", {:strategy_function_failed, :decomposer, :exit, :other}},
      {"not-a-list", {:invalid_strategy_result, :decomposer}},
      {"bad-element", {:invalid_strategy_result, :decomposer}},
      {"improper-list", {:invalid_strategy_result, :decomposer}}
    ]

    for {trigger, expected} <- cases do
      test "decomposer #{trigger} fails the run before any worker starts", %{name: name} do
        {:ok, pid} = start_supervisor(name, [])
        {:ok, first} = Ensemble.tell(name, "first")
        assert_receive {:controlled_prompt, "coordinator", "first", c1}, 2_000
        {:ok, second} = Ensemble.tell(name, "second")

        send(c1, {:result, unquote(trigger)})
        assert {:error, reason} = await_poll(name, first)
        assert reason == unquote(Macro.escape(expected))
        refute_leak(reason)
        assert Process.alive?(pid)
        refute_received {:controlled_prompt, "worker", _, _}
        await_agents(name, ["coordinator"])

        assert_receive {:controlled_prompt, "coordinator", "second", c2}, 2_000
        send(c2, {:result, "one"})
        assert_receive {:controlled_prompt, "worker", "one", w1}, 2_000
        send(w1, {:result, "DONE"})
        assert {:ok, :completed, response} = await_poll(name, second)
        assert response.text == "### one\n\nDONE"
      end
    end

    synth_cases = [
      {"boom", {:strategy_function_failed, :synthesizer, :error, RuntimeError}},
      {"bad", {:invalid_strategy_result, :synthesizer}}
    ]

    for arity <- [1, 2], {trigger, expected} <- synth_cases do
      test "arity-#{arity} synthesizer #{trigger} fails the run, stops workers and runs the queue",
           %{name: name} do
        synth =
          case unquote(arity) do
            1 ->
              fn
                [{_, "boom"} | _] -> raise "secret-payload"
                [{_, "bad"} | _] -> :not_binary
                outputs -> inspect(outputs)
              end

            2 ->
              fn
                [{_, "boom"} | _], _subtasks -> raise "secret-payload"
                [{_, "bad"} | _], _subtasks -> :not_binary
                outputs, _subtasks -> inspect(outputs)
              end
          end

        {:ok, pid} = start_supervisor(name, synthesizer: synth)
        {:ok, first} = Ensemble.tell(name, "first")
        assert_receive {:controlled_prompt, "coordinator", "first", c1}, 2_000
        {:ok, second} = Ensemble.tell(name, "second")

        send(c1, {:result, "one\ntwo"})
        assert_receive {:controlled_prompt, "worker", "one", w1}, 2_000
        assert_receive {:controlled_prompt, "worker", "two", w2}, 2_000
        send(w1, {:result, unquote(trigger)})
        send(w2, {:result, "TWO"})

        assert {:error, reason} = await_poll(name, first)
        assert reason == unquote(Macro.escape(expected))
        refute_leak(reason)
        assert Process.alive?(pid)
        await_agents(name, ["coordinator"])

        assert_receive {:controlled_prompt, "coordinator", "second", c2}, 2_000
        send(c2, {:result, "three"})
        assert_receive {:controlled_prompt, "worker", "three", w3}, 2_000
        send(w3, {:result, "THREE"})
        assert {:ok, :completed, response} = await_poll(name, second)
        assert response.text =~ "THREE"
      end
    end

    test "the built-in default synthesizer is not guarded, so corrupted state propagates" do
      opts = [
        coordinator: spec("coordinator"),
        worker_template: spec("worker"),
        decomposer: &decompose/1
      ]

      {:ok, state, _} = SupStrat.init(opts)
      corrupted = %{state | phase: {:fanning_out, "t", %{"worker-1" => :pending}}, subtasks: nil}
      response = %GenAgent.Response{text: "x"}

      assert_raise Protocol.UndefinedError, fn ->
        SupStrat.handle_response("worker-1", response, corrupted)
      end
    end

    test "a failed synthesis replies before worker cleanup, and cleanup precedes the queue",
         %{name: name} do
      synth = fn
        [{_, "did first"}] -> raise "secret-payload"
        outputs -> inspect(outputs)
      end

      worker =
        {"#{name}-w", BlockingWorker,
         [
           backend: Mock,
           observer: self(),
           scripts: [fn prompt -> [Event.new(:result, %{text: "did #{prompt}"})] end]
         ]}

      {:ok, _} =
        start_supervisor(name,
          worker_template: worker,
          decomposer: &String.split(&1, "\n", trim: true),
          synthesizer: synth
        )

      task = Task.async(fn -> Ensemble.ask(name, "q1", timeout: 5_000) end)
      assert_receive {:controlled_prompt, "coordinator", "q1", c1}, 2_000
      {:ok, second} = Ensemble.tell(name, "q2")
      send(c1, {:result, "first"})

      # The worker's terminate_agent stays blocked, so this error reply can
      # only arrive if it was emitted before the stop op.
      reply = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)

      assert {:ok, {:error, {:strategy_function_failed, :synthesizer, :error, RuntimeError}}} =
               reply

      assert_receive {:worker_stopping, worker_pid, :shutdown}, 2_000

      # Cleanup finishes before the queued run is dispatched.
      refute_receive {:controlled_prompt, "coordinator", "q2", _}, 100
      send(worker_pid, :release_worker)
      assert_receive {:controlled_prompt, "coordinator", "q2", c2}, 2_000

      send(c2, {:result, "other"})
      assert {:ok, :completed, response} = await_poll(name, second)
      assert response.text =~ "did other"

      assert_receive {:worker_stopping, worker_pid2, :shutdown}, 2_000
      send(worker_pid2, :release_worker)
    end
  end
end
