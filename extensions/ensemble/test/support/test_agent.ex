defmodule GenAgentEnsemble.TestAgent do
  @moduledoc false
  use GenAgent

  @impl true
  def init_agent(opts) do
    backend_opts = Keyword.take(opts, [:scripts, :session_id])
    {:ok, backend_opts, %{}}
  end

  @impl true
  def handle_response(_ref, _response, state), do: {:noreply, state}
end
