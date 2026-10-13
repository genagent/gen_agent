defmodule GenAgentEnsemble.Strategy do
  @moduledoc """
  Behaviour for session strategies.

  A strategy decides how a session of N sub-agents handles incoming
  prompts, events, and responses. The framework owns sub-agent
  lifecycle and message routing; the strategy declares *intent* via a
  list of operations the framework then executes.

  Every callback returns `{:ok, [op], strategy_state}`. The framework
  applies the ops in order, updates strategy state, and waits for the
  next event.

  Callbacks run synchronously in the Ensemble Server process. A callback that
  blocks delays all calls handled by that server; a callback that raises or
  returns an unexpected shape stops the session. Optional callbacks and their
  individual fallbacks are documented below.

  See `GenAgentEnsemble.Strategies.Solo` for a minimal reference
  implementation.

  ## Usage accounting

  Debate, Consensus, Supervisor, and Pipeline return `Response.usage` as
  summed numeric fields from every successful turn in the current run.
  Provider keys are preserved (for example, `:input_tokens` and
  `:output_tokens`). The reserved `:by_agent` key contains
  `%{agent_name => summed_numeric_usage_map}`; these maps sum to the top-level
  totals. Supervisor includes the coordinator and all completed workers.
  Pipeline preserves the final stage's other response fields and adds
  `metadata.pipeline`: `stages` holds ordered `{stage_name, response}` pairs
  with every unmodified stage response, and `total_duration_ms` sums their
  durations (excluding queue wait and orchestration overhead). Top-level
  `duration_ms` still describes the final stage. Other metadata keys survive;
  `:pipeline` is reserved for the current run.

  Missing or non-map usage is ignored. If no turn reports a usage map,
  `usage` remains `nil`. Empty maps or maps containing only nonnumeric
  fields produce an empty per-agent entry. Nonnumeric fields, including
  nested provider metadata, are dropped; `:by_agent` is reserved even if a
  provider supplies a numeric value for it. Each new or queued run starts
  fresh, including after a failed run. Solo, Pool, and Switchboard keep
  passing through the selected response's usage unchanged.

  Accounting assumes **per-turn** usage: core uses the latest `:usage` event
  within a turn. A backend reporting session-cumulative usage will therefore
  overcount. Failed turns deliver no successful response to the strategy, so
  their usage is not observable and is not included.

  ## Operations

    * `{:start, start_spec}` -- start a new sub-agent. `start_spec` is
      `{name, module, opts}` where `name` is a string, `module` is a
      `GenAgent` callback module, and `opts` is a keyword list that includes
      the `:backend` module. A spec that does not match is rejected as
      described under "Rejected starts" rather than started.
    * `{:stop, agent_name}` -- terminate a sub-agent.
    * `{:dispatch, agent_name, prompt, token}` -- send a prompt to an existing
      sub-agent via `GenAgent.tell_with_completion/3`. The framework calls `handle_response/3`
      only while `token` remains pending, so late results from an aborted run
      cannot enter a later run. If dispatch is rejected, the framework calls
      `handle_dispatch_rejected/4` and closes the token if the callback does not.
      The three-element form remains available for existing external strategies
      but has no run fencing or token to fail; rejection is only logged.
    * `{:reply, token, response}` -- complete a pending `tell`/`ask`.
      The caller polling on `token` (or blocked on an `ask`) receives
      the response.
    * `{:reply_error, token, reason}` -- complete a pending `tell`/`ask`
      with an error. Callers see `{:error, reason}`.
    * `{:forward, agent_name, event}` -- call `GenAgent.notify/2` on
      the named sub-agent.
    * `{:halt, reason}` -- terminate the session.

  Ops are applied sequentially. A rejected scoped dispatch ends the current
  op batch after notifying the strategy; other op failures are logged and
  processing continues. A failed start also ends its op batch when the
  strategy implements `handle_start_rejected/3`, so a following dispatch
  cannot target the absent agent. Strategies that record token state before
  dispatch should implement `handle_dispatch_rejected/4` to remove that token
  and advance any queued work. The framework guarantees a terminal error for
  the token even when the callback is absent.

  If `handle_error/3` is absent, a failed turn closes its token with the
  backend error. If `handle_agent_down/3` is absent, each pending token
  dispatched to that agent fails with `{:agent_down, agent, reason}`.
  Remaining dispatch references for those tokens are retired so late
  completions cannot alter their results; unrelated tokens remain pending.
  Implement these callbacks when the strategy needs to recover, update its
  own state, or advance queued work. Unscoped dispatches have no token to close.

  ## Malformed operations

  An individual operation that matches none of the forms above, or whose
  agent name, dispatch prompt, or scoped dispatch token is not a string, is
  logged and skipped, and the rest of the batch still runs. The log names only the operation tag and, for string
  names and tokens, the name or token. Skipping completes nothing on the
  strategy's behalf: a token the strategy meant to close stays pending until a
  later valid `:reply`, `:reply_error`, or rejected dispatch closes it. The
  operation list must still be a list and callbacks must still return
  `{:ok, ops, state}`; other shapes stop the session.

  ## Rejected starts

  A start is rejected with one of these reasons. The batch then ends if
  `handle_start_rejected/3` is implemented and continues if it is not.

    * `{:invalid_start_spec, field}` -- the spec failed validation and no child
      was built. `field` is `:shape` (not a 3-tuple), `:name` (not a string),
      `:module` (not a module atom), `:options` (not a proper keyword list),
      `:backend` (no `:backend` module in the options), or `:child_spec`
      (`GenAgent.child_spec/2` rejected the options, for example an invalid
      `:shutdown`).
    * `{:start_exception, kind}` -- starting the child raised, threw, or
      exited. `kind` is `:error`, `:throw`, or `:exit`.
    * `{:duplicate_sub_agent, name}`, or the child supervisor's own error
      reason, as in earlier releases.

  The first two reasons never contain the offending value, exception, or
  stacktrace, because start options often hold credentials. When the name is
  not identifiable, the start is logged and skipped even if the callback exists.
  A nonempty tuple with a string first field identifies the name even if its
  arity is invalid; other shapes and non-string names do not. A rejected spec returned
  from `c:init/1` stops initialization with the same reason and stops any
  children already started.

  ## Tokens

  Tokens are opaque strings minted by the framework when the caller
  invokes `tell`/`ask`. Strategies receive the token and must correlate
  it with work they dispatch. Pass the token in every `:dispatch` op;
  responses land back in `handle_response` tagged with the *agent* that
  produced them after the framework checks that token is still pending.
  `handle_response/3` does not receive the token, so keep your own
  agent-to-token mapping if the strategy needs to identify the originating
  request.
  """

  @type agent_name :: String.t()
  @type token :: String.t()
  @type start_spec :: {agent_name, module, keyword}
  @type prompt :: String.t()
  @type response :: GenAgent.Response.t()
  @type strategy_state :: term()

  @type op ::
          {:start, start_spec}
          | {:stop, agent_name}
          | {:dispatch, agent_name, prompt, token}
          | {:dispatch, agent_name, prompt}
          | {:reply, token, response}
          | {:reply_error, token, term()}
          | {:forward, agent_name, term()}
          | {:halt, term()}

  @type result :: {:ok, [op], strategy_state}

  @doc """
  Initialize strategy state and return the initial child specifications.

  Returning `{:error, reason}` stops server initialization with `reason`.
  """
  @callback init(keyword) :: {:ok, strategy_state, [start_spec]} | {:error, term()}

  @doc "Handle a caller's non-blocking `tell`, returning operations and updated state."
  @callback handle_tell(prompt, keyword, token, strategy_state) :: result

  @doc "Handle a caller's `ask`, returning operations and updated state."
  @callback handle_ask(prompt, keyword, token, strategy_state) :: result

  @doc "Handle a successful agent response. The callback receives the agent name, not the request token."
  @callback handle_response(agent_name, response, strategy_state) :: result

  @doc """
  Handle an active agent turn error. If the token is no longer pending,
  this callback is skipped. If omitted, the server logs the error and closes
  the affected token with it, retiring remaining dispatch references for
  that token. Strategy state is unchanged.
  """
  @callback handle_error(agent_name, term(), strategy_state) :: result

  @doc "Handle a rejected child start. Defining this callback halts the current operation batch; if omitted, remaining operations continue."
  @callback handle_start_rejected(agent_name, term(), strategy_state) :: result

  @doc "Handle a rejected token-scoped dispatch. This halts the current operation batch. If omitted, the server closes its token with a dispatch error; a callback that does not close the token also gets that fallback."
  @callback handle_dispatch_rejected(agent_name, token, term(), strategy_state) :: result
  @doc """
  Remove a cancelled token and advance queued work. Return operations for
  successors, but never reply to the cancelled token: the server closes it.
  Child refs are fenced before these operations execute. Implementations must
  use token-scoped dispatches to support cancellation safely. Without this
  callback cancellation returns `{:error, :unsupported}` without changes.
  """
  @callback handle_cancel(token, strategy_state) :: result
  @doc "Handle an event sent to the session. If omitted, the event is ignored and state is unchanged."
  @callback handle_notify(term(), strategy_state) :: result

  @doc """
  Handle an agent going down. If omitted, pending tokens dispatched to this
  agent fail with `{:agent_down, agent, reason}` and their remaining dispatch
  references are retired. Strategy state is unchanged.
  """
  @callback handle_agent_down(agent_name, term(), strategy_state) :: result

  @doc "Return extra status fields. These are merged over the server's base map and can replace its keys; if omitted, no extra fields are added."
  @callback handle_status(strategy_state) :: map()

  @optional_callbacks [
    handle_cancel: 2,
    handle_error: 3,
    handle_start_rejected: 3,
    handle_dispatch_rejected: 4,
    handle_agent_down: 3,
    handle_notify: 2,
    handle_status: 1
  ]
end
