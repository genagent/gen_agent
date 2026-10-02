defmodule LogTriage.Demo do
  @moduledoc "Crash disposable GenServers and print the node's incident notes."
  use GenServer

  def run do
    for _ <- 1..3, failure <- [:raise, :match, :exit] do
      {:ok, pid} = GenServer.start(__MODULE__, nil)
      ref = Process.monitor(pid)
      GenServer.cast(pid, failure)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end

    # Logger delivery and backend completion are asynchronous. This is only a
    # display delay for the interactive demo; tests use explicit gates.
    Process.sleep(500)
    %{notes: notes, drops: drops} = LogTriage.Sink.snapshot(LogTriage.Sink)
    Enum.each(notes, &IO.puts/1)
    IO.puts("Notification drops: #{drops}")
    :ok
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:raise, _state), do: raise("demo worker failed")

  def handle_cast(:match, state) do
    {:ok, value} = state
    {:noreply, value}
  end

  def handle_cast(:exit, _state), do: exit(:demo_exit)
end
