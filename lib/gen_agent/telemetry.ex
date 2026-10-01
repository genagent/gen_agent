defmodule GenAgent.Telemetry do
  @moduledoc """
  Telemetry contract for GenAgent turns and local agent observation.

  ## Content-free turn lifecycle

  Use these events for ordinary metrics and traces:

  | Event | Measurements | Metadata |
  | --- | --- | --- |
  | `[:gen_agent, :turn, :start]` | `system_time` (native unit) | `agent`, `ref`, `origin` |
  | `[:gen_agent, :turn, :stop]` | `duration_ms` (non-negative milliseconds) | `agent`, `ref`, `origin` |
  | `[:gen_agent, :turn, :error]` | `duration_ms` (non-negative milliseconds) | `agent`, `ref`, `origin`, `reason_kind` |
  | `[:gen_agent, :turn, :rejected]` | `system_time` (native unit) | `agent`, `ref`, `origin`, `reason_kind` |

  `ref` is the request reference and correlates the start with one
  terminal event. `origin` is one of `:ask`, `:tell`, `:event`, or
  `:self_chain`. A dispatched turn emits `:start` and then `:stop` or
  `:error` when it settles. Duration uses the agent process's
  monotonic clock from dispatch to backend outcome, watchdog,
  interruption, or task crash. An agent or VM crash can prevent a
  terminal event.

  `:rejected` means a prompt was declined before dispatch, so it has
  **no matching `:start`** and no duration. It covers queued prompt
  overload and `pre_turn/2` skip, halt, or invalid return. Rejected
  notifications are instead reported by `[:gen_agent, :input,
  :rejected]`; they are not prompt turns.

  `reason_kind` is deliberately coarse: terminal errors use
  `:timeout`, `:interrupted`, `:task_crashed`, or
  `:backend_or_callback_error`. Pre-dispatch rejections use
  `:overloaded`, `:pre_turn_skipped`, `:pre_turn_halted`, or
  `:pre_turn_invalid`. The raw reason, prompt, response, backend
  session, and agent state are never included in these turn events.
  `agent` and especially `ref` can still have high cardinality: use
  them to correlate traces, not as unbounded metric labels. The
  bounded `origin` and `reason_kind` fields are suitable dimensions.

  ## Rich local events

  The original events remain for trusted, in-process observers:

  | Event | Measurements | Metadata that may contain application data |
  | --- | --- | --- |
  | `[:gen_agent, :prompt, :start]` | `system_time` (native unit) | `agent`, `ref`, `prompt`, `original_prompt`, `rewritten`, `agent_state` |
  | `[:gen_agent, :prompt, :stop]` | `duration` (backend-reported milliseconds) | `agent`, `ref`, `agent_state` |
  | `[:gen_agent, :prompt, :error]` | `system_time` (native unit); `duration` (milliseconds) for dispatched turns | `agent`, `ref`, raw `reason`, `agent_state` |
  | `[:gen_agent, :event, :received]` | `system_time` (native unit) | `agent`, raw `event` |
  | `[:gen_agent, :state, :changed]` | `system_time` (native unit) | `agent`, `from`, `to` |
  | `[:gen_agent, :mailbox, :queued]` | `depth` (count) | `agent` |
  | `[:gen_agent, :input, :rejected]` | `system_time` (native unit) | `agent`, raw `reason` |
  | `[:gen_agent, :halted]` | `system_time` (native unit) | `agent`, `agent_state` |

  Rich `:prompt, :error` may describe a generated prompt rejected
  before dispatch, in which case it has no matching prompt start or
  duration. It also fires on interruption. These events can contain
  sensitive application data and should not be exported or turned
  into metrics without filtering. Their metadata shape is preserved
  for existing local observers.

  Normalized token usage is on `GenAgent.Response.usage`; inspect it
  in `handle_response/3` or `post_turn/3`. Backend-specific usage or
  cost fields can be read from normalized stream events by a trusted
  `handle_stream_event/2` callback. The core turn events do not copy
  usage or provider data, and adapters do not need to duplicate the
  turn lifecycle just to expose latency.
  """
end
