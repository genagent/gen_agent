defmodule ConsensusReview.ScriptedBackend do
  @moduledoc """
  Keyless backend that consumes one reply per prompt from `:script`.

  Replies are strings or functions receiving the prompt and returning a string.
  Exhaustion returns `{:error, :script_exhausted}` to expose unexpected turns.
  Each agent owns its script in its backend session.
  """
  @behaviour GenAgent.Backend

  @impl true
  def start_session(opts), do: {:ok, Keyword.fetch!(opts, :script)}

  @impl true
  def prompt([], _prompt), do: {:error, :script_exhausted}

  def prompt([reply | rest], prompt) do
    text = if is_function(reply, 1), do: reply.(prompt), else: reply
    {:ok, [GenAgent.Event.new(:result, %{text: text})], rest}
  end

  @impl true
  def update_session(session, _data), do: session

  @impl true
  def terminate_session(_session), do: :ok
end
