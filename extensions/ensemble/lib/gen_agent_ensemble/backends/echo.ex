defmodule GenAgentEnsemble.Backends.Echo do
  @moduledoc """
  A trivial always-compiled `GenAgent.Backend` for demos and iex
  experimentation.

  Each prompt turn emits a single `:result` event whose text is
  derived from the prompt. No external dependencies, no API keys,
  no subprocess -- makes it possible to wire up an ensemble and
  exercise `GenAgentEnsemble.ask/2` or `tell/2` end-to-end from a
  fresh `iex -S mix` session with zero setup.

  Not for production use. For real work, reach for
  `GenAgent.Backends.Anthropic`, `GenAgent.Backends.Claude`,
  `GenAgent.Backends.OpenAI`, or `GenAgent.Backends.Codex`.

  ## Options

    * `:transform` -- a function `(String.t() -> String.t())` that
      maps the prompt text to the response text. Defaults to
      prepending `"echo: "`.
    * `:delay_ms` -- milliseconds to sleep before emitting the
      response. Useful for simulating a slow backend during iex
      prototyping. Default: `0`.

  ## Example

      {:ok, _} =
        GenAgentEnsemble.start_link(
          name: "echo",
          strategy: GenAgentEnsemble.Strategies.Solo,
          opts: [
            agent: {"w", GenAgentEnsemble.Agents.Simple,
                    backend: GenAgentEnsemble.Backends.Echo,
                    transform: &String.upcase/1,
                    delay_ms: 500}
          ]
        )
      {:ok, %{text: "HELLO"}} = GenAgentEnsemble.ask("echo", "hello")
  """

  @behaviour GenAgent.Backend

  alias GenAgent.Event

  defstruct transform: nil, delay_ms: 0

  @type t :: %__MODULE__{
          transform: (String.t() -> String.t()),
          delay_ms: non_neg_integer()
        }

  @impl true
  def start_session(opts) do
    transform = Keyword.get(opts, :transform, &default_transform/1)
    delay_ms = Keyword.get(opts, :delay_ms, 0)
    {:ok, %__MODULE__{transform: transform, delay_ms: delay_ms}}
  end

  @impl true
  def prompt(%__MODULE__{} = session, prompt) when is_binary(prompt) do
    if session.delay_ms > 0, do: Process.sleep(session.delay_ms)
    text = session.transform.(prompt)
    {:ok, [Event.new(:result, %{text: text})], session}
  end

  @impl true
  def update_session(%__MODULE__{} = session, _data), do: session

  @impl true
  def terminate_session(%__MODULE__{}), do: :ok

  defp default_transform(prompt), do: "echo: " <> prompt
end
