defmodule GenAgentEnsemble.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: GenAgentEnsemble.Registry},
      {Registry, keys: :unique, name: GenAgentEnsemble.AgentTreeRegistry},
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

    # child_spec/1 validates the required name in this caller. Preserve the
    # configured startup path's warn-and-continue behavior for a missing name.
    result =
      case Keyword.fetch(config, :name) do
        {:ok, _name} ->
          DynamicSupervisor.start_child(GenAgentEnsemble.Supervisor, {GenAgentEnsemble, config})

        :error ->
          {:error, :missing_name}
      end

    case result do
      {:ok, _pid} ->
        Logger.info("[gen_agent_ensemble] started configured ensemble: #{inspect(name)}")

      {:error, reason} ->
        Logger.warning(
          "[gen_agent_ensemble] failed to start #{inspect(name)} (#{inspect(failure_kind(reason))})"
        )
    end
  end

  defp failure_kind(reason) when is_atom(reason), do: reason
  defp failure_kind({kind, _}) when is_atom(kind), do: kind
  defp failure_kind({kind, _, _}) when is_atom(kind), do: kind
  defp failure_kind(_), do: :other
end
