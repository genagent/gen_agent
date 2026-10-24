defmodule GenAgentEnsemble.Telemetry do
  @moduledoc """
  Observational events for Ensemble sessions and routed turns.

  Events use the `[:gen_agent_ensemble, scope, event]` prefix:

  | Scope | Events | Measurements | Metadata |
  | --- | --- | --- | --- |
  | `:session` | `:start`, `:stop`, `:halt` | `system_time` on start; `duration_ms` on stop/halt | `session`, `strategy`; `outcome` and `reason_kind` on stop/halt |
  | `:token` | `:start`, `:stop`, `:error` | `system_time` on start; `duration_ms` on stop/error | `session`, `strategy`, `token`, `kind`; `outcome` on stop/error, `reason_kind` on error |
  | `:dispatch` | `:start`, `:stop`, `:error`, `:rejected` | `system_time` on start; `duration_ms` on stop/error | `session`, `strategy`, `token`, `agent`, `member_name`, `ref`, `ordinal`, `outcome`; `reason_kind` on error/rejected |
  | `:admission` | `:rejected` | `pending_count`, `pending_bytes`, `incoming_bytes` | `session`, `strategy`, `kind`, `outcome` (`:rejected`), `reason_kind` (`:overloaded`), `limit` (`:count` or `:bytes`), `max_pending_prompts`, `max_pending_prompt_bytes` |

  An `[:gen_agent_ensemble, :admission, :rejected]` event is emitted once for
  each `ask`/`tell` the session's admission limits refuse (see
  `GenAgentEnsemble`). The request was never accepted, so no token exists and
  no `:token` or `:dispatch` event accompanies it; the metadata carries no
  token, ref, prompt, or options. The measurements are numbers, and the two
  maximums are non-negative integers or `:infinity`.

  A deliberate strategy `{:halt, reason}` emits exactly one
  `[:gen_agent_ensemble, :session, :halt]`
  (`outcome: :halted`, `reason_kind: :strategy_halt`), at the moment the halt
  is applied. Contained callback raises, throws and exits use
  `reason_kind: :strategy_callback_failed`; malformed callback results use
  `reason_kind: :invalid_strategy_result`. These failures also produce an error
  log containing only the callback atom and failure kind/category, never the
  failure value or stacktrace. Every halt closes each open dispatch and pending
  token with one `:error` event whose `reason_kind` is `:halted`; work
  that already finished keeps its original event. Because a halted session
  stays alive, `[:gen_agent_ensemble, :session, :stop]` is not emitted until it
  is actually stopped or its owner exits, and it then reports no further
  `:session_stopped` errors. Calls refused after a halt were never accepted:
  they emit no token, dispatch or admission event. The halt reason itself is
  never part of the metadata.

  `:kind` is `:ask` or `:tell`. `:ordinal` starts at zero for each
  token and is reserved at submission, including child-rejected submissions.
  Combined with `:agent`, it identifies Pipeline stage order and
  Supervisor branches. External strategies using unscoped dispatches have
  `nil` token and ordinal. `:ref` is the corresponding core GenAgent turn
  reference, so dispatches can be joined to `GenAgent.Telemetry` events.

  `:agent` remains the bare binary member; `:member_name` is the canonical
  `GenAgentEnsemble.member_name(session, agent)` tuple. Join core metadata's
  `:agent` to Ensemble's `:member_name`, and individual turns by `:ref`.
  Core completion/stream messages and agent listings also expose the tuple.
  Consumers of handwritten slash keys must migrate; this does not promise
  compatibility with third-party serializers or telemetry exporters.

  A submitted dispatch starts only on child admission `:ok` or a completion
  that proves acceptance. Completion before admission emits start then stop/error;
  duplicate or late decisions never reopen a retired ref. Child admission
  rejection emits one `:rejected` with its ref and reserved ordinal, and no
  start or stop/error. Unscoped dispatches retain a nil ordinal. Local cancellation, halt, or cleanup can emit an error for a submitted
  ref without inventing acceptance or a start. Dispatch durations include time
  spent awaiting child admission.

  A failed ownership guard emits exactly one `:dispatch, :rejected` event,
  with `reason_kind: :agent_not_running`, nil ref/ordinal and no dispatch start.
  Start conflicts and tracked duplicates use bounded `:member_name_conflict`
  and `:duplicate_sub_agent` reason categories when reported in token errors
  or operation logs. A supervisor exit during stop is `:agent_stop_failed`.
  No foreign PID or start options are added to these diagnostics.

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
