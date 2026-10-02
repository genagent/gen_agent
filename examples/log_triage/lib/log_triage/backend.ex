defmodule LogTriage.Backend do
  @moduledoc "A deterministic, keyless backend with an optional explicit test gate."
  @behaviour GenAgent.Backend

  @impl true
  def start_session(opts), do: {:ok, opts}

  @impl true
  def prompt(session, prompt) do
    if observer = session[:observer], do: send(observer, {:turn_started, prompt, self()})

    if session[:hold] do
      receive do
        :release -> :ok
      end
    end

    lines = String.split(prompt, "\n", trim: true)

    count =
      Enum.reduce(lines, 0, fn line, total ->
        {count, _rest} = Integer.parse(line)
        total + count
      end)

    note =
      "Incident: #{count} reports across #{length(lines)} fingerprints. " <>
        "Inspect the failing callbacks and their inputs.\n" <>
        Enum.map_join(Enum.take(lines, 3), "\n", &String.slice(&1, 0, 180))

    {:ok, [GenAgent.Event.new(:result, %{text: note})], session}
  end

  @impl true
  def terminate_session(_session), do: :ok
end
