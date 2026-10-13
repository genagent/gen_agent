defmodule GenAgentEnsemble.CompletedResultsTest do
  use ExUnit.Case, async: false

  alias GenAgent.Response
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}

  # Responses are released by notify; the strategy retains no prompt history.
  defmodule GatedStrategy do
    @behaviour GenAgentEnsemble.Strategy
    @impl true
    def init(opts) do
      observer = Keyword.fetch!(opts, :observer)
      send(observer, :strategy_initialized)
      {:ok, observer, []}
    end

    @impl true
    def handle_tell(prompt, _opts, token, observer) do
      send(observer, {:accepted, prompt, token})
      {:ok, [], observer}
    end

    @impl true
    def handle_ask(prompt, opts, token, observer),
      do: handle_tell(prompt, opts, token, observer)

    @impl true
    def handle_response(_agent, _response, state), do: {:ok, [], state}
    @impl true
    def handle_notify(ops, state), do: {:ok, ops, state}
  end

  setup do
    name = "completed-results-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    %{name: name}
  end

  defp start(name, extra \\ []) do
    {:ok, pid} =
      E.start_link([name: name, strategy: GatedStrategy, opts: [observer: self()]] ++ extra)

    assert_receive :strategy_initialized
    pid
  end

  defp complete(name, token, result) do
    op =
      case result do
        {:ok, value} -> {:reply, token, value}
        {:error, reason} -> {:reply_error, token, reason}
      end

    E.notify(name, [op])
    # Same-sender call follows the release cast, without scheduling sleeps.
    E.status(name)
  end

  defp assert_cache(pid, tokens) do
    state = :sys.get_state(pid)
    assert :queue.to_list(state.completed_order) == tokens
    assert Enum.sort(Map.keys(state.completed)) == Enum.sort(tokens)
    state
  end

  defp finish_tells(name, count) do
    for n <- 1..count do
      {:ok, token} = E.tell(name, n)
      complete(name, token, {:ok, n})
      token
    end
  end

  # Observe await entering the mailbox, then inspect actual registration.
  defp waiter(pid, name, token) do
    task =
      Task.async(fn ->
        receive do
          :go -> E.await(name, token, :infinity)
        end
      end)

    :erlang.trace(task.pid, true, [:send])
    send(task.pid, :go)
    task_pid = task.pid

    assert_receive {:trace, ^task_pid, :send, {:"$gen_call", _, {:await, ^token, :infinity}},
                    ^pid}

    :erlang.trace(task.pid, false, [:send])
    state = :sys.get_state(pid)
    assert Enum.any?(state.waiters[token], fn {_, {from, _}} -> elem(from, 0) == task.pid end)
    task
  end

  test "invalid limits precede strategy initialization and owned tree startup", %{name: name} do
    for value <- [-1, 1.5, nil, true, "100", :unlimited] do
      assert {:error, {:invalid_option, :max_completed_results, ^value}} =
               E.start_link(
                 name: name,
                 strategy: GatedStrategy,
                 opts: [observer: self()],
                 max_completed_results: value
               )

      assert Registry.lookup(GenAgentEnsemble.Registry, name) == []
      assert Registry.lookup(GenAgentEnsemble.AgentTreeRegistry, name) == []
      refute_receive :strategy_initialized, 0
    end

    pid = start(name, max_completed_results: 0)
    assert :sys.get_state(pid).max_completed_results == 0
  end

  test "default retains only the latest 100 completed tells", %{name: name} do
    pid = start(name)
    assert :sys.get_state(pid).max_completed_results == 100
    tokens = finish_tells(name, 105)
    assert_cache(pid, Enum.drop(tokens, 5))

    for token <- Enum.take(tokens, 5) do
      assert E.poll(name, token) == {:error, :not_found}
      assert E.await(name, token, 0) == {:error, :not_found}
    end

    assert {:ok, entries} = E.inbox(name)
    assert length(entries) == 100
    assert_cache(pid, [])
  end

  test "explicit infinity retains more than the default bound", %{name: name} do
    pid = start(name, max_completed_results: :infinity)
    tokens = finish_tells(name, 110)
    assert_cache(pid, tokens)
    assert E.await(name, hd(tokens), 0) == {:ok, 1}
    assert {:ok, entries} = E.inbox(name)
    assert length(entries) == 110
    assert_cache(pid, [])
  end

  test "eviction follows completion rather than lexical or submission order", %{name: name} do
    pid = start(name, max_completed_results: 3)

    tokens =
      for n <- 1..12 do
        {:ok, token} = E.tell(name, n)
        assert E.poll(name, token) == {:ok, :pending}
        token
      end

    # Reverse lexical order fails lexical eviction regardless of digit widths.
    order = Enum.sort(tokens, :desc)
    for token <- order, do: complete(name, token, {:ok, token})
    retained = Enum.take(order, -3)
    assert_cache(pid, retained)

    for token <- Enum.drop(order, -3) do
      assert E.poll(name, token) == {:error, :not_found}
      assert E.await(name, token, 0) == {:error, :not_found}
    end

    for token <- retained, do: assert(E.await(name, token, 0) == {:ok, token})
    assert_cache(pid, retained)
  end

  test "poll removes order entries immediately and inbox resets eviction order", %{name: name} do
    pid = start(name, max_completed_results: 3)
    [oldest, middle, newest] = finish_tells(name, 3)
    assert E.poll(name, middle) == {:ok, :completed, 2}
    assert_cache(pid, [oldest, newest])
    # Retain older results while consuming many newer large response payloads.
    payload = String.duplicate("x", 10_000)

    for n <- 1..200 do
      {:ok, token} = E.tell(name, n)
      complete(name, token, {:ok, payload})
      assert_cache(pid, [oldest, newest, token])
      assert E.poll(name, token) == {:ok, :completed, payload}
      state = assert_cache(pid, [oldest, newest])
      assert state.completed == %{oldest => {:ok, 1}, newest => {:ok, 3}}
      assert E.await(name, token, 0) == {:error, :not_found}
    end

    assert {:ok, entries} = E.inbox(name)
    assert Map.new(entries) == %{oldest => {:ok, 1}, newest => {:ok, 3}}
    assert_cache(pid, [])
    fresh = finish_tells(name, 4)
    assert_cache(pid, tl(fresh))
    assert E.poll(name, hd(fresh)) == {:error, :not_found}
  end

  test "waiters and recipients receive results evicted within the same op batch", %{name: name} do
    pid = start(name, max_completed_results: 1)
    {:ok, first} = E.tell_with_completion(name, :first)
    {:ok, second} = E.tell_with_completion(name, :second)
    a = waiter(pid, name, first)
    b = waiter(pid, name, second)
    E.notify(name, [{:reply, first, :one}, {:reply, second, :two}])

    assert Task.await(a) == {:ok, :one}
    assert Task.await(b) == {:ok, :two}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^first, {:ok, :one}}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^second, {:ok, :two}}
    assert E.poll(name, first) == {:error, :not_found}
    assert E.await(name, first, 0) == {:error, :not_found}
    assert_cache(pid, [second])
    assert E.poll(name, second) == {:ok, :completed, :two}
    assert_cache(pid, [])
  end

  test "asks never cache results or evict retained tells", %{name: name} do
    pid = start(name, max_completed_results: 1)
    {:ok, tell} = E.tell(name, :tell)
    complete(name, tell, {:ok, :retained})

    for result <- [{:ok, :answer}, {:error, :boom}] do
      task = Task.async(fn -> E.ask(name, :ask) end)
      assert_receive {:accepted, :ask, token}
      complete(name, token, result)
      assert Task.await(task) == result
      assert_cache(pid, [tell])
      assert E.poll(name, token) == {:error, :not_found}
      assert E.await(name, token, 0) == {:error, :not_found}
    end
  end

  for limit <- [0, 1] do
    test "live success/error/cancel notify all waiters with limit #{limit}", %{name: name} do
      limit = unquote(limit)

      {:ok, pid} =
        E.start_link(
          name: name,
          strategy: GenAgentEnsemble.Strategies.Solo,
          max_completed_results: limit,
          opts: [
            agent: {"w", ControlledAgent, backend: ControlledBackend, observer: self(), tag: :w}
          ]
        )

      Enum.reduce([:success, :error, :cancel], nil, fn outcome, previous ->
        {:ok, token} = E.tell_with_completion(name, "go")
        assert_receive {:controlled_prompt, :w, "go", backend}
        a = waiter(pid, name, token)
        b = waiter(pid, name, token)

        case outcome do
          :success -> send(backend, {:result, "done"})
          :error -> send(backend, {:error, :boom})
          :cancel -> assert E.cancel(name, token) == {:ok, :cancelled}
        end

        assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, result}

        case outcome do
          :success -> assert {:ok, %Response{text: "done"}} = result
          :error -> assert result == {:error, :boom}
          :cancel -> assert result == {:error, :cancelled}
        end

        assert Task.await(a) == result
        assert Task.await(b) == result
        state = assert_cache(pid, if(limit == 0, do: [], else: [token]))
        assert state.waiters == %{}
        assert state.waiter_monitors == %{}
        assert state.pending == %{}
        assert state.token_contexts == %{}

        if previous do
          assert E.poll(name, previous) == {:error, :not_found}
          assert E.await(name, previous, 0) == {:error, :not_found}
        end

        if limit == 0 do
          assert E.poll(name, token) == {:error, :not_found}
          assert E.await(name, token, 0) == {:error, :not_found}
        else
          assert E.await(name, token, 0) == result
        end

        refute_receive {:gen_agent_ensemble, :completion, ^name, ^token, _}, 0
        token
      end)

      assert {:ok, entries} = E.inbox(name)
      assert length(entries) == limit
      assert_cache(pid, [])
    end
  end
end
