defmodule LogTriage.Sink do
  @moduledoc "Records incident notes and counts notification admission drops without logging."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def record(sink, note), do: GenServer.call(sink, {:record, note})
  def snapshot(sink), do: GenServer.call(sink, :snapshot)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(id, [:gen_agent, :input, :rejected], &__MODULE__.rejected/4, %{
        sink: self(),
        agent: Keyword.fetch!(opts, :agent)
      })

    {:ok, %{notes: [], drops: 0, telemetry_id: id, observer: opts[:observer]}}
  end

  def rejected(_event, _measurements, metadata, %{agent: agent, sink: sink}) do
    case metadata do
      %{agent: ^agent, reason: {:overloaded, %{queue: :notifications}}} ->
        send(sink, {:drop, metadata})

      _ ->
        :ok
    end
  end

  @impl true
  def handle_call({:record, note}, _from, state) do
    if state.observer, do: send(state.observer, {:note, note})
    {:reply, :ok, %{state | notes: [note | state.notes]}}
  end

  def handle_call(:snapshot, _from, state),
    do: {:reply, %{notes: Enum.reverse(state.notes), drops: state.drops}, state}

  @impl true
  def handle_info({:drop, metadata}, state) do
    if state.observer, do: send(state.observer, {:drop, metadata})
    {:noreply, %{state | drops: state.drops + 1}}
  end

  @impl true
  def terminate(_reason, state), do: :telemetry.detach(state.telemetry_id)
end
