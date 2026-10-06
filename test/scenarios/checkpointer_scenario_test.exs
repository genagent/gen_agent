# Compile the copyable module directly from the guide, avoiding a second implementation.
guide = Path.expand("../../guides/patterns/checkpointer.md", __DIR__)

for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
    String.starts_with?(code, "defmodule Checkpointer.Agent do") do
  Code.compile_string(code, guide)
end

defmodule GenAgent.Scenarios.CheckpointerTest do
  @moduledoc """
  End-to-end scenario for the Checkpointer guide.

  Runs the guide's own `Checkpointer.Agent` against a scripted backend
  whose turns block until the test replies, so notifications can be
  sent while a turn is in flight. Covers the happy paths plus the
  protocol hazards: a review queued during processing, duplicate
  approvals, stale tokens after a revision, and failed turns.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias GenAgent.Event

  defmodule Backend do
    @moduledoc false
    @behaviour GenAgent.Backend

    @impl true
    def start_session(_opts), do: {:ok, Process.whereis(GenAgent.Scenarios.CheckpointerTest)}

    # Each turn announces itself to the test and blocks until it is answered.
    @impl true
    def prompt(observer, prompt) do
      send(observer, {:turn, prompt, self()})

      receive do
        {:reply, {:ok, text}} -> {:ok, [Event.new(:result, %{text: text})], observer}
        {:reply, {:error, reason}} -> {:error, reason}
      after
        5_000 -> {:error, :fixture_deadline}
      end
    end

    @impl true
    def terminate_session(_session), do: :ok
  end

  setup do
    Process.register(self(), GenAgent.Scenarios.CheckpointerTest)

    name = "checkpointer-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      GenAgent.start_agent(Checkpointer.Agent,
        name: name,
        backend: Backend,
        task: "write a 3-part tagline",
        total_steps: 3
      )

    on_exit(fn -> if GenAgent.whereis(name), do: GenAgent.stop(name) end)

    {:ok, name: name}
  end

  defp agent_state(name), do: GenAgent.status(name).agent_state

  # Answer the next turn and return its prompt.
  defp answer(reply) do
    assert_receive {:turn, prompt, task}, 1_000
    send(task, {:reply, reply})
    prompt
  end

  # Start the agent's first turn and answer it with a draft.
  defp first_draft(name, text \\ "draft 1") do
    {:ok, _ref} = GenAgent.tell(name, "start")
    answer({:ok, text})
    await_phase(name, :awaiting_review)
  end

  defp await_phase(name, phase, attempts \\ 100) do
    state = agent_state(name)

    cond do
      state.phase == phase ->
        state

      attempts == 0 ->
        flunk("expected phase #{inspect(phase)}, got #{inspect(state.phase)}")

      true ->
        Process.sleep(10)
        await_phase(name, phase, attempts - 1)
    end
  end

  # Wait until a turn is in flight and the runtime is processing it.
  defp await_turn(name) do
    assert_receive {:turn, prompt, task}, 1_000
    assert GenAgent.status(name).state == :processing
    {prompt, task}
  end

  defp finish_turn(task, reply), do: send(task, {:reply, reply})

  describe "idle-with-phase-marker pause primitive" do
    test "approves through all steps and finishes", %{name: name} do
      s1 = first_draft(name)
      status = GenAgent.status(name)
      assert status.state == :idle
      refute status.halted
      assert s1.current_step == 1
      assert s1.draft == "draft 1"
      assert is_reference(s1.review_token)

      GenAgent.notify(name, {:review, s1.review_token, :approve})
      answer({:ok, "draft 2"})
      s2 = await_phase(name, :awaiting_review)
      assert s2.current_step == 2
      refute s2.review_token == s1.review_token

      GenAgent.notify(name, {:review, s2.review_token, :approve})
      answer({:ok, "draft 3"})
      s3 = await_phase(name, :awaiting_review)
      assert s3.current_step == 3

      GenAgent.notify(name, {:review, s3.review_token, :approve})
      done = await_phase(name, :done)

      assert Enum.map(done.history, & &1.draft) == ["draft 1", "draft 2", "draft 3"]
      assert done.review_token == nil
      assert GenAgent.status(name).halted == true
    end

    test "revise redoes the current step with feedback in the prompt", %{name: name} do
      s1 = first_draft(name)

      GenAgent.notify(name, {:review, s1.review_token, {:revise, "be more specific"}})
      prompt = answer({:ok, "draft 1 revised"})
      assert prompt =~ "be more specific"

      s1b = await_phase(name, :awaiting_review)
      assert s1b.current_step == 1
      assert s1b.draft == "draft 1 revised"
      assert s1b.review_token != s1.review_token
      assert [%{feedback: nil}, %{feedback: "be more specific"}] = s1b.history

      GenAgent.notify(name, {:review, s1b.review_token, :approve})
      answer({:ok, "draft 2"})
      assert await_phase(name, :awaiting_review).current_step == 2
    end

    test "finish halts early without running remaining steps", %{name: name} do
      s1 = first_draft(name)

      GenAgent.notify(name, {:review, s1.review_token, :finish})
      done = await_phase(name, :done)

      assert Enum.map(done.history, & &1.draft) == ["draft 1"]
      assert GenAgent.status(name).halted == true
      refute_receive {:turn, _, _}, 50
    end
  end

  describe "review targets" do
    test "a review with no target or a made-up target is ignored", %{name: name} do
      s1 = first_draft(name)

      GenAgent.notify(name, {:review, nil, :approve})
      GenAgent.notify(name, {:review, make_ref(), :approve})
      GenAgent.notify(name, {:review, :approve})
      GenAgent.notify(name, :approve)

      assert agent_state(name) == s1
      refute_receive {:turn, _, _}, 50
    end

    test "a review sent while a turn is in flight is not applied to the unseen draft",
         %{name: name} do
      s1 = first_draft(name)

      GenAgent.notify(name, {:review, s1.review_token, :approve})
      {_prompt, task} = await_turn(name)

      # The reviewer has not seen draft 2. These are queued by the runtime and
      # drained after handle_response/3 has set :awaiting_review again.
      GenAgent.notify(name, {:review, s1.review_token, :approve})
      GenAgent.notify(name, {:review, s1.review_token, :finish})
      GenAgent.notify(name, {:review, s1.review_token, {:revise, "too early"}})
      assert GenAgent.runtime_snapshot(name).pending_notifications == 3

      finish_turn(task, {:ok, "draft 2"})
      s2 = await_phase(name, :awaiting_review)

      assert s2.current_step == 2
      assert s2.draft == "draft 2"
      assert is_reference(s2.review_token)
      assert GenAgent.status(name).state == :idle
      assert GenAgent.runtime_snapshot(name).pending_notifications == 0
      refute GenAgent.status(name).halted
      refute_receive {:turn, _, _}, 50

      # The fresh token still works.
      GenAgent.notify(name, {:review, s2.review_token, :approve})
      answer({:ok, "draft 3"})
      assert await_phase(name, :awaiting_review).current_step == 3
    end

    test "a duplicate approve during the next turn does not advance another step",
         %{name: name} do
      s1 = first_draft(name)

      GenAgent.notify(name, {:review, s1.review_token, :approve})
      {_prompt, task} = await_turn(name)
      GenAgent.notify(name, {:review, s1.review_token, :approve})

      finish_turn(task, {:ok, "draft 2"})
      s2 = await_phase(name, :awaiting_review)

      assert s2.current_step == 2
      assert length(s2.history) == 2
      refute_receive {:turn, _, _}, 50
    end

    test "two approvals queued together advance one step", %{name: name} do
      s1 = first_draft(name)

      GenAgent.notify(name, {:review, s1.review_token, :approve})
      GenAgent.notify(name, {:review, s1.review_token, :approve})

      {prompt, task} = await_turn(name)
      assert prompt =~ "step 2 of 3"
      finish_turn(task, {:ok, "draft 2"})

      s2 = await_phase(name, :awaiting_review)
      assert s2.current_step == 2
      refute_receive {:turn, _, _}, 50
    end

    test "the old token is rejected after a revision", %{name: name} do
      s1 = first_draft(name)

      GenAgent.notify(name, {:review, s1.review_token, {:revise, "tighter"}})
      answer({:ok, "draft 1 revised"})
      s1b = await_phase(name, :awaiting_review)

      GenAgent.notify(name, {:review, s1.review_token, :approve})

      assert agent_state(name) == s1b
      refute_receive {:turn, _, _}, 50
    end
  end

  describe "failed turns" do
    test "a failed first turn is visible and recoverable by retry", %{name: name} do
      {:ok, _ref} = GenAgent.tell(name, "start")
      answer({:error, :boom})

      failed = await_phase(name, :failed)
      assert failed.failure.reason == :boom
      assert failed.failure.prompt == "start"
      assert failed.review_token == nil
      assert failed.history == []

      # Review events cannot apply to a failed turn.
      GenAgent.notify(name, {:review, make_ref(), :approve})
      GenAgent.notify(name, {:review, nil, :finish})
      assert agent_state(name) == failed

      GenAgent.notify(name, {:retry, failed.failure.ref})
      assert answer({:ok, "draft 1"}) == "start"

      s1 = await_phase(name, :awaiting_review)
      assert s1.current_step == 1
      assert s1.failure == nil
      assert is_reference(s1.review_token)
    end

    test "a failed approval turn is retried with the same prompt", %{name: name} do
      s1 = first_draft(name)

      GenAgent.notify(name, {:review, s1.review_token, :approve})
      step2_prompt = answer({:error, :timeout})

      failed = await_phase(name, :failed)
      assert failed.current_step == 2
      assert failed.failure.prompt == step2_prompt
      assert failed.review_token == nil
      assert length(failed.history) == 1

      # The consumed token cannot be replayed against the failed state.
      GenAgent.notify(name, {:review, s1.review_token, :approve})
      assert agent_state(name) == failed

      GenAgent.notify(name, {:retry, failed.failure.ref})
      assert answer({:ok, "draft 2"}) == step2_prompt

      s2 = await_phase(name, :awaiting_review)
      assert s2.current_step == 2
      assert Enum.map(s2.history, & &1.draft) == ["draft 1", "draft 2"]
    end

    test "a failed revision turn keeps the step and history", %{name: name} do
      s1 = first_draft(name)

      GenAgent.notify(name, {:review, s1.review_token, {:revise, "shorter"}})
      revise_prompt = answer({:error, :overloaded})

      failed = await_phase(name, :failed)
      assert failed.current_step == 1
      assert length(failed.history) == 1
      assert failed.failure.prompt == revise_prompt

      GenAgent.notify(name, {:retry, failed.failure.ref})
      assert answer({:ok, "draft 1 shorter"}) == revise_prompt

      s1b = await_phase(name, :awaiting_review)
      assert s1b.current_step == 1
      assert Enum.map(s1b.history, & &1.draft) == ["draft 1", "draft 1 shorter"]
    end

    test "a stale or made-up retry is ignored, and a failure can recur", %{name: name} do
      {:ok, _ref} = GenAgent.tell(name, "start")
      answer({:error, :first})
      failed = await_phase(name, :failed)

      GenAgent.notify(name, {:retry, make_ref()})
      assert agent_state(name) == failed

      GenAgent.notify(name, {:retry, failed.failure.ref})
      answer({:error, :second})
      failed2 = await_phase(name, :failed)
      assert failed2.failure.reason == :second
      refute failed2.failure.ref == failed.failure.ref

      # Retrying the first failure again does nothing.
      GenAgent.notify(name, {:retry, failed.failure.ref})
      assert agent_state(name) == failed2
      refute_receive {:turn, _, _}, 50
    end
  end
end
