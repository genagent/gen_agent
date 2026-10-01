defmodule GenAgentEnsemble.AgentTree do
  @moduledoc false

  use Supervisor

  def start_link(session_name) do
    with :ok <- await_previous_tree(session_name) do
      Supervisor.start_link(__MODULE__, [], name: via(session_name))
    end
  end

  defp await_previous_tree(session_name) do
    case Registry.lookup(GenAgentEnsemble.AgentTreeRegistry, session_name) do
      [] ->
        :ok

      [{previous, _}] ->
        ref = Process.monitor(previous)

        receive do
          {:DOWN, ^ref, :process, ^previous, _reason} -> :ok
        after
          10_000 ->
            Process.demonitor(ref, [:flush])
            {:error, {:previous_agent_tree_still_running, session_name}}
        end
    end
  end

  defp via(session_name) do
    {:via, Registry, {GenAgentEnsemble.AgentTreeRegistry, session_name}}
  end

  def supervisors(tree) do
    children =
      tree
      |> Supervisor.which_children()
      |> Map.new(fn {id, pid, _type, _modules} -> {id, pid} end)

    {Map.fetch!(children, :tasks), Map.fetch!(children, :agents)}
  end

  @impl true
  def init(_opts) do
    children = [
      Supervisor.child_spec({Task.Supervisor, []}, id: :tasks),
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one}, id: :agents)
    ]

    # Server holds these PIDs. A supervisor restart would leave it routing to
    # stale children, so let the linked Server fail with the tree instead.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 0)
  end
end
