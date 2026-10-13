defmodule GenAgentEnsemble.Telemetry do
  @moduledoc """
  Observational events for Ensemble sessions and routed turns.

  Events use the `[:gen_agent_ensemble, scope, event]` prefix:

  | Scope | Events | Measurements | Metadata |
  | --- | --- | --- | --- |
  | `:session` | `:start`, `:stop`, `:halt` | `system_time` on start; `duration_ms` on stop/halt | `session`, `strategy`; `outcome` and `reason_kind` on stop/halt |
  | `:token` | `:start`, `:stop`, `:error` | `system_time` on start; `duration_ms` on stop/error | `session`, `strategy`, `token`, `kind`; `outcome` on stop/error, `reason_kind` on error |
  | `:dispatch` | `:start`, `:stop`, `:error`, `:rejected` | `system_time` on start; `duration_ms` on stop/error | `session`, `strategy`, `token`, `agent`, `ref`, `ordinal`, `outcome`; `reason_kind` on error/rejected |
  | `:admission` | `:rejected` | `pending_count`, `pending_bytes`, `incoming_bytes` | `session`, `strategy`, `kind`, `outcome` (`:rejected`), `reason_kind` (`:overloaded`), `limit` (`:count` or `:bytes`), `max_pending_prompts`, `max_pending_prompt_bytes` |

  An `[:gen_agent_ensemble, :admission, :rejected]` event is emitted once for
  each `ask`/`tell` the session's admission limits refuse (see
  `GenAgentEnsemble`). The request was never accepted, so no token exists and
  no `:token` or `:dispatch` event accompanies it; the metadata carries no
  token, ref, prompt, or options. The measurements are numbers, and the two
  maximums are non-negative integers or `:infinity`.

  `:kind` is `:ask` or `:tell`. `:ordinal` starts at zero for each
  token. Combined with `:agent`, it identifies Pipeline stage order and
  Supervisor branches. External strategies using unscoped dispatches have
  `nil` token and ordinal. `:ref` is the corresponding core GenAgent turn
  reference, so dispatches can be joined to `GenAgent.Telemetry` events.

  Event metadata never includes prompts, responses, full errors, or strategy
  state. `session`, `token`, `ref`, and agent names have high cardinality;
  use them for traces and logs, not metric labels. Durations are elapsed
  monotonic milliseconds. `reason_kind` is a bounded error category rather
  than its potentially sensitive details; arbitrary backend and strategy
  errors collapse to `:backend_or_strategy_error`.

  Event delivery is independent of result delivery. The Ensemble server
  receives turn completions directly and does not depend on telemetry
  handlers. A process killed without `terminate/2` cannot emit a stop event.
  """
end
