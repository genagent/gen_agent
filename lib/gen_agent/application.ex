defmodule GenAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: GenAgent.Registry},
      {Task.Supervisor, name: GenAgent.TaskSupervisor},
      {DynamicSupervisor, name: GenAgent.AgentSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: GenAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
