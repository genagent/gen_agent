defmodule GenAgentEnsemble.ControlledAgent do
  @moduledoc false
  use GenAgent

  @impl true
  def init_agent(opts), do: {:ok, Keyword.take(opts, [:observer, :tag]), %{}}

  @impl true
  def handle_response(_ref, _response, state), do: {:noreply, state}
end
