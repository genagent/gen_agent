defmodule GenAgentEnsemble.StreamingBackend do
  @moduledoc false
  @behaviour GenAgent.Backend

  alias GenAgent.Event

  @impl true
  def start_session(opts), do: {:ok, opts}

  @impl true
  def terminate_session(_session), do: :ok

  @impl true
  def prompt(session, prompt) do
    stream =
      Stream.flat_map([:first, :gate], fn
        :first ->
          [Event.new(:text, %{text: prompt})]

        :gate ->
          send(session[:observer], {:stream_gate, session[:tag], self()})

          receive do
            :release ->
              [Event.new(:text, %{text: "tail"}), Event.new(:result, %{text: "done"})]

            {:error, reason} ->
              [Event.new(:error, %{reason: reason})]
          after
            5_000 -> raise "stream fixture timed out"
          end
      end)

    {:ok, stream, session}
  end
end
