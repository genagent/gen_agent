# Checkpointer

Human-in-the-loop review workflow. The agent works on a multi-step
task autonomously, but after each step sits **idle** with a phase
marker instead of halting, waiting for the manager to send one of
`approve`, `{:revise, hint}`, or `finish`.

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

## The pattern

One callback module. The manager's review decisions come in as
`{:review, :approve | {:revise, feedback} | :finish}` notifies.

```elixir
defmodule Checkpointer.Agent do
  use GenAgent

  defmodule State do
    defstruct [
      :task,
      :draft,
      :current_step,
      :total_steps,
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
        phase: :awaiting_review
    }

    # NOT {:halt, state} -- halt would freeze the mailbox and
    # block handle_event's {:prompt, ...} return. Idle with a
    # phase marker is the correct pause primitive.
    {:noreply, new_state}
  end

  # --- Review decisions from the manager ---

  @impl true
  def handle_event({:review, :approve}, %State{phase: :awaiting_review} = state) do
    cond do
      state.current_step >= state.total_steps ->
        {:halt, %{state | phase: :done}}

      true ->
        next_step = state.current_step + 1
        prompt = next_step_prompt(state.task, state.draft, next_step, state.total_steps)
        {:prompt, prompt, %{state | current_step: next_step, phase: :drafting}}
    end
  end

  def handle_event({:review, {:revise, feedback}}, %State{phase: :awaiting_review} = state)
      when is_binary(feedback) do
    prompt = """
    Revise the current draft based on this feedback: #{feedback}

    Current draft:
    #{state.draft}
    """

    {:prompt, prompt, %{state | feedback: feedback, phase: :drafting}}
  end

  def handle_event({:review, :finish}, %State{phase: :awaiting_review} = state) do
    {:halt, %{state | phase: :done}}
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

# Wait for phase: :awaiting_review and read the draft.
# (Use a small poll loop or a helper in your manager module.)
%{agent_state: %{draft: draft, current_step: step}} = GenAgent.status("pitch")
IO.puts("step #{step}: #{draft}")

# Decide what to do next.
GenAgent.notify("pitch", {:review, :approve})
# ... or
GenAgent.notify("pitch", {:review, {:revise, "make it more specific about the target user"}})
# ... or
GenAgent.notify("pitch", {:review, :finish})

# After approve, the next step dispatches automatically. Loop:
# wait_for_review -> inspect -> decide -> repeat.

GenAgent.stop("pitch")
```

## Variations

- **Multi-reviewer sign-off.** Instead of a single `:approve`
  command, require N distinct reviewers to each send a
  `{:review, :approve, reviewer_id}` before advancing. Track
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
