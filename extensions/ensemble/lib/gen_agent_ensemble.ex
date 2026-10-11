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
        opts: [
          agent:
            {"worker-a", GenAgentEnsemble.Agents.Simple,
             backend: GenAgentEnsemble.Backends.Echo}
        ]
      )

      {:ok, token} = GenAgentEnsemble.tell("research-1", "hello")
      {:ok, response} = GenAgentEnsemble.await("research-1", token)
      {:ok, :completed, ^response} = GenAgentEnsemble.poll("research-1", token)

      {:ok, response} = GenAgentEnsemble.ask("research-1", "quick question", timeout: 30_000)

  See `GenAgentEnsemble.Strategy` for how to implement your own strategy.
  """

  @doc """
  Start a new ensemble process. Takes `:name`, `:strategy`, and
  `:opts` (the strategy's own options keyword list).

  The session is linked to its caller and stops when that caller exits,
  including normally. Runtime shutdown waits for the owned agent tree;
  each sub-agent's configured `:shutdown` budget still applies. The session's
  supervisor child spec uses `shutdown: :infinity` so it does not cut those
  budgets short. Termination observers should return promptly; a blocking
  observer or an infinite child shutdown budget can prolong cleanup indefinitely.
  Forced kills can still skip termination callbacks.
  """
  defdelegate start_link(opts), to: GenAgentEnsemble.Server

  @doc """
  Return a child specification for supervising an ensemble with
  `{GenAgentEnsemble, opts}`. Accepts the same options as `start_link/1`,
  including the required `:name`.

  The child ID is `{GenAgentEnsemble, name}`, allowing distinct named
  ensembles under one supervisor without creating atoms. Restart is
  `:transient`: explicit stops and strategy halts stay stopped, while
  abnormal exits restart the ensemble. Shutdown is `:infinity` so the
  owned agent tree can finish within its configured shutdown budgets.

  Use `Supervisor.child_spec/2` to override these defaults when needed.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: :infinity,
      type: :worker
    }
  end

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
  Like `tell/3`, returning `{:ok, token}`, with one terminal message sent to
  the supplied PID:

      {:gen_agent_ensemble, :completion, session, token, {:ok, response} | {:error, reason}}

  The recipient defaults to the caller. It must be a PID (otherwise raises
  `FunctionClauseError`).
  Notification does not consume the result stored for `poll/2` or `inbox/1`.
  Halt delivers `{:error, {:halted, reason}}` before stopping the session;
  stored results are unavailable after the session terminates.
  """
  def tell_with_completion(name, prompt, recipient \\ self(), opts \\ []),
    do: GenAgentEnsemble.Server.tell_with_completion(name, prompt, recipient, opts)

  @doc """
  Wait for an existing tell token without consuming its result.

  Returns `{:ok, response}` or `{:error, reason}`. All registered waiters
  receive the terminal result. `poll/2` and `inbox/1` still consume the
  stored copy; an await processed after consumption returns
  `{:error, :not_found}`, as does an unknown token. Server message order
  determines races between registration, completion, and consumption.

  Timeout is a non-negative number of milliseconds or `:infinity`, default
  30_000. Zero checks the current result without waiting. Expiry returns
  `{:error, :timeout}` and removes only this waiter; a late result can still
  be retrieved. Invalid timeouts raise `FunctionClauseError`.
  Unavailable or terminated sessions retain normal `GenServer.call/3` exit
  semantics. Halt replies to registered waiters before stopping the session.
  """
  defdelegate await(name, token, timeout \\ 30_000), to: GenAgentEnsemble.Server

  @doc """
  Cancel one pending token without stopping the ensemble or unrelated work.

  Returns `{:ok, :cancelled}` when child requests acknowledge cancellation,
  or `{:ok, :cancelled_unconfirmed}` when any child result is uncertain or
  unsupported. Both close the token with `{:error, :cancelled}` through the
  usual ask reply, tell completion, await, and poll/inbox paths. Late child
  events are fenced. Acknowledgement covers BEAM/request cancellation, not
  settlement of an external provider process.

  Returns `{:error, :already_finished}` for a retained result or a completion
  that wins the race, `{:error, :not_found}` for unknown/consumed tokens
  (including finished asks), and `{:error, :unsupported}` when the strategy
  lacks `handle_cancel/2`. Unsupported strategies are left unchanged.
  """
  defdelegate cancel(name, token), to: GenAgentEnsemble.Server

  @doc """
  Synchronous prompt. Blocks until the strategy replies or the
  default timeout expires. See `ask/3` for timeout semantics.
  """
  defdelegate ask(name, prompt), to: GenAgentEnsemble.Server

  @doc """
  Like `ask/2` with options. Supports `timeout:` plus any
  strategy-specific keys (e.g. `agent:` for Switchboard).

  ## Timeout

  The timeout is a non-negative integer of milliseconds or `:infinity`.
  Precedence: the per-call `timeout:` option, then the application
  environment (`config :gen_agent_ensemble, ask_timeout: 120_000`), then
  the compatibility default of 30_000. The selected value is validated
  before any work is submitted; invalid values (including an invalid
  application setting) raise `ArgumentError`.

  Expiry is a `GenServer.call/3` timeout: the **calling process exits**
  with `{:timeout, {GenServer, :call, _}}` (catch it if needed). The timeout
  itself does **not** cancel the work, and a late reply is not delivered to
  the caller as a result. The ensemble and its agents keep running the
  request only if the ensemble survives: the caller catches the exit, or the
  ensemble is owned by a separate process (such as a supervisor). If the
  uncaught exit kills the process that called `start_link/1`, the ensemble
  stops with that owner, along with its agents and in-flight work.
  Use `cancel/2` with a `tell/3` token to stop work explicitly.

  For long or recoverable waits prefer `tell/3` with `await/3` (called as
  `GenAgentEnsemble.await/3`; `GenAgentEnsemble.IEx.await/3` raises on
  timeout instead): the `await/3` timeout returns `{:error, :timeout}`
  without exiting, and the result can still be retrieved later with
  `await/3` or `poll/2` while the ensemble is alive. Budget
  long strategies (Debate, Pipeline, Consensus, Supervisor) explicitly with
  `timeout:` or the application setting.
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
  Stop the ensemble and its owned sub-agents and prompt tasks.
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
