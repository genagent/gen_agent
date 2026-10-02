# Checkpointer

Human-in-the-loop review workflow. The agent works on a multi-step
task autonomously, but after each step sits **idle** with a phase
marker instead of halting, waiting for the manager to send one of
`approve`, `{:revise, hint}`, or `finish` for the draft it inspected.

## When to reach for this

You want an agent to produce draft work in steps, but a human (or
a reviewing agent) needs to gate each step before the next one
starts. Writing a document one paragraph at a time with review
between paragraphs. Producing a release plan and approving each
stage. Generating PR descriptions that need human sign-off before
posting.

The critical design decision is **not to halt**. If you halt with
`{:halt, state}` to pause for review, you freeze the mailbox --
which means a subsequent `{:prompt, ..., state}` return from
`handle_event/2` will silently enqueue but never dispatch. Idle
with a phase marker is the correct primitive for "wait for next
input from outside."

## What it exercises in gen_agent

- **Idle-with-phase-marker as a pause primitive.**
  `handle_response/3` returns `{:noreply, state}` with
  `phase: :awaiting_review` instead of `{:halt, state}`. The
  agent is idle and its mailbox is live, so a subsequent
  `notify/2` can dispatch the next turn.
- **`handle_event/2` returning `{:prompt, text, state}`** as a
  resume primitive. Each review decision produces the next
  prompt and transitions back to `:drafting`.
- **Multiple decision outcomes from the manager**: approve
  (continue to next step), revise (redo with feedback), finish
  (halt).
- **Terminal halt** only happens on final approval or explicit
  finish -- not on intermediate pauses.
- **Explicit review targets.** Decisions carry a token naming the
  draft they were made on, so queued, stale, and duplicate
  decisions are rejected.
- **`handle_error/3` as a recoverable state.** A failed turn moves
  the agent to a visible `:failed` phase instead of leaving it in
  `:drafting`.

## The pattern

One callback module. The manager's review decisions come in as
`{:review, token, :approve | {:revise, feedback} | :finish}` notifies.

Each successful draft gets a fresh `review_token` (a reference),
exposed in agent state next to the draft. A decision is applied only
if its token equals the current `review_token`, and the token is
cleared as soon as a decision is accepted. This matters because the
runtime defers notifications that arrive while a turn is in flight
and drains them after `handle_response/3` has returned. By then the
phase is `:awaiting_review` again for a *new* draft, so a decision
matched on phase alone would be applied to a draft the reviewer
never saw, and an approve sent twice would advance two steps. With
tokens, an early, stale, or duplicate decision carries a token that
no longer matches and falls through to the catch-all clause.

A failed turn does not call `handle_response/3`. The agent
implements `handle_error/3` to enter a `:failed` phase, record the
reason and the prompt that failed, and clear the review token. The
manager recovers with `{:retry, failure_ref}`, which names the
specific failure and redispatches the same prompt.

