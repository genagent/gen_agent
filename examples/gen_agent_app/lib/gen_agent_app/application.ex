defmodule GenAgentApp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    name = Application.fetch_env!(:gen_agent_app, :session_name)
    agents = Application.fetch_env!(:gen_agent_app, :agents)

    if agents == [] do
      raise ArgumentError, "GenAgentApp requires at least one configured agent"
    end

    children = [
      {GenAgentEnsemble.Server,
       name: name, strategy: GenAgentEnsemble.Strategies.Switchboard, opts: [agents: agents]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GenAgentApp.Supervisor)
  end
end
