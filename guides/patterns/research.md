# Research

Autonomous self-chaining research agent -- one `GenAgent` that
drives itself through sub-question generation, per-question
answering, and final synthesis without any further input from the
manager.

## When to reach for this

The work can be decomposed into a fixed sequence of phases, each
phase is a separate LLM call, and the output of one phase is the
input to the next. You want to kick it off and walk away. A
manager polling `status/1` can observe progress but does not need
to drive the agent turn-by-turn.

This is the smallest and most idiomatic use of gen_agent's
self-chaining primitive. If you can express your work as a linear
state machine where each state produces the prompt for the next
state, this is the shape.

## What it exercises in gen_agent

- **Self-chaining via `{:prompt, text, state}` from
  `handle_response/3`** -- the whole pattern hinges on this
  return shape.
- **Phase-based `handle_response` dispatch** -- one clause per
  phase, each transitioning to the next phase or halting.
- **`handle_error/3`** to halt gracefully on any failure with the
  reason attached to state, so a manager polling `status/1` sees
  `phase: :failed` with context rather than a dead process.
- **`{:halt, state}`** as the terminal transition from the final
  synthesis phase.

## The pattern

One callback module. No manager-facing facade needed -- the
manager just calls `GenAgent.start_agent/2` and `GenAgent.status/1`
directly.

```elixir
defmodule Research.Agent do
  @moduledoc """
  Autonomous research GenAgent.

  Phases:
    1. :listing      -- model lists N sub-questions about the topic
    2. :answering    -- agent feeds each sub-question back one turn
                        at a time, accumulating answers
    3. :synthesizing -- final turn asking the model to pull
                        everything into a report
    4. :done         -- halt; final report is on state
  """

  use GenAgent

  defmodule State do
    defstruct [
      :topic,
      :max_sub_questions,
      :last_error,
      phase: :listing,
      sub_questions: [],
      answered: [],
      final_report: nil,
      turns: 0
    ]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      topic: Keyword.fetch!(opts, :topic),
      max_sub_questions: Keyword.get(opts, :max_sub_questions, 3)
    }

    backend_opts = [
      system: system_prompt(),
      max_tokens: Keyword.get(opts, :max_tokens, 512)
    ]

    {:ok, backend_opts, state}
  end

  # Phase 1 -> Phase 2: parse questions, dispatch first answer.
  @impl true
  def handle_response(_ref, response, %State{phase: :listing} = state) do
    questions =
      response.text
      |> parse_questions()
      |> Enum.take(state.max_sub_questions)

    new_state = %{state | sub_questions: questions, phase: :answering, turns: state.turns + 1}

    case questions do
      [] ->
        {:halt, %{new_state | phase: :failed, last_error: :no_questions}}

      [first | _] ->
        {:prompt, answer_prompt(first), new_state}
    end
  end

  # Phase 2 loop: answer each question in turn, then transition to synthesis.
  def handle_response(_ref, response, %State{phase: :answering} = state) do
    answered_count = length(state.answered)
    current_question = Enum.at(state.sub_questions, answered_count)
    answered = state.answered ++ [{current_question, String.trim(response.text)}]
    new_state = %{state | answered: answered, turns: state.turns + 1}

    if length(answered) < length(state.sub_questions) do
      next_question = Enum.at(state.sub_questions, length(answered))
      {:prompt, answer_prompt(next_question), new_state}
    else
      {:prompt, synthesis_prompt(new_state), %{new_state | phase: :synthesizing}}
    end
  end

  # Phase 3 -> terminal halt with the synthesized report on state.
  def handle_response(_ref, response, %State{phase: :synthesizing} = state) do
    {:halt,
     %{
       state
       | final_report: String.trim(response.text),
         phase: :done,
         turns: state.turns + 1
     }}
  end

  # A resumed terminal agent preserves its report and halts again.
  def handle_response(_ref, _response, %State{phase: phase} = state)
      when phase in [:done, :failed], do: {:halt, state}

  # Errors after resume preserve the terminal phase too.
  @impl true
  def handle_error(_ref, reason, %State{phase: phase} = state)
      when phase in [:done, :failed] do
    {:halt, %{state | last_error: reason}}
  end

  def handle_error(_ref, reason, %State{} = state) do
    {:halt, %{state | last_error: reason, phase: :failed}}
  end

  # --- Prompts & parsing ---

  defp answer_prompt(question) do
    "Answer this sub-question in 2-3 concise sentences: #{question}"
  end

  defp synthesis_prompt(%State{} = state) do
    answers =
      state.answered
      |> Enum.map_join("\n\n", fn {q, a} -> "Q: #{q}\nA: #{a}" end)

    """
    You have now answered all the sub-questions for the topic:
    #{state.topic}.

    Here are your sub-questions and answers:

    #{answers}

    Synthesize these findings into a concise 3-paragraph report.
    """
  end

  defp system_prompt do
    """
    You are a concise research assistant.

    When asked to list sub-questions: output them one per line,
    plain text questions ending in ?, no preamble, numbering or markup.

    When asked to answer a sub-question: 2-3 short sentences, no
    preamble.

    When asked to synthesize a report: exactly 3 paragraphs
    separated by blank lines, no headings.
    """
  end

  defp parse_questions(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.replace(&1, ~r/^\d+[.)]\s+/, ""))
    |> Enum.filter(&String.ends_with?(&1, "?"))
  end

  # Bound both polling and each status call; halted processes retain final state.
  def await_completion(name, timeout \\ 30_000) do
    wait([name], System.monotonic_time(:millisecond) + timeout)
  end

  defp wait(names, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      try do
        statuses =
          Enum.map(names, fn name ->
            call_timeout = deadline - System.monotonic_time(:millisecond)
            if call_timeout > 0,
              do: GenAgent.status(name, call_timeout),
              else: {:error, :timeout}
          end)

        case Enum.find(statuses, &match?({:error, _}, &1)) do
          {:error, reason} ->
            {:error, reason}

          nil ->
            if Enum.all?(statuses, & &1.halted) do
              states = Enum.map(statuses, & &1.agent_state)

              case Enum.find(states, fn state -> state.phase == :failed end) do
                nil -> {:ok, hd(states)}
                state -> {:error, state.last_error}
              end
            else
              Process.sleep(min(10, max(0, deadline - System.monotonic_time(:millisecond))))
              wait(names, deadline)
            end
        end
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, {:status_unavailable, reason}}
      end
    end
  end
end
```

