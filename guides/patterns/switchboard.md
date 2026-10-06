# Switchboard

Human-driven fleet of named, long-lived agent sessions. The shipped
Ensemble strategy routes each call to the named agent chosen by its
caller. The callback recipe later on this page adds per-session
history, summary, and inbox-cursor state in an application facade.

## Using it from `gen_agent_ensemble`

`GenAgentEnsemble.Strategies.Switchboard` owns the named agents and
their routing. Pass `agent:` on every `ask` or `tell` call; there is no
implicit default.

```elixir
simple = GenAgentEnsemble.Agents.Simple
echo = GenAgentEnsemble.Backends.Echo

{:ok, _pid} =
  GenAgentEnsemble.start_link(
    name: "reviewers",
    strategy: GenAgentEnsemble.Strategies.Switchboard,
    opts: [agents: [{"alice", simple, backend: echo}, {"bob", simple, backend: echo}]]
  )

{:ok, response} = GenAgentEnsemble.ask("reviewers", "review this", agent: "alice")
```

The rest of this page is a separate callback-level reference
implementation. Read the shipped strategy's module documentation for
its exact routing and failure behavior.

## When to reach for this

You want to sit "above" a pile of agents and talk to them
imperatively. A manager (a human, an MCP host, or both) starts
sessions on demand, sends prompts, polls for results, curates a
summary per session, and advances an inbox cursor to see what's new.
The agents themselves are dumb on purpose -- every turn is a plain
`{:noreply, state}` and the intelligence lives in the manager.

This is the closest pattern to what people build when they first
reach for gen_agent: "I want my chat loop but for N concurrent
sessions, non-blocking."

## What the callback recipe exercises

- `GenAgent.start_agent/2`, `tell/2`, `poll/2`, `status/1`,
  `notify_ack/2`, `interrupt/1`, `resume/1`, and `stop/1`. Halting
  uses a notification whose `handle_event/2` returns `{:halt, state}`.
- `handle_response/3` and `handle_error/3` returning plain
  `{:noreply, state}` every time. The agent never self-chains and
  never halts on its own.
- `handle_event/2` used only for manager-to-agent commands
  (`:update_summary`, `:ack_inbox`, `:halt`).
- Per-session history, inbox cursor, and manager-curated summary
  all live in the callback module's state.
- Telemetry events (`[:gen_agent, :state, :changed]`,
  `[:gen_agent, :prompt, :start|:stop|:error]`, etc.) tailed from
  the manager side as a live feed.

## Callback reference implementation

Two modules: a `SessionAgent` callback module that holds the
per-session state, and a `Switchboard` facade that exposes a flat
set of manager-facing functions over `GenAgent.*`.

### `Switchboard.SessionAgent`

```elixir
defmodule Switchboard.SessionAgent do
  @moduledoc """
  GenAgent implementation for a single switchboard session.

  One process per session, anchored to a cwd, holding:

    * `path` -- the directory the session operates in
    * `summary` -- a manager-curated markdown string
    * `history` -- append-only list of completed turns
    * `inbox_cursor` -- index into history marking the last ack

  The agent never self-chains and never halts on its own. Every
  turn is a plain `{:noreply, state}` so the manager stays in
  charge. Manager notifications update the summary, acknowledge the
  inbox, or halt the session.
  """

  use GenAgent

  defmodule State do
    @moduledoc false
    defstruct path: nil,
              summary: "",
              history: [],
              inbox_cursor: 0,
              next_seq: 1
  end

  @impl true
  def init_agent(opts) do
    path = Keyword.fetch!(opts, :cwd)
    {:ok, opts, %State{path: path}}
  end

  @impl true
  def handle_response(ref, response, %State{} = state) do
    entry = %{
      status: :ok,
      seq: state.next_seq,
      ref: ref,
      text: response.text,
      usage: response.usage,
      duration_ms: response.duration_ms,
      completed_at: System.system_time(:millisecond)
    }

    {:noreply,
     %{state | history: state.history ++ [entry], next_seq: state.next_seq + 1}}
  end

  @impl true
  def handle_error(ref, reason, %State{} = state) do
    entry = %{
      status: :failed,
      seq: state.next_seq,
      ref: ref,
      error: reason,
      completed_at: System.system_time(:millisecond)
    }

    {:noreply,
     %{state | history: state.history ++ [entry], next_seq: state.next_seq + 1}}
  end

  @impl true
  def handle_event({:update_summary, markdown}, %State{} = state)
      when is_binary(markdown) do
    {:noreply, %{state | summary: markdown}}
  end

  def handle_event({:ack_inbox, seen}, %State{} = state) do
    {:noreply, %{state | inbox_cursor: max(state.inbox_cursor, seen)}}
  end

  def handle_event({:switchboard, :halt}, %State{} = state) do
    {:halt, state}
  end

  def handle_event(_other, state), do: {:noreply, state}
end
```

