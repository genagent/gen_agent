defmodule GenAgentApp do
  @moduledoc """
  One local entry point for the configured Claude, Codex, or Echo agents.

  This example delegates to an application-owned Switchboard ensemble. Agent
  behavior remains in the configured callback module; this module only routes
  requests and returns the underlying GenAgent responses.
  """

  def session_name, do: Application.fetch_env!(:gen_agent_app, :session_name)

  def agents do
    with {:ok, %{agents: names}} <- status(), do: {:ok, names}
  end

  def status, do: GenAgentEnsemble.status(session_name())

  def ask(agent, prompt, opts \\ []) do
    GenAgentEnsemble.ask(session_name(), prompt, Keyword.put(opts, :agent, agent))
  end

  def tell(agent, prompt, opts \\ []) do
    GenAgentEnsemble.tell(session_name(), prompt, Keyword.put(opts, :agent, agent))
  end

  def poll(token), do: GenAgentEnsemble.poll(session_name(), token)
  def inbox, do: GenAgentEnsemble.inbox(session_name())
end
