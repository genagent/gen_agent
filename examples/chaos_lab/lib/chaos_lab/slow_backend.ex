defmodule ChaosLab.SlowBackend do
  @moduledoc "A keyless stream with a release gate for deterministic fault injection."
  @behaviour GenAgent.Backend
  alias GenAgent.Event

  @impl true
  def start_session(opts) do
    session = %{observer: Keyword.fetch!(opts, :observer), id: make_ref(), turns: 0}
    send(session.observer, {:session_started, self(), session.id})
    {:ok, session}
  end

  @impl true
  def prompt(session, prompt) do
    send(session.observer, {:backend_prompt, self(), session.id, session.turns, prompt})

    stream =
      Stream.map(1..3, fn index ->
        if prompt == "crash", do: raise("Chaos Lab injected stream failure")

        if index == 2 and prompt == "hold" do
          receive do
            :release -> :ok
          after
            30_000 -> raise "Chaos Lab hold was never released"
          end
        end

        kind = if index == 3, do: :result, else: :text
        Event.new(kind, %{text: prompt, prompt: prompt})
      end)

    {:ok, stream, %{session | turns: session.turns + 1}}
  end

  @impl true
  def resume_session(_id, _opts) do
    raise "GenAgent unexpectedly called resume_session/2"
  end

  @impl true
  def terminate_session(session) do
    send(session.observer, {:terminated_session, self(), session.id})
    IO.puts("terminate_session: #{inspect(session.id)}")
    :ok
  end
end
