defmodule GenAgent.Structured.Files do
  @moduledoc false
  use GenServer

  # The file owner survives an individual session's forced death, so cleanup
  # does not depend solely on that session's terminate callback.
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def allocate(owner), do: GenServer.call(__MODULE__, {:allocate, owner})
  def release(owner), do: GenServer.call(__MODULE__, {:release, owner})
  def init(state), do: {:ok, state}

  def handle_call({:allocate, owner}, _from, state) do
    path =
      Path.join(
        System.tmp_dir!(),
        "gen-agent-contract-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      )

    case create_private_directory(path) do
      :ok ->
        monitor = Process.monitor(owner)
        {:reply, {:ok, path, self()}, Map.put(state, monitor, {owner, path})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, owner}, _from, state) do
    {removed, kept} = Enum.split_with(state, fn {_, {pid, _}} -> pid == owner end)

    for {monitor, {_, path}} <- removed do
      Process.demonitor(monitor, [:flush])
      File.rm_rf(path)
    end

    {:reply, :ok, Map.new(kept)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state, monitor) do
      {nil, rest} ->
        {:noreply, rest}

      {{_, path}, rest} ->
        File.rm_rf(path)
        {:noreply, rest}
    end
  end

  def terminate(_reason, state) do
    for {_, {_, path}} <- state, do: File.rm_rf(path)
    :ok
  end

  defp create_private_directory(path) do
    case File.mkdir(path) do
      :ok ->
        case File.chmod(path, 0o700) do
          :ok ->
            :ok

          error ->
            File.rmdir(path)
            error
        end

      error ->
        error
    end
  end
end
