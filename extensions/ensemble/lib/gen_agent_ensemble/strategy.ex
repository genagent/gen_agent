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

  See `GenAgentEnsemble.Strategies.Solo` for a minimal reference
  implementation.

  ## Usage accounting

  Debate, Consensus, Supervisor, and Pipeline return `Response.usage` as
  summed numeric fields from every successful turn in the current run.
  Provider keys are preserved (for example, `:input_tokens` and
  `:output_tokens`). The reserved `:by_agent` key contains
  `%{agent_name => summed_numeric_usage_map}`; these maps sum to the top-level
  totals. Supervisor includes the coordinator and all completed workers.
  Pipeline preserves the final stage's other response fields.

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
      `{name, module, opts}` where `module` is a `GenAgent` callback
      module.
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

  ## Tokens

  Tokens are opaque strings minted by the framework when the caller
  invokes `tell`/`ask`. Strategies receive the token and must correlate
  it with work they dispatch. Pass the token in every `:dispatch` op;
  responses land back in `handle_response` tagged with the *agent* that
  produced them after the framework checks that token is still pending.
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

  @callback init(keyword) :: {:ok, strategy_state, [start_spec]}
  @callback handle_tell(prompt, keyword, token, strategy_state) :: result
  @callback handle_ask(prompt, keyword, token, strategy_state) :: result
  @callback handle_response(agent_name, response, strategy_state) :: result
  @callback handle_error(agent_name, term(), strategy_state) :: result
  @callback handle_start_rejected(agent_name, term(), strategy_state) :: result
  @callback handle_dispatch_rejected(agent_name, token, term(), strategy_state) :: result
  @doc """
  Remove a cancelled token and advance queued work. Return operations for
  successors, but never reply to the cancelled token: the server closes it.
  Child refs are fenced before these operations execute. Implementations must
  use token-scoped dispatches to support cancellation safely. Without this
  callback cancellation returns `{:error, :unsupported}` without changes.
  """
  @callback handle_cancel(token, strategy_state) :: result
  @callback handle_notify(term(), strategy_state) :: result
  @callback handle_agent_down(agent_name, term(), strategy_state) :: result
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