### `Switchboard` facade

```elixir
defmodule Switchboard do
  @moduledoc """
  Manager-facing API over Switchboard.SessionAgent.

  Synchronous operations return {:error, :not_found} for missing names.
  Other exits (including timeouts and crashes) propagate. State readers
  return {:error, :not_session} for another callback's state.

  interrupt/1 and resume/1 are best-effort casts: :ok does not confirm
  that a session exists. Names belong to the application; do not reuse
  a name for a replacement session while operations are in flight.
  """

  alias Switchboard.SessionAgent

  @doc "Start a session anchored to a cwd."
  def start_session(name, opts) when is_binary(name) and is_list(opts) do
    path = Keyword.fetch!(opts, :path)
    backend = Keyword.fetch!(opts, :backend)

    start_opts =
      opts
      |> Keyword.delete(:path)
      |> Keyword.put(:cwd, path)
      |> Keyword.put(:name, name)
      |> Keyword.put(:backend, backend)

    case GenAgent.start_agent(SessionAgent, start_opts) do
      {:ok, _pid} -> {:ok, name}
      err -> err
    end
  end

  @doc """
  Submit without waiting for completion. Returns {:ok, request_ref},
  {:error, {:overloaded, info}}, or {:error, :not_found}.
  Busy sessions queue prompts; halted sessions queue until resume/1.
  Admission is decided by tell/2 in one call, with no status preflight.
  """
  def submit(name, prompt) when is_binary(prompt) do
    call(fn -> GenAgent.tell(name, prompt) end)
  end

  @doc "Submit to application-owned names, retaining every admission outcome."
  def broadcast(names, prompt) do
    Enum.map(names, fn name -> {name, submit(name, prompt)} end)
  end

  @doc "Poll a previously submitted request; a missing name or ref returns not_found."
  def poll(name, ref), do: call(fn -> GenAgent.poll(name, ref) end)

  @doc """
  Return {:ok, %{new_requests: turns, summary: markdown}} from a snapshot.
  With ack: true, acknowledge only that snapshot's cursor. A turn still
  in flight remains unread. Admission may be deferred; repeated reads
  can return the same turns until the acknowledgment is applied.
  Returns {:error, {:overloaded, info}} if acknowledgment is rejected.
  """
  def inbox(name, opts \\ []) do
    with {:ok, state} <- session_state(name) do
      new_items = Enum.drop(state.history, state.inbox_cursor)
      seen = length(state.history)

      result =
        if Keyword.get(opts, :ack, false) and new_items != [] do
          call(fn -> GenAgent.notify_ack(name, {:ack_inbox, seen}) end)
        else
          :ok
        end

      with :ok <- result do
        {:ok, %{new_requests: new_items, summary: state.summary}}
      end
    end
  end

  @doc "Read the manager-curated summary as {:ok, markdown}."
  def summary_get(name) do
    with {:ok, state} <- session_state(name), do: {:ok, state.summary}
  end

  @doc """
  Update the summary. Returns :ok on admission (possibly deferred),
  {:error, {:overloaded, info}}, or {:error, :not_found}.
  """
  def summary_update(name, markdown) when is_binary(markdown) do
    call(fn -> GenAgent.notify_ack(name, {:update_summary, markdown}) end)
  end

  @doc "Return {:ok, history}, optionally limited to the last positive limit turns."
  def transcript(name, opts \\ []) do
    with {:ok, state} <- session_state(name) do
      limit = Keyword.get(opts, :limit)
      history = state.history
      {:ok, if(is_integer(limit) and limit > 0, do: Enum.take(history, -limit), else: history)}
    end
  end

  @doc "Cancel the in-flight request. Cast returns :ok even for a missing name."
  def interrupt(name), do: GenAgent.interrupt(name)

  @doc """
  Request a halt; an in-flight turn finishes before this takes effect.
  Prompts queue until resume/1. Returns :ok on admission (possibly
  deferred), {:error, {:overloaded, info}}, or {:error, :not_found}.
  """
  def halt(name), do: call(fn -> GenAgent.notify_ack(name, {:switchboard, :halt}) end)

  @doc "Resume a halted session. Cast returns :ok even for a missing name."
  def resume(name), do: GenAgent.resume(name)

  @doc "Stop a session; returns :ok or {:error, :not_found}."
  def stop_session(name), do: call(fn -> GenAgent.stop(name) end)

  defp session_state(name) do
    case call(fn -> GenAgent.status(name) end) do
      %{agent_state: %SessionAgent.State{} = state} -> {:ok, state}
      {:error, _} = error -> error
      _ -> {:error, :not_session}
    end
  end

  defp call(fun) do
    fun.()
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end
end
```

