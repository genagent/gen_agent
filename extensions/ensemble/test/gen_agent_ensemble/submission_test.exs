defmodule GenAgentEnsemble.SubmissionTest do
  use ExUnit.Case, async: false
  alias GenAgentEnsemble, as: E

  defmodule HeldAgent do
    use GenAgent
    def init_agent(opts), do: {:ok, opts, %{observer: Keyword.fetch!(opts, :observer)}}

    def pre_turn(prompt, state) do
      send(state[:observer], {:held, self()})

      receive do
        :release -> {:ok, prompt, state}
      end
    end

    def handle_response(_, _, state), do: {:noreply, state}
  end

  defmodule UnscopedStrategy do
    @behaviour GenAgentEnsemble.Strategy
    def init(opts), do: {:ok, nil, [Keyword.fetch!(opts, :agent)]}

    def handle_tell(prompt, _opts, _token, state),
      do: {:ok, [{:dispatch, "worker", prompt}], state}

    def handle_ask(prompt, opts, token, state), do: handle_tell(prompt, opts, token, state)
    def handle_response(_agent, _response, state), do: {:ok, [], state}

    def handle_dispatch_rejected(_agent, token, _reason, state) when is_binary(token),
      do: {:ok, [], state}
  end

  defmodule FirstResponseStrategy do
    @behaviour GenAgentEnsemble.Strategy
    def init(opts),
      do: {:ok, %{observer: Keyword.fetch!(opts, :observer)}, [Keyword.fetch!(opts, :agent)]}

    def handle_tell(prompt, _opts, token, state),
      do:
        {:ok, List.duplicate({:dispatch, "worker", prompt, token}, 2),
         Map.put(state, :token, token)}

    def handle_ask(prompt, opts, token, state), do: handle_tell(prompt, opts, token, state)

    def handle_response(_agent, response, state),
      do: {:ok, [{:reply, state.token, response}], state}

    def handle_dispatch_rejected(_agent, token, reason, state) do
      send(state.observer, {:rejected_callback, token})
      {:ok, [{:reply_error, token, reason}], state}
    end
  end

  setup context do
    name = "submission-#{System.unique_integer([:positive])}"
    observer = self()
    handler = make_ref()

    :ok =
      :telemetry.attach_many(
        handler,
        for(
          event <- [:start, :stop, :error, :rejected],
          do: [:gen_agent_ensemble, :dispatch, event]
        ),
        fn event, _, meta, _ ->
          if meta.session == name do
            send(observer, {:dispatch, List.last(event), meta.ref})
            send(observer, {:dispatch_meta, List.last(event), meta})
          end
        end,
        nil
      )

    {:ok, server} =
      E.start_link(
        name: name,
        strategy:
          cond do
            context[:siblings] -> FirstResponseStrategy
            context[:unscoped] -> UnscopedStrategy
            true -> GenAgentEnsemble.Strategies.Solo
          end,
        opts: [
          observer: observer,
          agent:
            {"worker", HeldAgent,
             [observer: observer, backend: GenAgentEnsemble.ControlledBackend]}
        ]
      )

    {:ok, token} = E.tell(name, "held")
    assert_receive {:held, child}
    dispatch_token = if context[:unscoped], do: nil, else: token
    state = :sys.get_state(server)

    refs =
      Enum.sort_by(Map.keys(state.in_flight), &elem(Map.fetch!(state.dispatch_contexts, &1), 1))

    [ref | _] = refs
    assert Enum.all?(refs, &(Map.fetch!(state.in_flight, &1) == {"worker", dispatch_token}))

    on_exit(fn ->
      :telemetry.detach(handler)
      send(child, :release)

      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    %{name: name, server: server, token: token, ref: ref, refs: refs, child: child}
  end

  @tag :siblings
  test "late sibling rejection retires ref without calling back for a closed token", c do
    [first, second] = c.refs
    send(c.server, {:gen_agent, :completion, :ignored, first, {:ok, %{text: "done"}}})
    assert {:ok, %{text: "done"}} = E.await(c.name, c.token)
    refute Map.has_key?(:sys.get_state(c.server).pending, c.token)
    assert_receive {:dispatch, :start, ^first}
    assert_receive {:dispatch, :stop, ^first}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..2 do
          send(
            c.server,
            {:gen_agent, :admission, :ignored, second, {:error, {:overloaded, "secret"}}}
          )
        end

        assert {:ok, %{in_flight: 0}} = E.status(c.name)
      end)

    assert log =~ "failed: overloaded"
    refute log =~ "secret"
    refute log =~ "held"
    refute log =~ "unknown_token"
    refute_receive {:rejected_callback, _}
    state = :sys.get_state(c.server)
    refute Map.has_key?(state.in_flight, second)
    refute Map.has_key?(state.dispatch_contexts, second)
    assert_receive {:dispatch, :rejected, ^second}
    assert_receive {:dispatch_meta, :rejected, %{ref: ^second, token: token, ordinal: 1}}
    assert token == c.token
    refute_receive {:dispatch, _, _}
  end

  @tag :unscoped
  test "unscoped asynchronous rejection retires ref without invoking token callback", c do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(c.server, {:gen_agent, :admission, :ignored, c.ref, {:error, :halted}})
        assert {:ok, %{in_flight: 0}} = E.status(c.name)
      end)

    assert log =~ ~s(op {:dispatch, "worker"} failed: halted)
    refute log =~ "held"
    assert Process.alive?(c.server)
    state = :sys.get_state(c.server)
    refute Map.has_key?(state.in_flight, c.ref)
    refute Map.has_key?(state.dispatch_contexts, c.ref)
    assert_receive {:dispatch, :rejected, ref} when ref == c.ref
    assert_receive {:dispatch_meta, :rejected, %{ref: ^ref, token: nil, ordinal: nil}}
    send(c.server, {:gen_agent, :admission, :ignored, c.ref, :ok})
    send(c.server, {:gen_agent, :completion, :ignored, c.ref, {:ok, %{text: "late"}}})
    assert :sys.get_state(c.server) == state
    refute_receive {:dispatch, _, _}
  end

  test "held pre_turn leaves ordinary read and submission commands responsive", c do
    assert {:ok, %{in_flight: 1}} = E.status(c.name)
    assert {:ok, :pending} = E.poll(c.name, c.token)
    assert {:ok, []} = E.inbox(c.name)
    assert :ok = E.notify(c.name, :probe)
    assert {:ok, _} = E.tell(c.name, "queued")
    assert {:ok, %{in_flight: 2}} = E.status(c.name)
    send(c.child, :release)
    assert_receive {:controlled_prompt, _, "held", task}, 2_000
    send(task, {:result, "done"})
    assert_receive {:held, child}, 2_000
    send(child, :release)
  end

  test "completion before admission closes once and ignores late decisions", c do
    send(c.server, {:gen_agent, :completion, :ignored, c.ref, {:ok, %{text: "done"}}})
    assert {:ok, %{text: "done"}} = E.await(c.name, c.token)
    send(c.server, {:gen_agent, :admission, :ignored, c.ref, :ok})
    send(c.server, {:gen_agent, :admission, :ignored, c.ref, {:error, :halted}})
    send(c.server, {:gen_agent, :completion, :ignored, c.ref, {:error, :late}})
    assert {:ok, %{in_flight: 0}} = E.status(c.name)
    assert_receive {:dispatch, :start, ref} when ref == c.ref
    assert_receive {:dispatch, :stop, ref} when ref == c.ref
    refute_receive {:dispatch, _, _}
  end

  test "rejection emits no start and late completion cannot reopen it", c do
    send(c.server, {:gen_agent, :admission, :ignored, c.ref, {:error, :halted}})
    assert {:error, :halted} = E.await(c.name, c.token)
    send(c.server, {:gen_agent, :completion, :ignored, c.ref, {:ok, %{text: "late"}}})
    send(c.server, {:gen_agent, :admission, :ignored, c.ref, :ok})
    assert {:ok, %{in_flight: 0}} = E.status(c.name)
    assert_receive {:dispatch, :rejected, ref} when ref == c.ref
    assert_receive {:dispatch_meta, :rejected, %{ref: ^ref, ordinal: 0, token: token}}
    assert token == c.token
    refute_receive {:dispatch, _, _}
  end

  test "duplicate admission and error completion emit one start and error", c do
    for _ <- 1..2, do: send(c.server, {:gen_agent, :admission, :ignored, c.ref, :ok})
    send(c.server, {:gen_agent, :completion, :ignored, c.ref, {:error, :failed}})
    assert {:error, :failed} = E.await(c.name, c.token)
    assert_receive {:dispatch, :start, ref} when ref == c.ref
    assert_receive {:dispatch, :error, ref} when ref == c.ref
    refute_receive {:dispatch, _, _}
  end

  test "known-gap pin: cancellation before admission blocks reads until child control returns",
       c do
    :erlang.trace(c.server, true, [:send])

    on_exit(fn ->
      if Process.alive?(c.server), do: :erlang.trace(c.server, false, [:send])
    end)

    cancellation = Task.async(fn -> E.cancel(c.name, c.token) end)
    child = c.child
    ref = c.ref
    assert_receive {:trace, _, :send, {:"$gen_call", _, {:cancel_request, ^ref}}, ^child}
    status = Task.async(fn -> E.status(c.name) end)
    assert Task.yield(status, 50) == nil
    send(child, :release)
    assert {:ok, outcome} = Task.await(cancellation)
    assert outcome in [:cancelled, :cancelled_unconfirmed]
    assert {:ok, %{in_flight: 0}} = Task.await(status)
    :erlang.trace(c.server, false, [:send])
    before = :sys.get_state(c.server)
    send(c.server, {:gen_agent, :admission, :ignored, c.ref, :ok})
    send(c.server, {:gen_agent, :admission, :ignored, c.ref, {:error, :halted}})
    assert :sys.get_state(c.server) == before
    assert {:error, :cancelled} = E.await(c.name, c.token)
  end

  test "child death before admission emits error without a fabricated start", c do
    Process.exit(c.child, :kill)
    assert {:error, _} = E.await(c.name, c.token)
    assert_receive {:dispatch, :error, ref} when ref == c.ref
    refute_receive {:dispatch, _, _}
    assert {:ok, %{in_flight: 0}} = E.status(c.name)
    before = :sys.get_state(c.server)
    send(c.server, {:gen_agent, :admission, :ignored, c.ref, :ok})
    send(c.server, {:gen_agent, :admission, :ignored, c.ref, {:error, :halted}})
    assert :sys.get_state(c.server) == before
    refute_receive {:dispatch, _, _}
  end
end
