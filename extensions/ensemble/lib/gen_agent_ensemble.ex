defmodule GenAgentEnsemble do
  @moduledoc """
  A session process that owns N `GenAgent` sub-agents under a strategy.

  Where `GenAgent` gives you one process per LLM session, `GenAgentEnsemble`
  gives you one process per *logical* session -- the single-agent case
  is `GenAgentEnsemble.Strategies.Solo`, multi-agent patterns like
  Supervisor or Pool are other strategies.

  ## Public API

      {:ok, pid} = GenAgentEnsemble.start_link(
        name: "research-1",
        strategy: GenAgentEnsemble.Strategies.Solo,
        opts: [agent: {"worker-a", MyAgent, backend: GenAgent.Backends.Mock}]
      )

      {:ok, token} = GenAgentEnsemble.tell("research-1", "hello")
      {:ok, :pending} = GenAgentEnsemble.poll("research-1", token)
      # ...later...
      {:ok, :completed, response} = GenAgentEnsemble.poll("research-1", token)

      {:ok, response} = GenAgentEnsemble.ask("research-1", "quick question", timeout: 30_000)

  See `GenAgentEnsemble.Strategy` for how to implement your own strategy.
  """

  @doc """
  Start a new ensemble process. Takes `:name`, `:strategy`, and
  `:opts` (the strategy's own options keyword list).
  """
  defdelegate start_link(opts), to: GenAgentEnsemble.Server

  @doc """
  Fire-and-forget prompt. Returns `{:ok, token}` immediately; use
  `poll/2` or `inbox/1` to retrieve the response later.
  """
  defdelegate tell(name, prompt), to: GenAgentEnsemble.Server

  @doc """
  Like `tell/2` but with strategy-specific options (e.g.
  `agent: "alice"` for Switchboard).
  """
  defdelegate tell(name, prompt, opts), to: GenAgentEnsemble.Server

  @doc """
  Synchronous prompt. Blocks until the strategy replies or the
  default timeout expires.
  """
  defdelegate ask(name, prompt), to: GenAgentEnsemble.Server

  @doc """
  Like `ask/2` with options. Supports `timeout:` plus any
  strategy-specific keys (e.g. `agent:` for Switchboard).
  """
  defdelegate ask(name, prompt, opts), to: GenAgentEnsemble.Server

  @doc """
  Non-blocking check on a `tell`-minted token. Returns
  `{:ok, :pending}`, `{:ok, :completed, response}`, or
  `{:error, reason}`.
  """
  defdelegate poll(name, token), to: GenAgentEnsemble.Server

  @doc """
  Drain every completed `tell` token since the last call. Returns
  `{:ok, [{token, {:ok, response} | {:error, reason}}, ...]}`.
  """
  defdelegate inbox(name), to: GenAgentEnsemble.Server

  @doc """
  Send an asynchronous event to the strategy (`handle_notify/2`).
  """
  defdelegate notify(name, event), to: GenAgentEnsemble.Server

  @doc """
  Inspect the ensemble: running agents, strategy phase, queue depth.
  """
  defdelegate status(name), to: GenAgentEnsemble.Server

  @doc """
  Stop the ensemble. Sub-agents are terminated in the process.
  """
  defdelegate stop(name), to: GenAgentEnsemble.Server

  @doc """
  List the names of all running ensembles, sorted.

      iex> GenAgentEnsemble.list()
      ["qa-pool", "solo"]
  """
  @spec list() :: [String.t()]
  def list do
    GenAgentEnsemble.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end
end
