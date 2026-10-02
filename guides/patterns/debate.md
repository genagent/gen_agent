# Debate

Two agents take turns until a convergence rule or round cap ends the
exchange. The shipped Ensemble strategy owns the alternation and
reply. The callback recipe later on this page instead uses
cross-agent `notify` and mutual halt without an orchestrator.

## Using it from `gen_agent_ensemble`

`GenAgentEnsemble.Strategies.Debate` accepts exactly two agent specs.
Each agent keeps its own backend session. The default reply is a
labeled transcript; `:converge`, `:rounds`, and `:reply` customize the
stopping and output rules.

```elixir
simple = GenAgentEnsemble.Agents.Simple
echo = GenAgentEnsemble.Backends.Echo

{:ok, _pid} =
  GenAgentEnsemble.start_link(
    name: "design-debate",
    strategy: GenAgentEnsemble.Strategies.Debate,
    opts: [
      agents: [{"for", simple, backend: echo}, {"against", simple, backend: echo}],
      rounds: 4
    ]
  )

{:ok, transcript} = GenAgentEnsemble.ask("design-debate", "Should this API be synchronous?")
```

The rest of this page is a separate callback-level reference
implementation. Read the shipped strategy's module documentation for
its exact options and failure behavior.

## When to reach for this

You want two autonomous perspectives on a topic and the
alternation is the point -- a debate, a red-team/blue-team
critique, a generator/critic loop, an interviewer/subject
exchange. Both sides have their own system prompt, their own
history, and their own halt condition, but neither is "in
charge."

This is the smallest cross-agent coordination pattern gen_agent
supports. Once you've seen it you'll recognize the shape in
richer fan-out topologies later (the [Supervisor](supervisor.md)
pattern is this idea generalized to N workers plus a coordinator).

## What the callback recipe exercises

- **Cross-agent `GenAgent.notify/2`** from inside
  `handle_response/3` -- the "I just finished my turn, now it's
  your turn" pass.
- **`handle_event/2` returning `{:prompt, text, state}`** -- the
  "I received your turn, here's what I'll say next" translation
  from an incoming event into a dispatched prompt.
- **Mutual halt coordination**: each side speaks exactly
  `max_rounds` times. A's last statement is delivered to B, B
  answers it, and B's last statement is delivered to A. Both halt
  once the second speaker's last statement has been delivered.
- **Failure propagation**: `handle_error/3` halts the failing side
  and notifies the opponent with `{:debate, {:failed, name, reason}}`,
  so the other side halts too instead of waiting forever.
- **Observable completion**: every agent sends its `:report_to`
  process `{:debate, name, :finished}` or
  `{:debate, name, {:failed, reason}}` when it halts.
- **Two simultaneous agents with independent sessions**,
  potentially on different backends, each with their own system
  prompt.

## Callback reference implementation

One callback module (used for both sides), plus a small starter
function that spins up the two agents with opposing roles and
kicks off the first turn.

### `Debate.Agent`

```elixir
defmodule Debate.Agent do
  use GenAgent

  defmodule State do
    defstruct [
      :name,
      :opponent,
      :role,
      :topic,
      :max_rounds,
      :report_to,
      round: 0,
      heard: 0,
      status: :running,
      transcript: []
    ]
  end

  @impl true
  def init_agent(opts) do
    state = %State{
      name: Keyword.fetch!(opts, :agent_name),
      opponent: Keyword.fetch!(opts, :opponent),
      role: Keyword.fetch!(opts, :role),
      topic: Keyword.fetch!(opts, :topic),
      max_rounds: Keyword.fetch!(opts, :max_rounds),
      report_to: Keyword.get(opts, :report_to)
    }

    system = """
    You are debating the topic: "#{state.topic}".

    Your role: #{state.role}.

    Keep each response to 2-3 sentences. Be direct and specific.
    Stay in character. Do not summarize the opponent's point --
    just rebut or extend the argument.
    """

    backend_opts =
      [system: system, max_tokens: Keyword.get(opts, :max_tokens, 200)] ++
        Keyword.get(opts, :backend_opts, [])

    {:ok, backend_opts, state}
  end

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    text = String.trim(response.text)
    new_state = record(%{state | round: state.round + 1}, state.name, text)

    # Always pass the statement on, including our last one.
    GenAgent.notify(state.opponent, {:opponent_said, text})

    if new_state.heard >= new_state.max_rounds do
      # The opponent already had its last word and we just had ours.
      finish(new_state, :finished)
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_error(_ref, reason, %State{} = state) do
    # Backend error, watchdog timeout or interrupt. The opponent is idle
    # waiting for our statement, so tell it and stop.
    GenAgent.notify(state.opponent, {:debate, {:failed, state.name, reason}})
    finish(state, {:failed, reason})
  end

  @impl true
  def handle_event({:opponent_said, text}, %State{} = state) do
    state = record(%{state | heard: state.heard + 1}, state.opponent, text)

    if state.round >= state.max_rounds do
      # The opponent had the last word; nothing left to say.
      finish(state, :finished)
    else
      prompt = ~s"""
      Your opponent just said: "#{text}"

      Respond briefly, staying in your role.
      """

      {:prompt, prompt, state}
    end
  end

  def handle_event({:debate, {:failed, who, _reason}}, %State{} = state) do
    finish(state, {:failed, {:opponent_failed, who}})
  end

  def handle_event(_other, state), do: {:noreply, state}

  # Each agent keeps one ordered transcript: its own statements and the
  # opponent's, in the order this agent saw them.
  defp record(state, who, text), do: %{state | transcript: state.transcript ++ [{who, text}]}

  defp finish(state, status) do
    if state.report_to, do: send(state.report_to, {:debate, state.name, status})
    {:halt, %{state | status: status}}
  end
end
```

