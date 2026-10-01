defmodule GenAgentEnsemble.ControlledBackend do
  @moduledoc false
  @behaviour GenAgent.Backend

  alias GenAgent.Event

  @impl true
  def start_session(opts), do: {:ok, opts}

  @impl true
  def terminate_session(_session), do: :ok

  @impl true
  def prompt(session, prompt) do
    send(session[:observer], {:controlled_prompt, session[:tag], prompt, self()})

    receive do
      {:result, text} -> {:ok, [Event.new(:result, %{text: text})], session}
      {:error, reason} -> {:error, reason}
    after
      5_000 -> {:error, :fixture_timeout}
    end
  end
end
