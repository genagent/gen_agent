defmodule GenAgentEnsemble.StreamTest do
  use ExUnit.Case, async: false

  alias GenAgent.{Event, Response}
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.{ControlledAgent, StreamingBackend}
  alias GenAgentEnsemble.Strategies.Solo

  # Exercises fanout, repeated dispatch, and early terminal operations without
  # tying transport assertions to a production strategy's aggregation policy.
  defmodule Strategy do
    def init(opts) do
      specs = Keyword.fetch!(opts, :agents)
      {:ok, %{members: Enum.map(specs, &elem(&1, 0)), token: nil, repeat: false}, specs}
    end

    def handle_tell(prompt, opts, token, state) do
      send(Keyword.fetch!(opts, :observer), {:strategy_opts, opts})
      ops = Enum.map(state.members, &{:dispatch, &1, prompt, token})
      {:ok, ops, %{state | token: token, repeat: Keyword.get(opts, :repeat, false)}}
    end

    def handle_response(agent, response, %{repeat: true} = state) do
      {:ok, [{:dispatch, agent, response.text, state.token}], %{state | repeat: false}}
    end

    def handle_response(_agent, response, state),
      do: {:ok, [{:reply, state.token, response}], state}

    def handle_error(_agent, reason, state),
      do: {:ok, [{:reply_error, state.token, reason}], state}

    def handle_agent_down(_agent, _reason, state),
      do: {:ok, [{:reply_error, state.token, :agent_down}], state}

    def handle_cancel(_token, state), do: {:ok, [], state}
    def handle_notify(op, state), do: {:ok, [op], state}
  end

  defp spec(member) do
    {member, ControlledAgent, backend: StreamingBackend, observer: self(), tag: member}
  end

  defp start(strategy \\ Solo, opts \\ nil) do
    name = "stream-#{System.unique_integer([:positive])}"
    {:ok, pid} = E.start_link(name: name, strategy: strategy, opts: opts || [agent: spec("w")])

    on_exit(fn ->
      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    {name, pid}
  end

  # Select only by the common prefix, so a completion overtaking an event fails.
  defp next_message do
    receive do
      {:gen_agent_ensemble, _, _, _, _} = message -> message
    after
      1_000 -> flunk("expected ensemble message")
    end
  end

  defp event(name, token, member, ordinal, kind, text) do
    assert {:gen_agent_ensemble, :event, ^name, ^token,
            %{agent: ^member, dispatch: ^ordinal, event: %Event{kind: ^kind, data: data}}} =
             next_message()

    assert data.text == text
  end

  defp completion(name, token) do
    assert {:gen_agent_ensemble, :completion, ^name, ^token, result} = next_message()
    result
  end

  defp refs(pid), do: :sys.get_state(pid).in_flight

  defp assert_fenced(pid, name, old_refs) do
    for {ref, {member, _}} <- old_refs do
      send(pid, {:gen_agent, :event, "#{name}/#{member}", ref, Event.new(:text, %{text: "late"})})
    end

    send(pid, {:gen_agent, :event, "unknown", make_ref(), Event.new(:text)})
    assert :sys.get_state(pid).stream_recipients == %{}
    refute_received {:gen_agent_ensemble, :event, _, _, _}
  end

  test "Solo forwards normalized events in order before completion and cleans up" do
    {name, pid} = start()
    {:ok, token} = E.tell_with_completion(name, "first", self(), stream_to: self())
    assert_receive {:stream_gate, "w", task}
    old_refs = refs(pid)
    event(name, token, "w", 0, :text, "first")
    send(task, :release)
    event(name, token, "w", 0, :text, "tail")
    event(name, token, "w", 0, :result, "done")
    assert {:ok, %Response{text: "done"}} = completion(name, token)
    assert_fenced(pid, name, old_refs)
  end

  test "streaming is per token and off for tell and default or nil completion options" do
    {name, pid} = start()

    for mode <- [:stream, :default, :tell, nil] do
      {:ok, token} =
        case mode do
          :stream -> E.tell_with_completion(name, "first", self(), stream_to: self())
          :default -> E.tell_with_completion(name, "first")
          :tell -> E.tell(name, "first")
          nil -> E.tell_with_completion(name, "first", self(), stream_to: nil)
        end

      assert_receive {:stream_gate, "w", task}
      {_, child_state} = :sys.get_state(GenAgent.whereis("#{name}/w"))
      assert child_state.current_request.stream_to == if(mode == :stream, do: pid, else: nil)
      if mode == :stream, do: event(name, token, "w", 0, :text, "first")
      send(task, :release)
      assert {:ok, _} = E.await(name, token)

      if mode == :stream do
        event(name, token, "w", 0, :text, "tail")
        event(name, token, "w", 0, :result, "done")
      end

      if mode != :tell, do: assert({:ok, _} = completion(name, token))
      assert_fenced(pid, name, %{})
    end
  end

  test "queued tokens retain independent streaming choices" do
    {name, pid} = start()
    {:ok, first} = E.tell_with_completion(name, "first", self(), stream_to: self())
    assert_receive {:stream_gate, "w", task}
    event(name, first, "w", 0, :text, "first")
    {:ok, second} = E.tell_with_completion(name, "second")
    {:ok, third} = E.tell_with_completion(name, "third", self(), stream_to: self())
    assert Enum.sort(Map.keys(:sys.get_state(pid).stream_recipients)) == Enum.sort([first, third])
    send(task, :release)
    event(name, first, "w", 0, :text, "tail")
    event(name, first, "w", 0, :result, "done")
    assert {:ok, _} = completion(name, first)
    assert_receive {:stream_gate, "w", second_task}
    {_, child_state} = :sys.get_state(GenAgent.whereis("#{name}/w"))
    assert child_state.current_request.stream_to == nil
    send(second_task, :release)
    assert {:ok, _} = completion(name, second)
    assert_receive {:stream_gate, "w", third_task}
    event(name, third, "w", 0, :text, "third")
    send(third_task, :release)
    event(name, third, "w", 0, :text, "tail")
    event(name, third, "w", 0, :result, "done")
    assert {:ok, _} = completion(name, third)
    assert_fenced(pid, name, %{})
  end

  test "reserved option is validated and stripped; repeated member dispatch increments ordinal" do
    {name, pid} = start(Strategy, agents: [spec("w")])

    assert_raise ArgumentError, fn ->
      E.tell_with_completion(name, "first", self(), stream_to: :invalid)
    end

    assert :sys.get_state(pid).pending == %{}

    {:ok, token} =
      E.tell_with_completion(name, "first", self(),
        stream_to: self(),
        observer: self(),
        repeat: true
      )

    assert_receive {:strategy_opts, opts}
    assert opts == [observer: self(), repeat: true]
    assert_receive {:stream_gate, "w", first}
    first_refs = refs(pid)
    event(name, token, "w", 0, :text, "first")
    send(first, :release)
    event(name, token, "w", 0, :text, "tail")
    event(name, token, "w", 0, :result, "done")
    assert_receive {:stream_gate, "w", second}
    event(name, token, "w", 1, :text, "done")

    # A completed child is fenced even while its token remains active.
    for {ref, {member, _}} <- first_refs do
      send(pid, {:gen_agent, :event, member, ref, Event.new(:text, %{text: "stale"})})
    end

    :sys.get_state(pid)
    refute_received {:gen_agent_ensemble, :event, _, _, _}
    send(second, :release)
    event(name, token, "w", 1, :text, "tail")
    event(name, token, "w", 1, :result, "done")
    assert {:ok, _} = completion(name, token)
    assert_fenced(pid, name, first_refs)
  end

  test "fanout identifies bare members and fences peers after early token error" do
    {name, pid} = start(Strategy, agents: [spec("a"), spec("b")])

    {:ok, token} =
      E.tell_with_completion(name, "first", self(), stream_to: self(), observer: self())

    assert_receive {:stream_gate, "a", a}
    assert_receive {:stream_gate, "b", b}
    old_refs = refs(pid)

    events = for _ <- 1..2, do: next_message()

    assert Enum.sort(
             Enum.map(events, fn
               {:gen_agent_ensemble, :event, ^name, ^token,
                %{agent: member, dispatch: ordinal, event: %Event{kind: :text}}} ->
                 {member, ordinal}
             end)
           ) == [{"a", 0}, {"b", 1}]

    send(a, {:error, :failed})

    assert {:gen_agent_ensemble, :event, ^name, ^token,
            %{agent: "a", dispatch: 0, event: %Event{kind: :error}}} = next_message()

    assert {:error, _} = completion(name, token)
    assert map_size(refs(pid)) == 1
    assert_fenced(pid, name, old_refs)

    # Trace the real peer completion as a barrier before checking no late relay.
    child = GenAgent.whereis("#{name}/b")
    :erlang.trace(child, true, [:send])
    send(b, :release)
    assert_receive {:trace, ^child, :send, {:gen_agent, :completion, _, _, _}, ^pid}
    :erlang.trace(child, false, [:send])
    assert_fenced(pid, name, old_refs)
  end

  test "cancellation fences late events and clears the recipient" do
    {name, pid} = start()
    {:ok, token} = E.tell_with_completion(name, "first", self(), stream_to: self())
    assert_receive {:stream_gate, "w", _task}
    event(name, token, "w", 0, :text, "first")
    old_refs = refs(pid)
    assert E.cancel(name, token) == {:ok, :cancelled}
    assert completion(name, token) == {:error, :cancelled}
    assert_fenced(pid, name, old_refs)
  end

  test "cancel drains events and completions queued behind its call in arrival order" do
    {name, pid} = start()
    {:ok, token} = E.tell_with_completion(name, "first", self(), stream_to: self())
    assert_receive {:stream_gate, "w", task}
    event(name, token, "w", 0, :text, "first")
    old_refs = refs(pid)
    :ok = :sys.suspend(pid)
    tag = make_ref()
    send(pid, {:"$gen_call", {self(), tag}, {:cancel, token}})
    child = GenAgent.whereis("#{name}/w")
    :erlang.trace(child, true, [:send])
    send(task, :release)
    assert_receive {:trace, ^child, :send, {:gen_agent, :completion, _, _, _}, ^pid}
    :erlang.trace(child, false, [:send])
    :ok = :sys.resume(pid)
    assert_receive {^tag, {:error, :already_finished}}
    event(name, token, "w", 0, :text, "tail")
    event(name, token, "w", 0, :result, "done")
    assert {:ok, _} = completion(name, token)
    assert_fenced(pid, name, old_refs)
  end

  test "negative child cancellation acknowledgement drains a racing stream before completion" do
    {name, pid} = start()
    {:ok, token} = E.tell_with_completion(name, "first", self(), stream_to: self())
    assert_receive {:stream_gate, "w", _task}
    event(name, token, "w", 0, :text, "first")
    [{ref, {member, ^token}}] = Map.to_list(refs(pid))
    fake = make_ref()

    # An unknown core ref produces a negative acknowledgement. Hold that call
    # open so the racing messages arrive after the initial selective drain.
    :sys.replace_state(pid, fn state ->
      {context, contexts} = Map.pop(state.dispatch_contexts, ref)

      %{
        state
        | in_flight: %{fake => {member, token}},
          dispatch_contexts: Map.put(contexts, fake, context)
      }
    end)

    child = GenAgent.whereis("#{name}/w")
    :ok = :sys.suspend(child)
    :erlang.trace(pid, true, [:send])
    tag = make_ref()
    send(pid, {:"$gen_call", {self(), tag}, {:cancel, token}})
    assert_receive {:trace, ^pid, :send, {:"$gen_call", _, {:cancel_request, ^fake}}, ^child}
    :erlang.trace(pid, false, [:send])
    send(pid, {:gen_agent, :event, "#{name}/w", fake, Event.new(:text, %{text: "racing"})})
    send(pid, {:gen_agent, :completion, "#{name}/w", fake, {:ok, %Response{text: "won"}}})
    :ok = :sys.resume(child)
    assert_receive {^tag, {:error, :already_finished}}
    event(name, token, "w", 0, :text, "racing")
    assert {:ok, %Response{text: "won"}} = completion(name, token)
    assert_fenced(pid, name, %{fake => {member, token}, ref => {member, token}})
  end

  test "rejected dispatch clears its stream recipient" do
    {name, pid} = start(Strategy, agents: [])

    :sys.replace_state(pid, fn state ->
      %{state | strategy_state: %{state.strategy_state | members: ["missing"]}}
    end)

    {:ok, token} =
      E.tell_with_completion(name, "first", self(), stream_to: self(), observer: self())

    assert {:error, {:dispatch_rejected, "missing", _}} = completion(name, token)
    assert_fenced(pid, name, %{})
  end

  test "agent down drops child refs and closes the token recipient" do
    {name, pid} = start(Strategy, agents: [spec("w")])

    {:ok, token} =
      E.tell_with_completion(name, "first", self(), stream_to: self(), observer: self())

    assert_receive {:stream_gate, "w", _task}
    event(name, token, "w", 0, :text, "first")
    old_refs = refs(pid)
    Process.exit(GenAgent.whereis("#{name}/w"), :kill)
    assert completion(name, token) == {:error, :agent_down}
    assert refs(pid) == %{}
    assert_fenced(pid, name, old_refs)
  end

  test "session halt delivers terminal completion and stops forwarding" do
    {name, pid} = start(Strategy, agents: [spec("w")])

    {:ok, token} =
      E.tell_with_completion(name, "first", self(), stream_to: self(), observer: self())

    assert_receive {:stream_gate, "w", _task}
    event(name, token, "w", 0, :text, "first")
    old_refs = refs(pid)
    monitor = Process.monitor(pid)
    # Queue halt then late events from one sender for deterministic ordering.
    send(pid, {:halt_session, :test})
    for {ref, _} <- old_refs, do: send(pid, {:gen_agent, :event, "w", ref, Event.new(:text)})
    assert completion(name, token) == {:error, {:halted, :test}}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    refute_received {:gen_agent_ensemble, :event, _, _, _}
  end

  test "separate and dead stream recipients do not change completion delivery" do
    {name, pid} = start()
    observer = self()
    recipient = spawn(fn -> relay(observer) end)
    on_exit(fn -> Process.exit(recipient, :kill) end)
    {:ok, token} = E.tell_with_completion(name, "first", self(), stream_to: recipient)
    assert_receive {:stream_gate, "w", task}
    assert_receive {:relayed, {:gen_agent_ensemble, :event, ^name, ^token, _}}
    send(task, :release)
    assert {:ok, _} = completion(name, token)

    assert_receive {:relayed,
                    {:gen_agent_ensemble, :event, ^name, ^token, %{event: %Event{kind: :text}}}}

    assert_receive {:relayed,
                    {:gen_agent_ensemble, :event, ^name, ^token, %{event: %Event{kind: :result}}}}

    send(recipient, {:barrier, self()})
    assert_receive :relayed_barrier
    refute_received {:relayed, {:gen_agent_ensemble, :completion, _, _, _}}
    assert_fenced(pid, name, %{})

    monitor = Process.monitor(recipient)
    Process.exit(recipient, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^recipient, :killed}
    {:ok, token} = E.tell_with_completion(name, "dead", self(), stream_to: recipient)
    assert_receive {:stream_gate, "w", task}
    send(task, :release)
    assert {:ok, _} = completion(name, token)
    assert {:ok, :completed, %Response{text: "done"}} = E.poll(name, token)
    assert_fenced(pid, name, %{})
  end

  defp relay(observer) do
    receive do
      {:barrier, caller} -> send(caller, :relayed_barrier)
      message -> send(observer, {:relayed, message})
    end

    relay(observer)
  end
end
