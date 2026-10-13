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

  ## Admission limits

  One gate in the session server covers every public `ask`, `tell` and
  `tell_with_completion` call (including `stream_to:`), for all strategies.
  It runs before a token is minted, so a rejected call leaves no token, no
  completion or stream message, no strategy callback, and no child work behind.
  It returns `{:error, {:overloaded, info}}`:

      %{
        queue: :ensemble_prompts,
        limit: :count | :bytes,
        pending_count: 3,
        pending_bytes: 120,
        incoming_bytes: 42,
        max_count: 1_000 | :infinity,
        max_bytes: 1_048_576 | :infinity
      }

  The info map holds numbers and limits only, never the prompt. When both
  limits would be exceeded, `:count` is reported. A prompt that exactly fills
  the remaining bytes is admitted.

  A call is charged once, at admission, with `:erlang.external_size/1` of the
  original prompt (prompt options are not counted, since built-in strategies do
  not retain them). The charge stays until the logical token reaches its
  terminal result: success, error, cancellation (including
  `{:ok, :cancelled_unconfirmed}`), dispatch rejection, or halt. Pipeline
  stages, Debate and Consensus rounds, and Supervisor or Consensus fanout do not
  change the charge, and capacity stays charged while a cancellation executes.
  A caller's `ask/3` timeout does not release the work. Completed-result
  retention (`:max_completed_results`), `poll/2` and `inbox/1` do not affect it.
  Accepted requests are never evicted.

  This is a budget for the original serialized prompts of outstanding requests.
  It is not a total memory limit or a limit on physical work. The raw mailbox,
  strategy state and options, prompts a strategy generates, intermediate
  outputs, fanout, child backend histories, and completed results are bounded
  separately or not at all.

  `status/1` reports the live counters under `:admission`, and each rejection
  emits `[:gen_agent_ensemble, :admission, :rejected]`; see
  `GenAgentEnsemble.Telemetry`.

  ## Halt

  A strategy ends its session logically with the `{:halt, reason}` operation.
  The first applied halt wins and takes effect immediately: the rest of the
  operation batch is skipped, every request still pending finishes with
  `{:error, {:halted, reason}}` (asks, tell completion messages and registered
  `await/3` callers included), open child dispatches are retired, and the
  strategy is never called again. Results stored before the halt, including
  earlier successes, are kept. A `tell/3` whose own callback halts was already
  accepted, so it still returns `{:ok, token}` and its result is
  `{:error, {:halted, reason}}`.

  The ensemble process does **not** exit on halt. It keeps its PID and name
  as a read-only facade, so the final results can be collected:

    * `await/3` (repeatable), `poll/2`, `inbox/1`, `cancel/2` and `status/1`
      keep working. `status/1` reports `lifecycle: :halted`, no agents, and
      no strategy-specific fields.
    * `ask/3`, `tell/3` and `tell_with_completion/4` return
      `{:error, {:halted, reason}}` without minting a token, calling the
      strategy, starting work or emitting admission events. `notify/2` is
      ignored.
    * The owned agent tree is told to shut down at the moment of the halt.
      That shutdown is asynchronous and each child's configured `:shutdown`
      budget still applies, so a result can become available before child
      processes are gone. There is no latency guarantee, and no guarantee that
      an external provider has settled.

  There is no way to resume a halted ensemble. Dispose of it with `stop/1`;
  owner exit or a fatal process/tree failure also ends the session. Each
  discards the stored results. Until disposal it holds its registered name, and a supervisor still
  counts it as an active child. Results stay in memory with no expiry, bounded
  only by `:max_completed_results` (a count of results, not bytes, and `0`
  keeps none). Halt results count against that bound like any other, so a
  small bound can evict earlier results. Callers that wait, such as a
  `tell_with_completion/4` recipient or a registered `await/3`, still receive
  every result regardless of retention.
  """

  @doc """
  Start a new ensemble process. Takes `:name`, `:strategy`, and
  `:opts` (the strategy's own options keyword list).

  Top-level `:max_completed_results` bounds retained terminal tell results,
  default 100 (matching core's default tell result limit). Accepts a
  non-negative integer, including 0 to disable retention, or `:infinity` to
  opt out of the bound. Invalid values return
  `{:error, {:invalid_option, :max_completed_results, value}}` before strategy
  initialization or owned tree startup. The oldest result by completion
  order is evicted first; success, error, and cancellation all count.
  Asks are never cached. This is a result count bound, not a byte limit or
  a bound on strategy state or pending work.

  Top-level `:max_pending_prompts` (default 1_000) and
  `:max_pending_prompt_bytes` (default 1_048_576) bound the public `ask/3`,
  `tell/3` and `tell_with_completion/4` invocations outstanding in this
  session, active plus waiting, until each reaches a terminal result. Each
  accepts a non-negative integer or `:infinity` independently; zero rejects
  every new admission, including an idle session and an empty prompt. Invalid
  values return `{:error, {:invalid_option, key, value}}` before strategy
  initialization or owned tree startup. See "Admission limits" below.

  The session is linked to its caller and stops when that caller exits,
  including normally; this applies to a halted session as well, which
  otherwise stays alive (see "Halt" in the module documentation).
  Runtime shutdown waits for the owned agent tree;
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
  `:transient`: explicit stops stay stopped, while abnormal exits restart the
  ensemble. A strategy halt does not exit the process: the halted child stays
  registered and counted as active, with the same PID and name, until it is
  stopped explicitly (for example with `stop/1` or
  `Supervisor.terminate_child/2`), which then stays stopped. Shutdown is
  `:infinity` so the owned agent tree can finish within its configured
  shutdown budgets.

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
  `poll/2` or `inbox/1` to retrieve the response later. Returns
  `{:error, {:overloaded, info}}` without a token when the session's admission
  limits are full (see "Admission limits" in the module documentation), and
  `{:error, {:halted, reason}}` without a token once the ensemble has halted
  (see "Halt").
  """
  defdelegate tell(name, prompt), to: GenAgentEnsemble.Server

  @doc """
  Like `tell/2` but with strategy-specific options (e.g.
  `agent: "alice"` for Switchboard). Subject to the same admission limits.
  """
  defdelegate tell(name, prompt, opts), to: GenAgentEnsemble.Server

  @doc """
  Like `tell/3`, returning `{:ok, token}`, with one terminal message sent to
  the supplied PID:

      {:gen_agent_ensemble, :completion, session, token, {:ok, response} | {:error, reason}}

  The recipient defaults to the caller. It must be a PID (otherwise raises
  `FunctionClauseError`). When admission limits are full it returns
  `{:error, {:overloaded, info}}`; no completion or stream message is sent
  for a rejected call.
  Notification does not consume the result stored for `poll/2` or `inbox/1`.
  It is delivered even when retention is disabled or the cache is full.
  Halt delivers `{:error, {:halted, reason}}` to the recipient of each token
  still pending. After the halt, a new call returns
  `{:error, {:halted, reason}}` and sends nothing.

  Set `stream_to: pid` to also receive normalized child stream events:

      {:gen_agent_ensemble, :event, session, token,
       %{agent: bare_member, dispatch: ordinal, event: %GenAgent.Event{}}}

  Streaming defaults to off (`nil`). Other values raise `ArgumentError`.
  This reserved option is removed before strategy callbacks. The dispatch
  ordinal starts at zero for each token and distinguishes repeated dispatches
  to the same member. Legacy unscoped strategy dispatches are not streamed.
  Core retries within one child request keep the same dispatch ordinal; an
  intermediate `:error` event does not necessarily mean the token has finished.

  Events preserve each child's stream order; events across members interleave
  in the order received by the ensemble. Events are sent before the token's
  completion and arrive before it when both recipients are the same PID.
  Separate recipients have no shared arrival order. Late events are dropped
  after token completion (including error, cancellation, rejection or session
  halt), or after the corresponding child completes or goes down. Streaming
  stops at the halt even though the ensemble process remains.

  Delivery is best effort with no backpressure. Stream recipients are not
  monitored; a dead recipient does not cancel the token.
  Result retention and consumption do not control streaming. Stream
  notifications are not replayed by `await/3`, `poll/2`, or `inbox/1`; a
  retained response may still contain its own event history. An `await/3`
  timeout removes only that waiter; streaming continues until the token finishes.
  """
  def tell_with_completion(name, prompt, recipient \\ self(), opts \\ []),
    do: GenAgentEnsemble.Server.tell_with_completion(name, prompt, recipient, opts)

  @doc """
  Wait for an existing tell token without consuming its result.

  Returns `{:ok, response}` or `{:error, reason}`. All registered waiters
  receive the terminal result. `poll/2` and `inbox/1` still consume the
  stored copy; an await processed after consumption returns
  `{:error, :not_found}`, as does an evicted or unknown token. Registered
  waiters receive results even with zero retention or a full cache. Server
  message order determines races between registration, completion, and consumption.

  Timeout is a non-negative number of milliseconds or `:infinity`, default
  30_000. Zero checks the current result without waiting. Expiry returns
  `{:error, :timeout}` and removes only this waiter; a late result can still
  be retrieved. Invalid timeouts raise `FunctionClauseError`.
  Unavailable or terminated sessions retain normal `GenServer.call/3` exit
  semantics. Halt replies to registered waiters with
  `{:error, {:halted, reason}}`. A halted session stays alive, so a retained
  halt result can be awaited repeatedly until `poll/2` or `inbox/1` consumes
  it or `stop/1` discards the session.
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
  that wins the race, `{:error, :not_found}` for unknown/consumed/evicted tokens
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

  ## Admission

  When the session's admission limits are full, `ask/3` returns
  `{:error, {:overloaded, info}}` immediately and starts no work. An accepted
  ask stays charged until its logical terminal result, even if the caller's
  timeout expires first.

  After a strategy halt, `ask/3` returns `{:error, {:halted, reason}}`
  immediately without starting work (see "Halt" in the module documentation).
  """
  defdelegate ask(name, prompt, opts), to: GenAgentEnsemble.Server

  @doc """
  Non-blocking check on a `tell`-minted token. Returns
  `{:ok, :pending}`, `{:ok, :completed, response}`, or
  `{:error, reason}`. Completed results are consumed; evicted or consumed
  tokens return `{:error, :not_found}`. Works on a halted ensemble.
  """
  defdelegate poll(name, token), to: GenAgentEnsemble.Server

  @doc """
  Drain all currently retained completed `tell` tokens, clearing their
  completion order bookkeeping too. Entry order is unspecified. Returns
  `{:ok, [{token, {:ok, response} | {:error, reason}}, ...]}`. Works on a
  halted ensemble, where it returns the retained results, halt errors
  included. Draining does not dispose of the ensemble.
  """
  defdelegate inbox(name), to: GenAgentEnsemble.Server

  @doc """
  Send an asynchronous event to the strategy (`handle_notify/2`). Ignored once
  the ensemble has halted.
  """
  defdelegate notify(name, event), to: GenAgentEnsemble.Server

  @doc """
  Inspect the ensemble: running agents, strategy phase, queue depth.

  The result always includes an `:admission` map, added after the strategy's own
  fields so a strategy cannot replace it:

      %{
        scope: :outstanding,
        pending_count: 2,
        pending_bytes: 96,
        max_pending_prompts: 1_000,
        max_pending_prompt_bytes: 1_048_576
      }

  The counters cover outstanding public requests, active plus waiting. The two
  maximums are non-negative integers or `:infinity`.

  `:lifecycle` is `:running` or `:halted`. Like `:admission`, it is added
  after the strategy's own fields. Once halted, the strategy is not called, so
  its fields are omitted: `:agents` and `:pending_tokens` are empty,
  `:in_flight` is `0` and the admission counters are zero. The halt reason is
  not part of the status; it is the one returned to callers.
  """
  defdelegate status(name), to: GenAgentEnsemble.Server

  @doc """
  Stop the ensemble and its owned sub-agents and prompt tasks, discarding any
  retained results. This is also how a halted ensemble is disposed of: it
  waits for an owned-tree shutdown that the halt already started.
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