```elixir
defmodule Checkpointer.Agent do
  use GenAgent

  defmodule State do
    defstruct [
      :task,
      :draft,
      :current_step,
      :total_steps,
      :review_token,
      :last_prompt,
      :failure,
      phase: :drafting,
      history: [],
      feedback: nil
    ]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      task: Keyword.fetch!(opts, :task),
      current_step: 1,
      total_steps: Keyword.get(opts, :total_steps, 3)
    }

    system = """
    You are a writing assistant working on a multi-step task.
    Each turn, produce one refinement of the current draft. Keep
    each output concise. No preamble, no explanations -- just
    the draft.
    """

    {:ok, [system: system, max_tokens: Keyword.get(opts, :max_tokens, 300)], state}
  end

  # Remember the prompt of the turn in flight so a failed turn can be retried.
  @impl true
  def pre_turn(prompt, %State{} = state) do
    {:ok, prompt, %{state | last_prompt: prompt}}
  end

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    draft = String.trim(response.text)

    new_history =
      state.history ++ [%{step: state.current_step, draft: draft, feedback: state.feedback}]

    new_state = %{
      state
      | draft: draft,
        history: new_history,
        feedback: nil,
        failure: nil,
        review_token: make_ref(),
        phase: :awaiting_review
    }

    # NOT {:halt, state} -- halt would freeze the mailbox and
    # block handle_event's {:prompt, ...} return. Idle with a
    # phase marker is the correct pause primitive.
    {:noreply, new_state}
  end

  @impl true
  def handle_error(ref, reason, %State{} = state) do
    failure = %{ref: ref, reason: reason, prompt: state.last_prompt}
    {:noreply, %{state | phase: :failed, failure: failure, review_token: nil}}
  end

  # --- Review decisions from the manager ---

  @impl true
  def handle_event(
        {:review, token, :approve},
        %State{phase: :awaiting_review, review_token: token} = state
      )
      when is_reference(token) do
    if state.current_step >= state.total_steps do
      {:halt, %{state | phase: :done, review_token: nil}}
    else
      next_step = state.current_step + 1
      prompt = next_step_prompt(state.task, state.draft, next_step, state.total_steps)

      {:prompt, prompt, %{state | current_step: next_step, phase: :drafting, review_token: nil}}
    end
  end

  def handle_event(
        {:review, token, {:revise, feedback}},
        %State{phase: :awaiting_review, review_token: token} = state
      )
      when is_reference(token) and is_binary(feedback) do
    prompt = """
    Revise the current draft based on this feedback: #{feedback}

    Current draft:
    #{state.draft}
    """

    {:prompt, prompt, %{state | feedback: feedback, phase: :drafting, review_token: nil}}
  end

  def handle_event(
        {:review, token, :finish},
        %State{phase: :awaiting_review, review_token: token} = state
      )
      when is_reference(token) do
    {:halt, %{state | phase: :done, review_token: nil}}
  end

  # A retry names the failure it targets, so a stale retry is ignored.
  def handle_event(
        {:retry, ref},
        %State{phase: :failed, failure: %{ref: ref, prompt: prompt}} = state
      )
      when is_binary(prompt) do
    {:prompt, prompt, %{state | phase: :drafting, failure: nil}}
  end

  def handle_event(_other, state), do: {:noreply, state}

  # --- Prompts ---

  defp next_step_prompt(task, previous_draft, next_step, total) do
    """
    You are on step #{next_step} of #{total} for the task: #{task}

    Previous draft:
    #{previous_draft}

    Produce the next refinement. Each step should improve on
    the previous -- tighter, clearer, more specific.
    """
  end
end
```

## Using it

```elixir
{:ok, _pid} = GenAgent.start_agent(Checkpointer.Agent,
  name: "pitch",
  backend: GenAgent.Backends.Anthropic,
  task: "a single-sentence elevator pitch for a time-tracking app",
  total_steps: 3
)

# Kick off the first step.
{:ok, _ref} = GenAgent.tell("pitch",
  "Write an initial draft for: a single-sentence elevator pitch for a time-tracking app")

# Wait for phase :awaiting_review or :failed (a small poll loop or a
# helper in your manager module), then inspect.
case GenAgent.status("pitch").agent_state do
  %{phase: :awaiting_review, draft: draft, current_step: step, review_token: token} ->
    IO.puts("step #{step}: #{draft}")

    # Decide what to do next. The decision names the draft it was made on.
    GenAgent.notify("pitch", {:review, token, :approve})
    # ... or
    # GenAgent.notify("pitch", {:review, token, {:revise, "make it more specific about the target user"}})
    # ... or
    # GenAgent.notify("pitch", {:review, token, :finish})

  %{phase: :failed, failure: %{ref: ref, reason: reason}} ->
    IO.puts("turn failed: #{inspect(reason)}")

    # Redispatch the same prompt, or stop the agent.
    GenAgent.notify("pitch", {:retry, ref})
end

# After approve, the next step dispatches automatically. Loop:
# wait -> inspect -> decide -> repeat. Always take the token from the
# draft you inspected; never reuse one from an earlier draft.

GenAgent.stop("pitch")
```

## Variations

- **Multi-reviewer sign-off.** Instead of a single `:approve`
  command, require N distinct reviewers to each send a
  `{:review, token, :approve, reviewer_id}` before advancing. Track
  approvals in state, advance when the set is full.
- **Time-boxed review.** If no review decision arrives within a
  deadline, auto-approve or auto-finish. Use a state timeout or
  an external watchdog that fires a notify.
- **Branching plans.** Instead of a linear step counter, store
  a tree of planned steps and let the reviewer choose which
  branch to explore next via a more complex notify shape.
- **Diff-based review.** For patterns where each step produces a
  file change rather than a prose draft, replace `draft` with a
  proposed diff and let the reviewer approve/reject it. Commits
  happen via `post_turn/3` once approved. See
  [Workspace](workspace.md) for the workspace plumbing half of
  that.