Resuming a terminal agent and sending another ask/tell preserves its report
and terminal phase, then halts again.

Questions must occupy one line each and end in `?`. The parser strips numeric
prefixes such as `1.` and `2)`, and ignores blank lines and preambles without a
trailing question mark before applying the question limit. A preamble ending
in `?` counts as a question; wrapped questions and other list markup are outside
this simple format. A listing with no valid questions fails with `:no_questions`.

## Using it

```elixir
# Start the agent. It self-drives from here.
{:ok, _pid} = GenAgent.start_agent(Research.Agent,
  name: "octopus-research",
  backend: GenAgent.Backends.Anthropic,
  topic: "why do octopuses have three hearts?",
  max_sub_questions: 3
)

# The first turn needs a kick.
{:ok, _ref} = GenAgent.tell("octopus-research",
  "List 3 sub-questions about: why do octopuses have three hearts?")

try do
  case Research.Agent.await_completion("octopus-research", 30_000) do
    {:ok, %{final_report: report}} -> IO.inspect(report, label: "report")
    {:error, reason} -> IO.inspect(reason, label: "research failed or timed out")
  end
after
  GenAgent.stop("octopus-research")
end
```

## Variations

- **Dynamic sub-question count.** Instead of fixing
  `max_sub_questions`, let the listing turn output as many as it
  wants and take all of them.
- **Parallel answering.** Replace the sequential answer loop with
  a `Supervisor`-shaped fan-out: spawn one worker agent per
  sub-question, collect answers via notify. See the
  [Supervisor](supervisor.md) pattern.
- **Per-phase model selection.** Different phases might deserve
  different models -- cheap model for listing, expensive model
  for synthesis. Swap sessions mid-run, or have the backend take
  per-call overrides.
- **Mid-run inspection.** Because phase lives on state, a manager
  can inspect partial results via `GenAgent.status/1` at any
  point. Useful for long-running research where you want to bail
  early if answers aren't looking good.
