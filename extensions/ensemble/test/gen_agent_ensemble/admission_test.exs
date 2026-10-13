defmodule GenAgentEnsemble.AdmissionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GenAgent.Response
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.{Consensus, Debate, Pipeline, Pool, Solo, Switchboard}
  alias GenAgentEnsemble.Strategies.Supervisor, as: Fanout

  @default_bytes 1_048_576
  @kinds [:solo, :switchboard, :pool, :pipeline, :supervisor, :debate, :consensus]
  # Strategies that hold waiting requests in their own Queue.
  @queueing [:pool, :pipeline, :supervisor, :debate, :consensus]

  # Admits every request and holds it. Tokens are closed from outside through
  # notify/2 (which runs the given ops), through `ops:` in the call options, or
  # by cancellation. `:token` inside an op is replaced by the request's token.
  defmodule HoldStrategy do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(opts) do
      observer = Keyword.fetch!(opts, :observer)
      send(observer, :strategy_init)
      {:ok, %{observer: observer}, []}
    end

    @impl true
    def handle_tell(prompt, opts, token, state), do: admit(:tell, prompt, opts, token, state)

    @impl true
    def handle_ask(prompt, opts, token, state), do: admit(:ask, prompt, opts, token, state)

    @impl true
    def handle_response(_agent, _response, state), do: {:ok, [], state}

    @impl true
    def handle_cancel(_token, state), do: {:ok, [], state}

    @impl true
    def handle_notify(ops, state) when is_list(ops), do: {:ok, ops, state}

    # Tries to replace both a newer key and an older one.
    @impl true
    def handle_status(_state), do: %{admission: :from_strategy, session: :overridden}

    defp admit(kind, prompt, opts, token, state) do
      send(state.observer, {:strategy_called, kind, token, prompt})
      ops = opts |> Keyword.get(:ops, []) |> Enum.map(&bind(&1, token))
      {:ok, ops, state}
    end

    defp bind(op, token) do
      op
      |> Tuple.to_list()
      |> Enum.map(fn
        :token -> token
        other -> other
      end)
      |> List.to_tuple()
    end
  end

  # --- helpers ---

  defp size(term), do: :erlang.external_size(term)

  defp spec(tag),
    do: {tag, ControlledAgent, [backend: ControlledBackend, observer: self(), tag: tag]}

  defp start(strategy, opts, session_opts \\ []) do
    name = "admission-#{System.unique_integer([:positive])}"
    {:ok, pid} = E.start_link([name: name, strategy: strategy, opts: opts] ++ session_opts)

    on_exit(fn ->
      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    {name, pid}
  end

  defp hold(session_opts \\ []), do: start(HoldStrategy, [observer: self()], session_opts)

  defp admission(name) do
    {:ok, %{admission: admission}} = E.status(name)
    admission
  end

  defp counters(name), do: Map.take(admission(name), [:pending_count, :pending_bytes])

  defp zero, do: %{pending_count: 0, pending_bytes: 0}

  defp total(prompts), do: prompts |> Enum.map(&size/1) |> Enum.sum()

  defp overloaded(limit, count, bytes, incoming, max_count, max_bytes) do
    {:error,
     {:overloaded,
      %{
        queue: :ensemble_prompts,
        limit: limit,
        pending_count: count,
        pending_bytes: bytes,
        incoming_bytes: incoming,
        max_count: max_count,
        max_bytes: max_bytes
      }}}
  end

  defp watch(events) do
    id = "admission-test-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        id,
        events,
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp tell_all(name, prompts, route) do
    for prompt <- prompts do
      {:ok, token} = E.tell_with_completion(name, prompt, self(), route)
      token
    end
  end

  # An accepted ask blocks, so it runs in its own process and reports back.
  defp ask_async(name, prompt, route) do
    parent = self()
    spawn(fn -> send(parent, {:ask_result, prompt, E.ask(name, prompt, route)}) end)
  end

  # Answers every backend prompt with `answer` until each wanted request has
  # produced its terminal result. Waits are bounded by the receive timeout.
  defp serve(wanted, answer, done \\ [], prompts \\ []) do
    if length(done) == length(wanted) do
      assert MapSet.new(Enum.map(done, &elem(&1, 0))) == MapSet.new(wanted)
      {Enum.reverse(done), Enum.reverse(prompts)}
    else
      receive do
        {:controlled_prompt, _tag, prompt, task} ->
          send(task, answer)
          serve(wanted, answer, done, [prompt | prompts])

        {:gen_agent_ensemble, :completion, _name, token, result} ->
          assert token in wanted
          serve(wanted, answer, [{token, result} | done], prompts)

        {:ask_result, prompt, result} ->
          assert {:ask, prompt} in wanted
          serve(wanted, answer, [{{:ask, prompt}, result} | done], prompts)
      after
        5_000 -> flunk("requests did not finish; done: #{inspect(done)}")
      end
    end
  end

  defp refs(pid, token) do
    for {ref, {agent, ^token}} <- :sys.get_state(pid).in_flight, do: {ref, agent}
  end

  # Child completions that arrive after the request was closed.
  defp late(pid, name, refs) do
    for {ref, agent} <- refs do
      completed = {:ok, %Response{text: "late"}}
      send(pid, {:gen_agent, :completion, "#{name}/#{agent}", ref, completed})
      send(pid, {:gen_agent, :completion, "#{name}/#{agent}", ref, {:error, :interrupted}})
    end

    :sys.get_state(pid)
  end

  # --- option validation, defaults, limits ---

  test "invalid limits fail before strategy init or tree startup" do
    for key <- [:max_pending_prompts, :max_pending_prompt_bytes],
        bad <- [-1, 1.5, "10", nil, :unbounded, [1]] do
      name = "admission-invalid-#{System.unique_integer([:positive])}"
      opts = [name: name, strategy: HoldStrategy, opts: [observer: self()]] ++ [{key, bad}]

      assert E.start_link(opts) == {:error, {:invalid_option, key, bad}}
      refute name in E.list()
    end

    refute_receive :strategy_init, 0
  end

  test "defaults are 1000 outstanding requests and 1 MiB of serialized prompts" do
    {name, _} = hold()

    assert admission(name) == %{
             scope: :outstanding,
             pending_count: 0,
             pending_bytes: 0,
             max_pending_prompts: 1_000,
             max_pending_prompt_bytes: @default_bytes
           }

    for _ <- 1..1_000, do: assert({:ok, _} = E.tell(name, "x"))

    assert E.tell(name, "x") ==
             overloaded(:count, 1_000, 1_000 * size("x"), size("x"), 1_000, @default_bytes)

    exact = String.duplicate("x", @default_bytes - size(""))
    assert size(exact) == @default_bytes

    {name, _} = hold()
    assert {:ok, _} = E.tell(name, exact)

    assert E.tell(name, "") ==
             overloaded(:bytes, 1, @default_bytes, size(""), 1_000, @default_bytes)

    {name, _} = hold()
    over = exact <> "x"

    assert E.ask(name, over, timeout: 1_000) ==
             overloaded(:bytes, 0, 0, size(over), 1_000, @default_bytes)
  end

  test "zero limits reject every new admission, including an idle session and an empty prompt" do
    for {limits, limit} <- [
          {[max_pending_prompts: 0], :count},
          {[max_pending_prompt_bytes: 0], :bytes}
        ] do
      {name, pid} = hold(limits)
      before = :sys.get_state(pid)
      max_count = Keyword.get(limits, :max_pending_prompts, 1_000)
      max_bytes = Keyword.get(limits, :max_pending_prompt_bytes, @default_bytes)
      expected = overloaded(limit, 0, 0, size(""), max_count, max_bytes)

      assert E.tell(name, "") == expected
      assert E.ask(name, "", timeout: 1_000) == expected
      assert E.tell_with_completion(name, "", self(), stream_to: self()) == expected
      assert :sys.get_state(pid) == before
      refute_receive {:strategy_called, _, _, _}, 0
    end

    {name, _} = hold(max_pending_prompts: 0, max_pending_prompt_bytes: 0)
    assert E.tell(name, "x") == overloaded(:count, 0, 0, size("x"), 0, 0)
  end

  test "bytes admit an exact fit, reject beyond it, and lose to the count limit" do
    {first, second} = {"first", "second"}
    limit = size(first) + size(second)
    {name, _} = hold(max_pending_prompt_bytes: limit)

    assert {:ok, _} = E.tell(name, first)
    assert {:ok, _} = E.tell(name, second)
    assert counters(name) == %{pending_count: 2, pending_bytes: limit}

    assert E.tell(name, "") == overloaded(:bytes, 2, limit, size(""), 1_000, limit)

    # A single prompt larger than the whole budget is refused on an idle session.
    {name, _} = hold(max_pending_prompt_bytes: size(first))
    oversize = first <> "!"
    assert E.tell(name, oversize) == overloaded(:bytes, 0, 0, size(oversize), 1_000, size(first))
    assert {:ok, _} = E.tell(name, first)

    # When both limits are exceeded the count is reported.
    {name, _} = hold(max_pending_prompts: 1, max_pending_prompt_bytes: size(first))
    assert {:ok, _} = E.tell(name, first)

    assert E.tell(name, "longer than what remains") ==
             overloaded(:count, 1, size(first), size("longer than what remains"), 1, size(first))
  end

  test "the two limits are independent and :infinity disables only its own" do
    big = String.duplicate("x", @default_bytes)

    {name, _} = hold(max_pending_prompts: 2, max_pending_prompt_bytes: :infinity)
    assert {:ok, _} = E.tell(name, big)
    assert {:ok, _} = E.tell(name, big)
    assert E.tell(name, big) == overloaded(:count, 2, 2 * size(big), size(big), 2, :infinity)

    assert %{max_pending_prompts: 2, max_pending_prompt_bytes: :infinity} = admission(name)

    one = size("p")
    {name, _} = hold(max_pending_prompts: :infinity, max_pending_prompt_bytes: 3 * one)
    for _ <- 1..3, do: assert({:ok, _} = E.tell(name, "p"))
    assert E.tell(name, "p") == overloaded(:bytes, 3, 3 * one, one, :infinity, 3 * one)

    {name, _} = hold(max_pending_prompts: :infinity, max_pending_prompt_bytes: :infinity)
    for _ <- 1..3, do: assert({:ok, _} = E.tell(name, big))
    assert counters(name) == %{pending_count: 3, pending_bytes: 3 * size(big)}
  end

  test "concurrent callers get exactly the admissions that fit" do
    {name, _} = hold(max_pending_prompts: 5)
    parent = self()
    callers = 25

    for n <- 1..callers do
      spawn(fn ->
        result =
          if rem(n, 2) == 0,
            do: E.tell(name, "p#{n}"),
            else: E.ask(name, "p#{n}", timeout: :infinity)

        send(parent, {:caller, n, result})
      end)
    end

    # Accepted asks never reply; every other caller is answered. Twenty
    # rejections plus five strategy calls account for all twenty-five callers.
    for _ <- 1..(callers - 5) do
      assert_receive {:caller, _, {:error, {:overloaded, %{limit: :count, max_count: 5}}}}, 5_000
    end

    for _ <- 1..5, do: assert_receive({:strategy_called, _, _, _}, 5_000)
    refute_receive {:strategy_called, _, _, _}, 0
    refute_receive {:caller, _, {:error, _}}, 0
    assert %{pending_count: 5} = admission(name)

    prompt = "same-size"
    limit = 5 * size(prompt)
    {name, _} = hold(max_pending_prompt_bytes: limit)

    results =
      1..callers
      |> Task.async_stream(fn _ -> E.tell(name, prompt) end, max_concurrency: callers)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 5

    assert Enum.filter(results, &match?({:error, _}, &1)) ==
             List.duplicate(overloaded(:bytes, 5, limit, size(prompt), 1_000, limit), 20)

    assert counters(name) == %{pending_count: 5, pending_bytes: limit}
  end

  test "status reports the authoritative admission map after the strategy's own fields" do
    {name, _} = hold(max_pending_prompts: 4, max_pending_prompt_bytes: 5_000)
    {:ok, _} = E.tell(name, "alpha")
    ask_async(name, "beta", [])
    assert_receive {:strategy_called, :ask, _, "beta"}, 5_000

    assert {:ok, status} = E.status(name)

    assert status.admission == %{
             scope: :outstanding,
             pending_count: 2,
             pending_bytes: total(["alpha", "beta"]),
             max_pending_prompts: 4,
             max_pending_prompt_bytes: 5_000
           }

    assert status.session == :overridden
    assert status.strategy == HoldStrategy
    assert length(status.pending_tokens) == 2
  end

  # --- all built-in strategies ---

  defp config(:solo), do: {Solo, [agent: spec("w")], []}

  defp config(:switchboard),
    do: {Switchboard, [agents: [spec("w"), spec("x")]], [agent: "w"]}

  defp config(:pool), do: {Pool, [worker_count: 1, worker_template: spec("w")], []}
  defp config(:pipeline), do: {Pipeline, [stages: [spec("a"), spec("b")]], []}

  defp config(:supervisor) do
    {Fanout,
     [coordinator: spec("c"), worker_template: spec("w"), decomposer: fn _ -> ["part"] end], []}
  end

  defp config(:debate), do: {Debate, [agents: [spec("a"), spec("b")], rounds: 3], []}

  defp config(:consensus) do
    parser = fn text -> {:ok, :yes, text} end
    {Consensus, [agents: [spec("a"), spec("b")], rounds: 1, verdict_parser: parser], []}
  end

  for kind <- @kinds do
    test "#{kind}: active and waiting requests share one limit, and capacity returns on success, error and cancellation" do
      run_matrix(unquote(kind))
    end
  end

  defp run_matrix(kind) do
    {strategy, opts, route} = config(kind)
    {name, pid} = start(strategy, opts, max_pending_prompts: 3)
    watch([[:gen_agent_ensemble, :token, :start]])

    # Success: one active and two waiting requests fill the session.
    prompts = ["one", "two", "three"]
    tokens = tell_all(name, prompts, route)
    assert counters(name) == %{pending_count: 3, pending_bytes: total(prompts)}
    if kind in @queueing, do: assert({:ok, %{queued: 2}} = E.status(name))

    # Every public form is refused without a trace.
    before = :sys.get_state(pid)
    full = fn incoming -> overloaded(:count, 3, total(prompts), incoming, 3, @default_bytes) end

    assert E.tell(name, "rejected-tell", route) == full.(size("rejected-tell"))
    assert E.ask(name, "rejected-ask", route) == full.(size("rejected-ask"))

    assert E.tell_with_completion(name, "rejected-plain", self(), route) ==
             full.(size("rejected-plain"))

    streamed = route ++ [stream_to: self()]

    assert E.tell_with_completion(name, "rejected-stream", self(), streamed) ==
             full.(size("rejected-stream"))

    assert :sys.get_state(pid) == before
    refute_receive {:gen_agent_ensemble, _, _, _, _}, 0

    {done, seen} = serve(tokens, {:result, "ok"})
    assert Enum.map(done, &elem(&1, 0)) == tokens
    assert Enum.all?(done, &match?({_, {:ok, %Response{}}}, &1))
    refute Enum.any?(seen, &String.contains?(&1, "rejected"))
    assert counters(name) == zero()

    # Error: the same capacity is available again, and ask counts too.
    error_prompts = ["err-one", "err-two", "err-ask"]
    [e1, e2] = tell_all(name, Enum.take(error_prompts, 2), route)
    ask_async(name, "err-ask", route)

    assert_receive {:telemetry, [:gen_agent_ensemble, :token, :start], _,
                    %{session: ^name, kind: :ask}}

    assert counters(name) == %{pending_count: 3, pending_bytes: total(error_prompts)}
    assert {:error, {:overloaded, %{limit: :count}}} = E.tell(name, "rejected-after-ask", route)

    {done, seen} = serve([e1, e2, {:ask, "err-ask"}], {:error, :boom})
    assert Enum.all?(done, &match?({_, {:error, _}}, &1))
    refute Enum.any?(seen, &String.contains?(&1, "rejected"))
    assert counters(name) == zero()

    # Cancellation: a queued cancel frees capacity at once, an active cancel
    # frees it and lets the survivors run in order.
    [c1, c2, c3] = tell_all(name, ["c-one", "c-two", "c-three"], route)
    assert {:ok, _} = E.cancel(name, c2)
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^c2, {:error, :cancelled}}
    assert counters(name) == %{pending_count: 2, pending_bytes: total(["c-one", "c-three"])}

    [c4] = tell_all(name, ["c-four"], route)

    assert {:error, {:overloaded, %{limit: :count}}} =
             E.tell(name, "rejected-after-cancel", route)

    assert {:ok, _} = E.cancel(name, c1)
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^c1, {:error, :cancelled}}
    assert counters(name) == %{pending_count: 2, pending_bytes: total(["c-three", "c-four"])}

    {done, _} = serve([c3, c4], {:result, "ok"})
    assert Enum.map(done, &elem(&1, 0)) == [c3, c4]
    assert counters(name) == zero()
  end

  # --- no side effects on rejection ---

  test "a rejected request reaches no strategy callback and registers nothing" do
    sentinel = "PROMPT-SENTINEL-1234"
    {name, pid} = hold(max_pending_prompts: 1)

    {:ok, held} = E.tell_with_completion(name, sentinel, self(), [])
    assert_receive {:strategy_called, :tell, ^held, ^sentinel}

    before = :sys.get_state(pid)
    # The accepted request keeps a numeric charge, not its prompt.
    refute inspect(before.token_contexts) =~ "SENTINEL"

    assert {:error, {:overloaded, _}} = E.tell(name, "rejected-1")
    assert {:error, {:overloaded, _}} = E.ask(name, "rejected-2", timeout: 1_000)

    assert {:error, {:overloaded, _}} =
             E.tell_with_completion(name, "rejected-3", self(), stream_to: self())

    assert :sys.get_state(pid) == before
    refute_receive {:strategy_called, _, _, _}, 0
    refute_receive {:gen_agent_ensemble, _, _, _, _}, 0
    assert {:ok, %{pending_tokens: [^held]}} = E.status(name)
  end

  # --- release paths ---

  test "each terminal route releases a charge once; duplicate, unknown and late replies subtract nothing" do
    {name, _} = hold()
    [a, b, c, d] = tell_all(name, ["alpha", "beta", "gamma", "delta"], [])
    ok = %Response{text: "r"}

    E.notify(name, [{:reply, a, ok}])
    assert counters(name) == %{pending_count: 3, pending_bytes: total(["beta", "gamma", "delta"])}

    log =
      capture_log(fn ->
        E.notify(name, [{:reply, a, ok}, {:reply_error, a, :late}, {:reply, "tok-unknown", ok}])

        assert counters(name) ==
                 %{pending_count: 3, pending_bytes: total(["beta", "gamma", "delta"])}
      end)

    # The duplicate and unknown replies reached the server and were refused.
    assert log =~ "failed"

    E.notify(name, [{:reply_error, b, :boom}])
    assert counters(name) == %{pending_count: 2, pending_bytes: total(["gamma", "delta"])}

    assert {:ok, :cancelled} = E.cancel(name, c)
    assert counters(name) == %{pending_count: 1, pending_bytes: total(["delta"])}
    assert {:error, :already_finished} = E.cancel(name, c)
    assert counters(name) == %{pending_count: 1, pending_bytes: total(["delta"])}

    E.notify(name, [{:reply, d, ok}])
    assert counters(name) == zero()

    capture_log(fn ->
      E.notify(name, [{:reply, d, ok}, {:reply_error, c, :late}])
      assert counters(name) == zero()
    end)
  end

  test "routing errors, dispatch rejections and immediate replies release at once" do
    {name, _} = hold(max_pending_prompts: 1)

    capture_log(fn ->
      for n <- 1..3 do
        assert {:error, {:dispatch_rejected, "missing", _}} =
                 E.ask(name, "route-#{n}", ops: [{:dispatch, "missing", "x", :token}])

        assert counters(name) == zero()
      end
    end)

    for n <- 1..3 do
      assert {:ok, %Response{text: "now"}} =
               E.ask(name, "now-#{n}", ops: [{:reply, :token, %Response{text: "now"}}])

      assert {:error, :denied} = E.ask(name, "deny-#{n}", ops: [{:reply_error, :token, :denied}])
    end

    assert counters(name) == zero()
  end

  test "Switchboard routing errors release capacity for the next request" do
    {name, _} = start(Switchboard, [agents: [spec("w")]], max_pending_prompts: 1)

    for _ <- 1..3 do
      assert E.ask(name, "p") == {:error, :no_agent_specified}
      assert E.ask(name, "p", agent: "zzz") == {:error, {:unknown_agent, "zzz"}}
      {:ok, token} = E.tell(name, "p")
      assert E.poll(name, token) == {:error, :no_agent_specified}
    end

    assert counters(name) == zero()
  end

  test "a child's own overload closes the token and returns its charge" do
    agent =
      {"w", ControlledAgent,
       [backend: ControlledBackend, observer: self(), tag: "w", max_pending_prompts: 0]}

    {name, _} = start(Solo, [agent: agent], max_pending_prompts: 3)
    {:ok, first} = E.tell_with_completion(name, "first")
    {:ok, second} = E.tell_with_completion(name, "second")

    # The child's rejection names its own queue, not the Ensemble's.
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^second,
                    {:error, {:overloaded, %{queue: :prompts}}}}

    assert counters(name) == %{pending_count: 1, pending_bytes: size("first")}

    assert_receive {:controlled_prompt, "w", "first", task}
    send(task, {:result, "ok"})
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^first, {:ok, %Response{}}}
    assert counters(name) == zero()
  end

  test "a halt closes every outstanding token exactly once" do
    {name, pid} = hold()
    watch([[:gen_agent_ensemble, :token, :error]])
    monitor = Process.monitor(pid)
    [t1, t2] = tell_all(name, ["held-1", "held-2"], [])

    assert E.ask(name, "halting", ops: [{:halt, :planned}]) == {:error, {:halted, :planned}}

    for token <- [t1, t2] do
      assert_receive {:gen_agent_ensemble, :completion, ^name, ^token,
                      {:error, {:halted, :planned}}}
    end

    assert_receive {:DOWN, ^monitor, :process, ^pid, _}

    for _ <- 1..3 do
      assert_receive {:telemetry, [:gen_agent_ensemble, :token, :error], _,
                      %{session: ^name, reason_kind: :halted}}
    end

    # Nothing was left open for the shutdown path to report.
    refute_receive {:telemetry, [:gen_agent_ensemble, :token, :error], _, %{session: ^name}}, 0
    refute_receive {:gen_agent_ensemble, :completion, ^name, _, _}, 0
  end

  test "an expired ask timeout leaves its request charged until the work finishes" do
    {name, _} = start(Solo, [agent: spec("w")], max_pending_prompts: 1)
    watch([[:gen_agent_ensemble, :token, :stop]])

    assert {:timeout, {GenServer, :call, _}} = catch_exit(E.ask(name, "slow", timeout: 10))
    assert counters(name) == %{pending_count: 1, pending_bytes: size("slow")}

    assert E.tell(name, "rejected") ==
             overloaded(:count, 1, size("slow"), size("rejected"), 1, @default_bytes)

    assert_receive {:controlled_prompt, "w", "slow", task}
    send(task, {:result, "late"})
    assert_receive {:telemetry, [:gen_agent_ensemble, :token, :stop], _, %{session: ^name}}
    assert counters(name) == zero()
    assert {:ok, _} = E.tell(name, "after")
  end

  test "completed-result retention is independent of capacity" do
    ok = %Response{text: "r"}

    for {retain, retained} <- [{0, 0}, {1, 1}, {:infinity, 6}] do
      {name, _} = hold(max_pending_prompts: 2, max_completed_results: retain)

      for n <- 1..5 do
        {:ok, token} = E.tell(name, "round-#{n}")
        E.notify(name, [{:reply, token, ok}])
        assert counters(name) == zero()
      end

      {:ok, held} = E.tell(name, "held")
      {:ok, done} = E.tell(name, "done")
      E.notify(name, [{:reply, done, ok}])
      expected = %{pending_count: 1, pending_bytes: size("held")}
      assert counters(name) == expected

      # Consuming retained results does not change what is outstanding.
      {:ok, entries} = E.inbox(name)
      assert length(entries) == retained
      assert counters(name) == expected
      assert E.poll(name, held) == {:ok, :pending}
      assert counters(name) == expected
    end
  end

  # --- cancellation ---

  test "queued and active cancellation return capacity once; late child results do not return it again" do
    {name, pid} = start(Solo, [agent: spec("w")], max_pending_prompts: 2)
    {:ok, active} = E.tell_with_completion(name, "active")
    assert_receive {:controlled_prompt, "w", "active", _}
    {:ok, queued} = E.tell_with_completion(name, "queued")
    old = refs(pid, active) ++ refs(pid, queued)
    assert counters(name) == %{pending_count: 2, pending_bytes: total(["active", "queued"])}

    assert E.cancel(name, queued) == {:ok, :cancelled}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^queued, {:error, :cancelled}}
    assert counters(name) == %{pending_count: 1, pending_bytes: size("active")}

    assert E.cancel(name, active) == {:ok, :cancelled}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^active, {:error, :cancelled}}
    assert counters(name) == zero()

    late(pid, name, old)
    assert counters(name) == zero()

    {:ok, next} = E.tell_with_completion(name, "next")
    next_charge = %{pending_count: 1, pending_bytes: size("next")}
    assert counters(name) == next_charge
    late(pid, name, old)
    assert counters(name) == next_charge

    assert_receive {:controlled_prompt, "w", "next", backend}
    send(backend, {:result, "ok"})
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^next, {:ok, %Response{}}}
    assert counters(name) == zero()
  end

  test "an unconfirmed cancellation still closes the token and returns its charge" do
    {name, pid} = start(Solo, [agent: spec("w")], max_pending_prompts: 1)
    {:ok, token} = E.tell_with_completion(name, "active")
    assert_receive {:controlled_prompt, "w", "active", backend}
    [{ref, agent}] = refs(pid, token)
    fake = make_ref()

    # Make the child unable to acknowledge the request being cancelled.
    :sys.replace_state(pid, fn state ->
      {context, contexts} = Map.pop(state.dispatch_contexts, ref)

      %{
        state
        | in_flight: %{fake => {agent, token}},
          dispatch_contexts: Map.put(contexts, fake, context)
      }
    end)

    assert counters(name) == %{pending_count: 1, pending_bytes: size("active")}
    assert E.cancel(name, token) == {:ok, :cancelled_unconfirmed}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:error, :cancelled}}
    assert counters(name) == zero()

    {:ok, next} = E.tell_with_completion(name, "next")
    send(backend, {:result, "late real result"})
    assert_receive {:controlled_prompt, "w", "next", next_backend}
    late(pid, name, [{fake, agent}, {ref, agent}])
    assert counters(name) == %{pending_count: 1, pending_bytes: size("next")}

    send(next_backend, {:result, "ok"})
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^next, {:ok, %Response{}}}
    assert counters(name) == zero()
  end

  # --- accounting stays on the original prompt ---

  test "Pipeline charges the original prompt once across its stages" do
    prompt = "pipe"
    queued = "next"
    generated = String.duplicate("g", 500)
    budget = total([prompt, queued])

    {name, _} =
      start(Pipeline, [stages: [spec("a"), spec("b"), spec("c")]],
        max_pending_prompts: 2,
        max_pending_prompt_bytes: budget
      )

    {:ok, first} = E.tell_with_completion(name, prompt)
    {:ok, second} = E.tell_with_completion(name, queued)
    held = %{pending_count: 2, pending_bytes: budget}
    assert counters(name) == held
    assert E.tell(name, "") == overloaded(:count, 2, budget, size(""), 2, budget)

    # Stage outputs far larger than the whole budget are never charged.
    assert_receive {:controlled_prompt, "a", ^prompt, a}
    send(a, {:result, generated})
    assert_receive {:controlled_prompt, "b", ^generated, b}
    assert counters(name) == held

    send(b, {:result, generated <> "!"})
    assert_receive {:controlled_prompt, "c", _, c}
    assert counters(name) == held

    send(c, {:result, "done"})

    assert_receive {:gen_agent_ensemble, :completion, ^name, ^first,
                    {:ok, %Response{text: "done"}}}

    assert counters(name) == %{pending_count: 1, pending_bytes: size(queued)}

    assert_receive {:controlled_prompt, "a", ^queued, a2}
    send(a2, {:result, "x"})
    assert_receive {:controlled_prompt, "b", "x", b2}
    send(b2, {:result, "y"})
    assert_receive {:controlled_prompt, "c", "y", c2}
    assert counters(name) == %{pending_count: 1, pending_bytes: size(queued)}

    send(c2, {:result, "done"})
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^second, {:ok, %Response{}}}
    assert counters(name) == zero()
  end

  test "Consensus charges the original prompt once across rounds and parallel fanout" do
    prompt = "decide"

    parser = fn text ->
      cond do
        String.starts_with?(text, "YES") -> {:ok, :yes, text}
        String.starts_with?(text, "NO") -> {:ok, :no, text}
        true -> :error
      end
    end

    opts = [
      agents: [spec("a"), spec("b")],
      threshold: :unanimous,
      rounds: 2,
      verdict_parser: parser
    ]

    {name, _} =
      start(Consensus, opts, max_pending_prompts: 1, max_pending_prompt_bytes: size(prompt))

    watch([[:gen_agent_ensemble, :dispatch, :stop]])
    {:ok, token} = E.tell_with_completion(name, prompt)
    held = %{pending_count: 1, pending_bytes: size(prompt)}

    assert_receive {:controlled_prompt, "a", ^prompt, a1}
    assert_receive {:controlled_prompt, "b", ^prompt, b1}
    assert counters(name) == held

    send(a1, {:result, "YES first"})
    assert_receive {:telemetry, [:gen_agent_ensemble, :dispatch, :stop], _, %{session: ^name}}
    assert counters(name) == held

    # Disagreement starts round two with longer generated prompts.
    send(b1, {:result, "NO first"})
    assert_receive {:controlled_prompt, "a", reprompt, a2}
    assert_receive {:controlled_prompt, "b", _, b2}
    assert size(reprompt) > size(prompt)
    assert counters(name) == held

    send(a2, {:result, "YES again"})
    send(b2, {:result, "YES again"})
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:ok, %Response{}}}
    assert counters(name) == zero()
  end

  test "Supervisor charges the original prompt once while it fans out" do
    prompt = "split"
    subs = for n <- 1..3, do: String.duplicate("sub#{n}-", 50)

    {name, _} =
      start(
        Fanout,
        [coordinator: spec("c"), worker_template: spec("w"), decomposer: fn _ -> subs end],
        max_pending_prompts: 1,
        max_pending_prompt_bytes: size(prompt)
      )

    watch([[:gen_agent_ensemble, :dispatch, :stop]])
    {:ok, token} = E.tell_with_completion(name, prompt)
    held = %{pending_count: 1, pending_bytes: size(prompt)}

    assert_receive {:controlled_prompt, "c", ^prompt, coordinator}
    assert counters(name) == held
    send(coordinator, {:result, "plan"})
    assert_receive {:telemetry, [:gen_agent_ensemble, :dispatch, :stop], _, %{agent: "c"}}

    [first, second, last] =
      for sub <- subs do
        assert_receive {:controlled_prompt, "w", ^sub, task}
        task
      end

    assert counters(name) == held

    for task <- [first, second] do
      send(task, {:result, "done"})
      assert_receive {:telemetry, [:gen_agent_ensemble, :dispatch, :stop], _, %{agent: "w-" <> _}}
      assert counters(name) == held
    end

    send(last, {:result, "done"})
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:ok, %Response{}}}
    assert counters(name) == zero()
  end

  # --- telemetry ---

  test "each rejection emits one payload-free admission event and no token or dispatch start" do
    secret = "SECRET-PROMPT"

    {name, _} = start(Solo, [agent: spec("w")], max_pending_prompts: 1)

    watch([
      [:gen_agent_ensemble, :admission, :rejected],
      [:gen_agent_ensemble, :token, :start],
      [:gen_agent_ensemble, :dispatch, :start]
    ])

    {:ok, _held} = E.tell(name, "held")
    assert_receive {:telemetry, [:gen_agent_ensemble, :token, :start], _, %{kind: :tell}}
    assert_receive {:telemetry, [:gen_agent_ensemble, :dispatch, :start], _, %{session: ^name}}

    assert {:error, {:overloaded, _}} = E.tell(name, secret, secret_option: "SECRET-OPTION")

    assert {:error, {:overloaded, _}} =
             E.ask(name, secret, secret_option: "SECRET-OPTION", timeout: 1_000)

    assert_receive {:telemetry, [:gen_agent_ensemble, :admission, :rejected], tell_measurements,
                    tell_metadata}

    assert_receive {:telemetry, [:gen_agent_ensemble, :admission, :rejected], ask_measurements,
                    ask_metadata}

    refute_receive {:telemetry, [:gen_agent_ensemble, :admission, :rejected], _, _}, 0

    measurements = %{
      pending_count: 1,
      pending_bytes: size("held"),
      incoming_bytes: size(secret)
    }

    assert tell_measurements == measurements
    assert ask_measurements == measurements

    metadata = %{
      session: name,
      strategy: Solo,
      outcome: :rejected,
      reason_kind: :overloaded,
      limit: :count,
      max_pending_prompts: 1,
      max_pending_prompt_bytes: @default_bytes
    }

    assert tell_metadata == Map.put(metadata, :kind, :tell)
    assert ask_metadata == Map.put(metadata, :kind, :ask)

    rendered = inspect({tell_measurements, tell_metadata, ask_measurements, ask_metadata})
    refute rendered =~ "SECRET"
    refute rendered =~ "tok-"

    # The rejected requests produced neither a token nor a dispatch.
    refute_receive {:telemetry, [:gen_agent_ensemble, :token, :start], _, _}, 0
    refute_receive {:telemetry, [:gen_agent_ensemble, :dispatch, :start], _, _}, 0
  end

  test "a bytes rejection reports its limit category" do
    {name, _} = hold(max_pending_prompt_bytes: size("held"))
    watch([[:gen_agent_ensemble, :admission, :rejected]])
    {:ok, _} = E.tell(name, "held")

    assert {:error, {:overloaded, %{limit: :bytes}}} = E.tell(name, "")

    assert_receive {:telemetry, [:gen_agent_ensemble, :admission, :rejected],
                    %{pending_count: 1, pending_bytes: bytes, incoming_bytes: incoming},
                    %{limit: :bytes, max_pending_prompts: 1_000, max_pending_prompt_bytes: max}}

    assert bytes == size("held")
    assert incoming == size("")
    assert max == size("held")
  end
end
