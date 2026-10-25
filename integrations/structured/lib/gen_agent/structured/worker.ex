defmodule GenAgent.Structured.Worker do
  @moduledoc false
  use GenAgent

  def init_agent(opts), do: {:ok, Keyword.fetch!(opts, :backend_opts), nil}
  def handle_response(_ref, _response, state), do: {:noreply, state}
end
