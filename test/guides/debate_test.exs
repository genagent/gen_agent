# Compile the copyable modules directly from the guide, avoiding a second implementation.
guide = Path.expand("../../guides/patterns/debate.md", __DIR__)

for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
    String.starts_with?(code, ["defmodule Debate.Agent do", "defmodule Debate do"]) do
  Code.compile_string(code, guide)
end

defmodule GenAgent.DebateGuideTest do
  use ExUnit.Case, async: false

  # Replies "<label> <n>" on its nth turn. With `fail_on: {label, n}` the
  # session whose label matches returns a backend error on that turn.
  defmodule StubBackend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts) do
      [_, label] = Regex.run(~r/Your role: (\w+)\./, Keyword.fetch!(opts, :system))
      {:ok, %{label: label, turn: 0, fail_on: Keyword.get(opts, :fail_on)}}
    end

    @impl true
    def prompt(%{label: label, turn: turn, fail_on: fail_on} = session, _prompt) do
      turn = turn + 1

      if fail_on == {label, turn} do
        {:error, :stub_failure}
      else
        {:ok, [GenAgent.Event.new(:result, %{text: "#{label} #{turn}"})], %{session | turn: turn}}
      end
    end

    @impl true
    def terminate_session(_session), do: :ok
  end

  defp start(max_rounds, backend_opts \\ []) do
    {:ok, handle} =
      Debate.start("topic",
        role_a: "A",
        role_b: "B",
        max_rounds: max_rounds,
        backend: StubBackend,
        backend_opts: backend_opts
      )

    on_exit(fn ->
      for name <- [handle.a, handle.b], GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    handle
  end

  # The runtime flag, not the recipe's own status field.
  defp assert_halted(handle) do
    for name <- [handle.a, handle.b] do
      assert GenAgent.status(name).halted == true, name <> " is not halted"
    end
  end

  defp transcript(name), do: GenAgent.status(name).agent_state.transcript

  defp expected(rounds) do
    for n <- 1..rounds, who <- ["A", "B"], do: {who, "#{who} #{n}"}
  end

  defp names(handle, transcript) do
    Enum.map(transcript, fn {name, text} ->
      {if(name == handle.a, do: "A", else: "B"), text}
    end)
  end

  for rounds <- [1, 3] do
    test "each side speaks max_rounds times and delivers the last statement (#{rounds})" do
      rounds = unquote(rounds)
      handle = start(rounds)

      assert_receive {:debate, name1, :finished}, 2_000
      assert_receive {:debate, name2, :finished}, 2_000
      assert Enum.sort([name1, name2]) == Enum.sort([handle.a, handle.b])

      for name <- [handle.a, handle.b] do
        st = GenAgent.status(name).agent_state
        assert st.round == rounds
        assert st.heard == rounds
        assert st.status == :finished
        # Ordered, interleaved A, B, A, B ... and identical on both sides.
        assert names(handle, st.transcript) == expected(rounds)
      end

      assert transcript(handle.a) == transcript(handle.b)
      assert_halted(handle)
    end
  end

  test "a failed turn by the first speaker halts both and reports" do
    handle = start(3, fail_on: {"A", 2})

    assert_receive {:debate, a, {:failed, :stub_failure}}, 2_000
    assert a == handle.a
    assert_receive {:debate, b, {:failed, {:opponent_failed, ^a}}}, 2_000
    assert b == handle.b

    assert GenAgent.status(handle.a).agent_state.status == {:failed, :stub_failure}
    assert GenAgent.status(handle.b).agent_state.status == {:failed, {:opponent_failed, a}}

    # Both halted with the successful turns only, in order.
    assert names(handle, transcript(handle.a)) ==
             [{"A", "A 1"}, {"B", "B 1"}]

    assert_halted(handle)
    refute_receive {:debate, _, _}, 100
  end

  # The guide's wait loop: one report per agent, matched by name.
  defp await_reports(handle) do
    for name <- [handle.a, handle.b] do
      receive do
        {:debate, ^name, :finished} -> :ok
        {:debate, ^name, {:failed, reason}} -> {:error, reason}
      after
        2_000 -> flunk("no report from " <> name)
      end
    end
  end

  test "repeated debates in one process do not consume each other's reports" do
    first = start(2)
    assert await_reports(first) == [:ok, :ok]

    second = start(3)
    assert await_reports(second) == [:ok, :ok]

    # Both reports were the second debate's own, so it had finished.
    for name <- [second.a, second.b] do
      assert GenAgent.status(name).agent_state.round == 3
    end

    assert names(second, transcript(second.a)) == expected(3)
    refute_receive {:debate, _, _}, 100
  end

  test "a failed turn by the second speaker halts both and reports" do
    handle = start(2, fail_on: {"B", 1})

    assert_receive {:debate, b, {:failed, :stub_failure}}, 2_000
    assert b == handle.b
    assert_receive {:debate, a, {:failed, {:opponent_failed, ^b}}}, 2_000
    assert a == handle.a

    assert names(handle, transcript(handle.a)) == [{"A", "A 1"}]
    assert_halted(handle)
    refute_receive {:debate, _, _}, 100
  end
end
