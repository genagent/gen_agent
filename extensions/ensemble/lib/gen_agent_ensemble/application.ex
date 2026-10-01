defmodule GenAgentEnsemble.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: GenAgentEnsemble.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: GenAgentEnsemble.Supervisor}
    ]

    opts = [strategy: :one_for_one, name: GenAgentEnsemble.RootSupervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        start_configured_ensembles()
        {:ok, pid}

      error ->
        error
    end
  end

  defp start_configured_ensembles do
    :gen_agent_ensemble
    |> Application.get_env(:ensembles, [])
    |> Enum.each(&start_one/1)
  end

  defp start_one(config) do
    name = Keyword.get(config, :name, "<unnamed>")

    case DynamicSupervisor.start_child(
           GenAgentEnsemble.Supervisor,
           {GenAgentEnsemble.Server, config}
         ) do
      {:ok, _pid} ->
        Logger.info("[gen_agent_ensemble] started configured ensemble: #{inspect(name)}")

      {:error, reason} ->
        Logger.warning(
          "[gen_agent_ensemble] failed to start #{inspect(name)}: #{inspect(reason)}"
        )
    end
  end
end
