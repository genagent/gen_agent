defmodule LogTriage.Handler do
  @moduledoc "Owns an OTP logger handler that forwards compact reports through notify/2."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :id)
    config = %{level: :error, config: %{agent: Keyword.fetch!(opts, :agent)}}

    case :logger.add_handler(id, __MODULE__, config) do
      :ok -> {:ok, id}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, id), do: :logger.remove_handler(id)

  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok

  def log(%{level: level, meta: meta, msg: message}, %{config: %{agent: agent}})
      when level in [:error, :critical, :alert, :emergency] do
    unless Map.has_key?(meta, :log_triage) or gen_agent?(meta) do
      {fingerprint, sample} = reduce(message)
      GenAgent.notify(agent, {:log, fingerprint, sample})
    end

    :ok
  end

  def log(_event, _config), do: :ok

  defp gen_agent?(meta) do
    meta[:application] == :gen_agent or
      case meta[:mfa] do
        {module, _, _} when is_atom(module) ->
          module == GenAgent or String.starts_with?(Atom.to_string(module), "Elixir.GenAgent.")

        _ ->
          false
      end
  end

  @doc "Keep crash identity, omitting process state, PID, timestamps and report callbacks."
  def reduce(message) do
    sample =
      message
      |> identity()
      |> inspect(limit: 20, printable_limit: 300, width: :infinity)
      |> String.replace(~r/#PID<[^>]+>/, "<pid>")
      |> String.replace(~r/#Reference<[^>]+>/, "<ref>")
      |> String.slice(0, 120)

    {Base.encode16(:erlang.md5(sample), case: :lower), sample}
  end

  defp identity({:report, %{label: label, reason: reason}}), do: {label, reason}

  defp identity({:report, %{label: label, report: [crash | _]}}) when is_list(crash),
    do: {label, Keyword.get(crash, :error_info)}

  defp identity({:report, report}) when is_map(report),
    do: Map.drop(report, [:pid, :time, :timestamp, :state, :report_cb])

  defp identity(message), do: message
end
