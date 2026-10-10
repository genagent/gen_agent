defmodule GenAgent.ReadmeRequestsGuideTest do
  use ExUnit.Case, async: false
  alias GenAgent.Backends.Mock

  defmodule Callback do
    use GenAgent
    def init_agent(opts), do: {:ok, [scripts: opts[:scripts] || []], %{events: []}}
    def handle_response(_, _, state), do: {:noreply, state}
    def handle_event(event, state), do: {:noreply, %{state | events: state.events ++ [event]}}
  end

  defp snippet(prefix) do
    [code] =
      for [_, code] <-
            Regex.scan(
              ~r/```elixir\n(.*?)\n```/s,
              File.read!(Path.expand("../../README.md", __DIR__))
            ),
          String.starts_with?(code, prefix),
          do: code

    code
  end

  defp start(opts \\ []) do
    name = "readme234-#{System.unique_integer([:positive])}"
    {:ok, pid} = GenAgent.start_agent(Callback, [name: name, backend: Mock] ++ opts)
    on_exit(fn -> if GenAgent.whereis(name), do: GenAgent.stop(name) end)
    {name, pid}
  end

  defp evaluate(prefix, name) do
    {result, _} = prefix |> snippet() |> String.replace("my-coder", name) |> Code.eval_string()
    result
  end

  test "exact README interruption example completes an active request" do
    {name, _} = start(scripts: [Mock.gate(:active, [])])

    assert %{ref: ref, interruption: {:ok, :accepted}} =
             evaluate("try do\n  with {:ok, ref}", name)

    assert GenAgent.poll(name, ref) == {:error, :interrupted}
  end

  test "exact README example cancels a tell queued while halted" do
    {name, _} = start()
    :ok = GenAgent.halt(name)

    assert %{ref: ref, interruption: {:ok, :cancelled}} =
             evaluate("try do\n  with {:ok, ref}", name)

    assert GenAgent.poll(name, ref) == {:error, :cancelled}
    assert GenAgent.runtime_snapshot(name).pending_prompts == 0
  end

  test "missing agent is returned on submission" do
    assert evaluate("try do\n  with {:ok, ref}", "no-such-readme234-agent") ==
             {:error, :not_found}
  end

  # Stop the owner at the interruption call. Submission/control handling and
  # the final catch still come directly from the fenced README example.
  def interrupt_after_death(name, ref, timeout) do
    pid = GenAgent.whereis(name)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      1_000 -> raise "fault injection did not stop agent"
    end

    GenAgent.interrupt_request(name, ref, timeout)
  end

  test "README returns an exact ref when the agent disappears before interruption" do
    {name, _} = start(scripts: [Mock.gate(:death, [])])

    ast =
      snippet("try do\n  with {:ok, ref}")
      |> String.replace("my-coder", name)
      |> Code.string_to_quoted!()

    ast =
      Macro.prewalk(ast, fn
        {{:., meta, [{:__aliases__, aliases, [:GenAgent]}, :interrupt_request]}, call, args} ->
          {{:., meta,
            [
              {:__aliases__, aliases, [:GenAgent, :ReadmeRequestsGuideTest]},
              :interrupt_after_death
            ]}, call, args}

        other ->
          other
      end)

    assert {%{ref: ref, interruption: {:error, :not_found}}, _} = Code.eval_quoted(ast)
    assert is_reference(ref)
  end

  def interrupt_call_exit(_name, _ref, _timeout) do
    exit({:noproc, {:gen_statem, :call, [:fixture, :request, 5_000]}})
  end

  test "README catches synchronous call exits" do
    {name, _} = start(scripts: [Mock.gate(:call_exit, [])])

    ast =
      snippet("try do\n  with {:ok, ref}")
      |> String.replace("my-coder", name)
      |> Code.string_to_quoted!()

    ast =
      Macro.prewalk(ast, fn
        {{:., meta, [{:__aliases__, aliases, [:GenAgent]}, :interrupt_request]}, call, args} ->
          {{:., meta,
            [{:__aliases__, aliases, [:GenAgent, :ReadmeRequestsGuideTest]}, :interrupt_call_exit]},
           call, args}

        other ->
          other
      end)

    assert {{:error, {:agent_call_failed, {:noproc, _}}}, _} = Code.eval_quoted(ast)
  end

  test "idle acknowledgment applies the event without launching a turn" do
    {name, _} = start()
    assert evaluate("case GenAgent.notify_ack", name) == :accepted
    assert GenAgent.status(name).agent_state.events == [{:ci_failed, "test_auth"}]
    assert GenAgent.status(name).state == :idle
    assert Mock.history(name) == []
  end

  test "busy acknowledgment admits a deferred event without completing the turn" do
    {name, _} = start(scripts: [Mock.gate(:busy, [GenAgent.Event.new(:result, %{text: "ok"})])])
    assert {:ok, ref} = GenAgent.tell_with_completion(name, "held")
    assert_receive {:mock_blocked, :busy, task}, 1_000
    assert evaluate("case GenAgent.notify_ack", name) == :accepted
    assert GenAgent.status(name).agent_state.events == []
    send(task, {:mock_release, :busy})
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, _}}, 1_000
    assert GenAgent.status(name).agent_state.events == [{:ci_failed, "test_auth"}]
  end
end
