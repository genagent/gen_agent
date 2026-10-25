defmodule GenAgent.Delegation.Worker do
  use GenAgent

  def init_agent(opts), do: {:ok, Keyword.fetch!(opts, :backend_opts), nil}
  def handle_response(_ref, _response, state), do: {:noreply, state}
end

defmodule GenAgent.Delegation.Echo do
  @behaviour GenAgent.Backend

  def start_session(_opts), do: {:ok, 0}

  def prompt(turn, prompt) do
    {:ok, [GenAgent.Event.new(:result, %{text: "echo: " <> prompt})], turn + 1}
  end

  def terminate_session(_session), do: :ok
end
