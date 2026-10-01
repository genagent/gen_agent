defmodule GenAgentEnsemble.RunFencingTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.Consensus

  setup do
    name = "fencing-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case Registry.lookup(GenAgentEnsemble.Registry, name) do
        [{server, _}] -> if Process.alive?(server), do: Ensemble.stop(name)
        [] -> :ok
      end
    end)

    {:ok, name: name}
  end

  defp start_consensus(name, extra_opts \\ []) do
    agents =
      for tag <- ["a", "b"] do
        {tag, ControlledAgent, [backend: ControlledBackend, observer: self(), tag: tag]}
      end

    opts =
      Keyword.merge(
        [agents: agents, rounds: 1, verdict_parser: &{:ok, :approve, &1}],
        extra_opts
      )

    Ensemble.start_link(name: name, strategy: Consensus, opts: opts)
  end

  defp await_poll(name, token, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    case Ensemble.poll(name, token) do
      {:ok, :pending} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_poll(name, token, deadline)
        else
          flunk("token #{token} did not complete")
        end

      other ->
        other
    end
  end

  test "a late response from a failed run cannot count toward the next run", %{name: name} do
    {:ok, _pid} = start_consensus(name)
    {:ok, first} = Ensemble.tell(name, "first")
    assert_receive {:controlled_prompt, "a", "first", a1}, 2_000
    assert_receive {:controlled_prompt, "b", "first", b1}, 2_000

    {:ok, second} = Ensemble.tell(name, "second")
    send(a1, {:error, :first_failed})
    assert_receive {:controlled_prompt, "a", "second", a2}, 2_000

    send(b1, {:result, "OLD_B"})
    assert_receive {:controlled_prompt, "b", "second", b2}, 2_000
    assert {:ok, %{phase: %{responded: 0}}} = Ensemble.status(name)

    send(a2, {:result, "NEW_A"})
    send(b2, {:result, "NEW_B"})
    assert {:ok, :completed, response} = await_poll(name, second)
    assert response.text =~ "NEW_A"
    assert response.text =~ "NEW_B"
    refute response.text =~ "OLD_B"
    assert {:error, {"a", :first_failed}} = await_poll(name, first)
  end

  test "a late error from a failed run cannot abort the next run", %{name: name} do
    {:ok, _pid} = start_consensus(name)
    {:ok, first} = Ensemble.tell(name, "first")
    assert_receive {:controlled_prompt, "a", "first", a1}, 2_000
    assert_receive {:controlled_prompt, "b", "first", b1}, 2_000

    {:ok, second} = Ensemble.tell(name, "second")
    send(a1, {:error, :first_failed})
    assert_receive {:controlled_prompt, "a", "second", a2}, 2_000
    assert {:error, {"a", :first_failed}} = await_poll(name, first)

    send(b1, {:error, :late_first_error})
    assert_receive {:controlled_prompt, "b", "second", b2}, 2_000
    assert {:ok, %{phase: %{responded: 0}}} = Ensemble.status(name)

    send(a2, {:result, "NEW_A"})
    send(b2, {:result, "NEW_B"})
    assert {:ok, :completed, response} = await_poll(name, second)
    assert response.text =~ "NEW_A"
    assert response.text =~ "NEW_B"
  end

  test "repeated queued submissions keep their own responses", %{name: name} do
    {:ok, _pid} = start_consensus(name)
    {:ok, first} = Ensemble.tell(name, "first")
    assert_receive {:controlled_prompt, "a", "first", a1}, 2_000
    assert_receive {:controlled_prompt, "b", "first", b1}, 2_000
    {:ok, second} = Ensemble.tell(name, "second")
    {:ok, third} = Ensemble.tell(name, "third")

    send(a1, {:error, :first_failed})
    assert_receive {:controlled_prompt, "a", "second", a2}, 2_000
    assert {:error, {"a", :first_failed}} = await_poll(name, first)
    send(b1, {:result, "OLD_B"})
    assert_receive {:controlled_prompt, "b", "second", b2}, 2_000

    send(a2, {:result, "SECOND_A"})
    send(b2, {:result, "SECOND_B"})
    assert_receive {:controlled_prompt, "a", "third", a3}, 2_000
    assert_receive {:controlled_prompt, "b", "third", b3}, 2_000
    assert {:ok, :completed, second_response} = await_poll(name, second)
    assert second_response.text =~ "SECOND_A"
    assert second_response.text =~ "SECOND_B"
    refute second_response.text =~ "OLD_B"

    send(a3, {:result, "THIRD_A"})
    send(b3, {:result, "THIRD_B"})
    assert {:ok, :completed, third_response} = await_poll(name, third)
    assert third_response.text =~ "THIRD_A"
    assert third_response.text =~ "THIRD_B"
  end

  test "round-two responses remain attached to the same run", %{name: name} do
    parser = fn text ->
      verdict = if text == "no", do: :reject, else: :approve
      {:ok, verdict, text}
    end

    {:ok, pid} = start_consensus(name, rounds: 2, verdict_parser: parser)
    {:ok, token} = Ensemble.tell(name, "question")
    assert_receive {:controlled_prompt, "a", "question", a1}, 2_000
    assert_receive {:controlled_prompt, "b", "question", b1}, 2_000

    {first_ref, _} =
      Enum.find(:sys.get_state(pid).in_flight, fn {_ref, {agent, _}} -> agent == "a" end)

    send(a1, {:result, "no"})
    send(b1, {:result, "yes"})
    assert_receive {:controlled_prompt, "a", _reprompt_a, a2}, 2_000
    assert_receive {:controlled_prompt, "b", _reprompt_b, b2}, 2_000

    # A duplicate terminal notification from round one has no live ref.
    send(pid, {:gen_agent_error, "#{name}/a", first_ref, :stale_round})
    send(a2, {:result, "yes again"})
    send(b2, {:result, "yes too"})
    assert {:ok, :completed, response} = await_poll(name, token)
    assert response.text =~ "round 2"
    assert response.text =~ "yes again"
    assert response.text =~ "yes too"
  end
end
