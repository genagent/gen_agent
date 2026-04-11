# Debate

Two agents with opposing roles pushing each other forward via
cross-agent `notify`. No orchestrator, no shared state. Each side
drives the conversation by reacting to the other until both reach
a round cap and halt together.

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

## What it exercises in gen_agent

- **Cross-agent `GenAgent.notify/2`** from inside
  `handle_response/3` -- the "I just finished my turn, now it's
  your turn" pass.
- **`handle_event/2` returning `{:prompt, text, state}`** -- the
  "I received your turn, here's what I'll say next" translation
  from an incoming event into a dispatched prompt.
- **Mutual halt coordination**: when one side reaches its round
  cap, it notifies the other with `{:debate, :done}` so both
  halt together.
- **Two simultaneous agents with independent sessions**,
  potentially on different backends, each with their own system
  prompt.

## The pattern

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
      round: 0,
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
      max_rounds: Keyword.fetch!(opts, :max_rounds)
    }

    system = """
    You are debating the topic: "#{state.topic}".

    Your role: #{state.role}.

    Keep each response to 2-3 sentences. Be direct and specific.
    Stay in character. Do not summarize the opponent's point --
    just rebut or extend the argument.
    """

    {:ok, [system: system, max_tokens: Keyword.get(opts, :max_tokens, 200)], state}
  end

  @impl true
  def handle_response(_ref, response, %State{} = state) do
    text = String.trim(response.text)
    new_round = state.round + 1
    new_state = %{state | round: new_round, transcript: state.transcript ++ [{state.name, text}]}

    cond do
      new_round >= state.max_rounds ->
        # Our last say. Tell the opponent to wrap up too and halt.
        GenAgent.notify(state.opponent, {:debate, :done})
        {:halt, new_state}

      true ->
        # Pass the ball.
        GenAgent.notify(state.opponent, {:opponent_said, text})
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_event({:opponent_said, text}, %State{} = state) do
    prompt = ~s"""
    Your opponent just said: "#{text}"

    Respond briefly, staying in your role.
    """

    {:prompt, prompt, state}
  end

  def handle_event({:debate, :done}, %State{} = state) do
    # Opponent asked us to stop. Halt if we have not already.
    {:halt, state}
  end

  def handle_event(_other, state), do: {:noreply, state}
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

    shared = [backend: backend, topic: topic, max_rounds: max_rounds]

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

# Inspect live state:
GenAgent.status(handle.a)
GenAgent.status(handle.b)

# Read the interleaved transcript:
%{agent_state: %{transcript: transcript_a}} = GenAgent.status(handle.a)
%{agent_state: %{transcript: transcript_b}} = GenAgent.status(handle.b)

# Clean up:
GenAgent.stop(handle.a)
GenAgent.stop(handle.b)
```

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
