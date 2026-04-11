# Switchboard

Human-driven fleet of named long-lived agent sessions, each anchored
to a working directory, driven from iex or an MCP client.

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

## What it exercises in gen_agent

- `GenAgent.start_agent/2`, `tell/2`, `poll/2`, `notify/2`,
  `interrupt/1`, `halt/1`, `resume/1`, `stop/1` -- the full public
  API.
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

## The pattern

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
  charge. Notifications are used only to update the summary and
  advance the inbox cursor.
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
    backend_opts = Keyword.drop(opts, [:name, :backend])
    {:ok, backend_opts, %State{path: path}}
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

  def handle_event(:ack_inbox, %State{} = state) do
    {:noreply, %{state | inbox_cursor: length(state.history)}}
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

  Every function delegates to GenAgent.* and unwraps the
  SessionAgent.State struct from the returned agent_state.
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

  @doc "Non-blocking send. Returns {:ok, request_ref} or {:error, :busy}."
  def send(name, prompt) when is_binary(prompt) do
    case GenAgent.status(name) do
      %{state: :processing} -> {:error, :busy}
      %{halted: true} -> {:error, :halted}
      _ -> GenAgent.tell(name, prompt)
    end
  end

  @doc "Poll a previously-issued send."
  def poll(name, ref), do: GenAgent.poll(name, ref)

  @doc "Return new turns since the last `inbox(name, ack: true)`."
  def inbox(name, opts \\ []) do
    ack = Keyword.get(opts, :ack, false)

    case GenAgent.status(name) do
      %{agent_state: %SessionAgent.State{} = state} ->
        new_items = Enum.drop(state.history, state.inbox_cursor)
        if ack and new_items != [], do: GenAgent.notify(name, :ack_inbox)
        {:ok, %{new_requests: new_items, summary: state.summary}}

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Read the manager-curated summary."
  def summary_get(name) do
    case GenAgent.status(name) do
      %{agent_state: %SessionAgent.State{summary: s}} -> {:ok, s}
      _ -> {:error, :not_found}
    end
  end

  @doc "Update the manager-curated summary."
  def summary_update(name, markdown) when is_binary(markdown) do
    GenAgent.notify(name, {:update_summary, markdown})
  end

  @doc "Return the full turn history for a session."
  def transcript(name, opts \\ []) do
    case GenAgent.status(name) do
      %{agent_state: %SessionAgent.State{history: history}} ->
        limit = Keyword.get(opts, :limit)
        if is_integer(limit) and limit > 0, do: Enum.take(history, -limit), else: history

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Cancel the in-flight request on a session."
  def interrupt(name), do: GenAgent.interrupt(name)

  @doc "Halt a session (freezes mailbox; use resume/1 to unfreeze)."
  def halt(name), do: GenAgent.notify(name, {:switchboard, :halt})

  @doc "Resume a halted session."
  def resume(name), do: GenAgent.resume(name)

  @doc "Stop a session."
  def stop_session(name), do: GenAgent.stop(name)
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
{:ok, ref_a} = Switchboard.send("project-a", "what files are here?")
{:ok, ref_b} = Switchboard.send("project-b", "list tests in test/")

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
Switchboard.summary_update("project-a", "## Status\\nworking on auth.")

# Stop.
Switchboard.stop_session("project-a")
```

## Variations

- **Broadcast to many sessions.** Add a `broadcast/2` helper that
  enumerates the registry and calls `send/2` on each. Use
  `GenAgent.tell/2`'s natural mailbox queueing so you don't lose
  prompts against currently-busy sessions.
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
  (`switchboard_start_session`, `switchboard_send`, etc.) so any
  MCP host can drive the fleet.