## Using it

```elixir
# Start two sessions anchored to different projects.
{:ok, "project-a"} = Switchboard.start_session("project-a",
  path: "/path/to/project-a",
  backend: GenAgent.Backends.Claude
)

{:ok, "project-b"} = Switchboard.start_session("project-b",
  path: "/path/to/project-b",
  backend: GenAgent.Backends.Claude
)

# Non-blocking prompts.
{:ok, ref_a} = Switchboard.submit("project-a", "what files are here?")
{:ok, ref_b} = Switchboard.submit("project-b", "list tests in test/")

# Poll.
Switchboard.poll("project-a", ref_a)
# => {:ok, :pending}
# ... later ...
Switchboard.poll("project-a", ref_a)
# => {:ok, :completed, %GenAgent.Response{text: "..."}}

# Inbox -- peek then ack.
Switchboard.inbox("project-a")
Switchboard.inbox("project-a", ack: true)

# Manager-curated summary.
Switchboard.summary_update("project-a", "## Status\nworking on auth.")

# Stop.
Switchboard.stop_session("project-a")
```

## Variations

- **Broadcast to many sessions.** Use `Switchboard.broadcast(names, prompt)`
  with session names tracked by your application. Each name is paired
  with its `submit/2` result, including missing-name and overload errors.
  Busy sessions queue accepted prompts; halted sessions wait for resume.
  Broadcast admission is per session, not atomic across the fleet.
- **Live telemetry tail.** Attach a telemetry handler to
  `[:gen_agent, :prompt, :start|:stop|:error]` and
  `[:gen_agent, :state, :changed]` and print one line per event
  across every registered session. Useful as a "what's happening
  right now" view from the manager side.
- **Persistence across restarts.** SQLite via Ecto for
  sessions/requests/events/summaries. Reload sessions into the
  supervision tree at startup, mark any previously in-flight
  requests as `:interrupted`.
- **MCP surface.** Expose the facade functions as MCP tools
  (`switchboard_start_session`, `switchboard_submit`, etc.) so any
  MCP host can drive the fleet.