### Starter function

```elixir
defmodule Debate do
  alias Debate.Agent

  def start(topic, opts \\ []) do
    role_a = Keyword.get(opts, :role_a, "optimist arguing in favor")
    role_b = Keyword.get(opts, :role_b, "skeptic arguing against")
    max_rounds = Keyword.get(opts, :max_rounds, 3)
    backend = Keyword.get(opts, :backend, GenAgent.Backends.Anthropic)

    id = System.unique_integer([:positive])
    name_a = "debate-#{id}-a"
    name_b = "debate-#{id}-b"

    shared = [
      backend: backend,
      backend_opts: Keyword.get(opts, :backend_opts, []),
      topic: topic,
      max_rounds: max_rounds,
      report_to: Keyword.get(opts, :report_to, self())
    ]

    {:ok, _} = GenAgent.start_agent(Agent,
      [name: name_a, agent_name: name_a, opponent: name_b, role: role_a] ++ shared)

    {:ok, _} = GenAgent.start_agent(Agent,
      [name: name_b, agent_name: name_b, opponent: name_a, role: role_b] ++ shared)

    # Kick off agent A with the opening statement.
    {:ok, _ref} = GenAgent.tell(name_a,
      "Make your opening statement about: #{topic}. 2-3 sentences.")

    {:ok, %{a: name_a, b: name_b}}
  end
end
```

## Using it

```elixir
{:ok, handle} = Debate.start(
  "is Rust a better systems language than C++ for new projects?",
  role_a: "Rust advocate",
  role_b: "C++ veteran",
  max_rounds: 3
)

# Both agents are now running. Agent A has received the opening
# prompt and will produce the first turn. When A's handle_response
# fires, it notifies B with {:opponent_said, text}, and B's
# handle_event turns that into B's next prompt. And so on.
#
# Each side speaks max_rounds times: A, B, A, B, ... B's last
# statement is delivered to A, which records it and halts. With
# max_rounds: 1, A opens and B answers.

# Each agent halts and reports to :report_to (the caller by default),
# so there are two reports per debate. A turn failure on either side
# halts both, and each reports. Wait for both, matching on the agent
# name so a report left over from an earlier debate is never taken:
results =
  for name <- [handle.a, handle.b] do
    receive do
      {:debate, ^name, :finished} -> :ok
      {:debate, ^name, {:failed, reason}} -> {:error, reason}
    end
  end

# Inspect live state:
GenAgent.status(handle.a)
GenAgent.status(handle.b)

# Read the transcript. Each agent stores its own statements and the
# opponent's as {speaker, text} in the order it saw them. There is no
# shared store, but once the debate finishes both agents hold the same
# ordered conversation, so either one will do:
%{agent_state: %{transcript: transcript}} = GenAgent.status(handle.a)

# Clean up:
GenAgent.stop(handle.a)
GenAgent.stop(handle.b)
```

`test/guides/debate_test.exs` compiles `Debate.Agent` and `Debate`
from this page and runs them on a local stub backend. It covers equal
turn counts at `max_rounds` of 1 and 3, delivery of the final
statement, a failed turn on either side, and transcript order.

## Variations

- **Asymmetric roles.** Nothing forces the two agents to share
  the same callback module. A "generator" agent could be
  `Debate.Agent` while a "critic" agent is a different module
  with a different system prompt style.
- **Different backends per side.** The debate module takes one
  `backend` option, but `start_agent/2` accepts one per side.
  A Claude-vs-Anthropic-HTTP debate works fine.
- **Moderator.** Add a third agent that subscribes to both sides'
  notifies and can interject. Requires passing the moderator's
  name into both debaters so they can cc it, or having the
  moderator tail telemetry.
- **More than two participants.** This pattern extends to N by
  having each agent hold a list of opponents and broadcast
  `{:opponent_said, text}` to all of them. Everyone reacts to
  everyone. Noisy at N>3 but works.
