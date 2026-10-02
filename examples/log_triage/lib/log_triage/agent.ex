defmodule LogTriage.Agent do
  @moduledoc "Accumulate log fingerprints and render each deferred drain at dispatch time."
  use GenAgent

  @impl true
  def init_agent(opts) do
    {:ok, Keyword.get(opts, :backend_opts, []),
     %{buffer: %{}, flush_queued: false, sink: Keyword.fetch!(opts, :sink)}}
  end

  @impl true
  def handle_event({:log, fingerprint, sample}, state)
      when is_binary(fingerprint) and is_binary(sample) and byte_size(sample) <= 480 do
    buffer =
      Map.update(state.buffer, fingerprint, {1, sample}, fn {count, first} ->
        {count + 1, first}
      end)

    state = %{state | buffer: buffer}

    if state.flush_queued,
      do: {:noreply, state},
      else: {:prompt, "FLUSH", %{state | flush_queued: true}}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def pre_turn("FLUSH", %{buffer: buffer} = state) when map_size(buffer) == 0,
    do: {:skip, %{state | flush_queued: false}}

  def pre_turn("FLUSH", state) do
    prompt =
      state.buffer
      |> Enum.sort()
      |> Enum.map_join("\n", fn {fingerprint, {count, sample}} ->
        "#{count}x #{fingerprint}: #{sample}"
      end)

    {:ok, prompt, %{state | buffer: %{}, flush_queued: false}}
  end

  @impl true
  def handle_response(_ref, response, state) do
    LogTriage.Sink.record(state.sink, response.text)
    {:noreply, state}
  end

  @impl true
  def handle_error(_ref, {:overloaded, %{queue: :prompts}}, state),
    do: {:noreply, %{state | flush_queued: false}}

  def handle_error(_ref, _reason, state), do: {:noreply, state}
end
