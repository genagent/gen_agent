defmodule GenAgent do
  @moduledoc """
  A behaviour and supervision framework for long-running LLM agent processes,
  modeled as OTP state machines.

  Each agent is a `:gen_statem` process wrapping a persistent LLM session.
  Every interaction is a prompt-response turn, and the implementation decides
  what happens between turns.

  > It is a GenServer but every call is a prompt.

  GenAgent handles the mechanics of turns. Implementations handle the
  semantics of turns.

  Public client functions address agents by their registered `:name`. The pid
  returned by `start_agent/2` is for monitoring and supervision, not a client
  address. Synchronous calls return `{:error, :not_found}` when that name is
  absent at lookup. A concurrent stop or agent death after lookup can still
  exit the call, and a caller-supplied timeout exits on expiry. Casts are best
  effort and return `:ok` even when no agent is registered.

  ## Installation

      def deps do
        [
          {:gen_agent, "~> 0.7.0"}, # x-release-please-version
          # Plus at least one backend:
          {:gen_agent_claude, "~> 0.2.0"},
          {:gen_agent_codex, "~> 0.4.0"},
          {:gen_agent_anthropic, "~> 0.3.0"},
          {:gen_agent_openai, "~> 0.3.0"}
        ]
      end

  ## Quick start

      defmodule MyApp.Coder do
        use GenAgent

        defmodule State do
          defstruct [:path, responses: []]
        end

        @impl true
        def init_agent(opts) do
          path = Keyword.fetch!(opts, :cwd)

          backend_opts = [
            cwd: path,
            system_prompt: "You are a coding assistant."
          ]

          {:ok, backend_opts, %State{path: path}}
        end

        @impl true
        def handle_response(_ref, response, state) do
          {:noreply, %{state | responses: state.responses ++ [response.text]}}
        end
      end

      # Start the agent under the GenAgent supervision tree.
      {:ok, _pid} = GenAgent.start_agent(MyApp.Coder,
        name: "my-coder",
        backend: GenAgent.Backends.Claude,
        cwd: "/path/to/project"
      )

      # Synchronous prompt.
      {:ok, response} = GenAgent.ask("my-coder", "What does lib/foo.ex do?")
      IO.puts(response.text)

      # Async prompt.
      {:ok, ref} = GenAgent.tell("my-coder", "Add tests for lib/foo.ex")
      GenAgent.poll("my-coder", ref)
      #=> {:ok, :pending} while the turn runs, then {:ok, :completed, response}

      # Or have the outcome sent to you as a message.
      {:ok, ref} = GenAgent.tell_with_completion("my-coder", "Run the tests")

      receive do
        {:gen_agent, :completion, "my-coder", ^ref, {:ok, response}} -> IO.puts(response.text)
        {:gen_agent, :completion, "my-coder", ^ref, {:error, reason}} -> IO.inspect(reason)
      end

      # External event.
      GenAgent.notify("my-coder", {:ci_failed, "test_auth"})

      GenAgent.stop("my-coder")

  ## State model

  An agent is a state machine with two states:

      idle --- ask/tell/notify ---> processing
                                        |
                                        v
      idle <--- handle_response --- processing (turn done)

  Self-chaining: `c:handle_response/3` can return `{:prompt, text, state}`
  to immediately dispatch another turn without a caller, useful for
  multi-step work that the agent drives itself.

  Halting: `c:handle_response/3`, `c:handle_error/3`, `c:handle_event/2`,
  or `c:pre_turn/2` can return `{:halt, state}` to go idle but freeze the
  mailbox. A halted agent ignores queued prompts until `resume/1` is called.

  ## Backends

  Backends implement `GenAgent.Backend` and translate the LLM-specific wire
  protocol into the normalized `GenAgent.Event` stream the state machine
  consumes. Available backends (in sibling packages):

    * `GenAgent.Backends.Claude` (package: `gen_agent_claude`) --
      wraps the Anthropic `claude` CLI via `ClaudeWrapper`.
    * `GenAgent.Backends.Codex` (package: `gen_agent_codex`) --
      wraps the OpenAI `codex` CLI via `CodexWrapper`.
    * `GenAgent.Backends.Anthropic` (package: `gen_agent_anthropic`) --
      calls the Anthropic HTTP API via `Req`.
    * `GenAgent.Backends.OpenAI` (package: `gen_agent_openai`) --
      calls the OpenAI Responses API via `Req`.

  A backend owns its session lifecycle, translates events, and carries any
  state it needs (session id, message history) in an opaque session term.

  ## Callbacks

    * `c:init_agent/1` -- set up backend options and initial agent state.
    * `c:handle_response/3` -- a turn completed, decide what to do next.
    * `c:handle_error/3` (optional) -- a turn failed, decide what to do next.
    * `c:handle_event/2` (optional) -- an external event arrived via `notify/2`.
    * `c:handle_info/2` (optional) -- an ordinary OTP message arrived, such
      as a timer, monitor `:DOWN`, or completion from another agent.
    * `c:handle_stream_event/2` (optional) -- a backend event arrived mid-turn.
      Runs inside the prompt task, not the agent process.
    * `c:terminate_agent/2` (optional) -- the agent is shutting down.

  Lifecycle hooks (all optional):

    * `c:pre_run/1` -- one-time setup after `init_agent`, before the first turn.
    * `c:pre_turn/2` -- before each dispatch. Can rewrite the prompt, skip, or halt.
    * `c:post_turn/3` -- after each turn, post-decision. For state-mutating side effects.
    * `c:post_run/1` -- on clean `{:halt, state}` from a decision callback or
      `c:pre_turn/2`. For completion side effects.

  The `use GenAgent` macro provides default implementations of most optional
  callbacks and lifecycle hooks, plus an overridable `child_spec/1` that
  delegates to `child_spec/2`. It deliberately leaves `handle_info/2`
  undefined so unexpected OTP messages can be logged.

  ### Where callbacks run

  | Callback or step | Runs in |
  | --- | --- |
  | `c:init_agent/1`, `c:pre_run/1`, `c:pre_turn/2` | agent process |
  | `c:handle_response/3`, `c:handle_error/3`, `c:handle_event/2`, `c:handle_info/2` | agent process |
  | `c:post_turn/3`, `c:post_run/1`, `c:terminate_agent/2` | agent process |
  | `c:handle_stream_event/2` | prompt task |
  | Backend `prompt/2,3`, its event stream, `update_session/2` | prompt task |
  | Backend `start_session/1`, `terminate_session/1`, `checkpoint_session/2` | agent process |

  `current_name/0` returns the registered agent name in callbacks on either
  process, including `init_agent/1` and `handle_stream_event/2`. It returns
  `nil` outside those processes. The name is kept separate from the options
  that an agent might forward to its backend.

  Anything that runs in the agent process blocks the agent from handling
  other messages while it runs. Synchronous calls such as `status/2`,
  `poll/3`, `tell/3`, `runtime_snapshot/2` and `notify_ack/3` are handled
  by that process, so they wait until the callback returns. Their default
  timeout is `:infinity`, so a caller waits as long as the callback takes
  unless it passes a shorter timeout. Asynchronous casts such as
  `notify/2` return immediately (the event is handled after the callback),
  and `whereis/1` reads the registry without messaging the agent. Work in
  the prompt task does not block the agent process, with one exception: a
  backend's `prompt/3` can request a session checkpoint through the
  `:checkpoint` function in its options. That call is synchronous, so the
  prompt task waits while the agent process runs `checkpoint_session/2`,
  and synchronous agent calls wait for it too. The agent also runs
  `checkpoint_session/2` when restoring a stored checkpoint after a prompt
  task returns a success or error. If the task crashes, the agent keeps the
  earlier checkpoint without invoking the callback again.

  ## Process lifecycle

  Agents use `restart: :temporary`. A crashed or stopped agent must be
  started explicitly; GenAgent does not restore its previous state.

  Each turn runs in a supervised prompt task. Task failures are delivered
  to `c:handle_error/3` without taking down the agent. When the agent exits,
  its active prompt task is stopped, including when an abrupt exit bypasses
  termination callbacks.

  Stopping the BEAM task does not establish that a provider's subprocess
  or remote request has stopped. The backend and its transport own external
  cancellation and resource cleanup.

  Callback failure logs include the agent name and callback module. Logger
  metadata also carries `:gen_agent` and `:gen_agent_module` for filtering;
  applications can opt to include those keys in their Logger formatter.
  Stack frames include module, function, file, and line but omit argument
  values and exception messages, which may contain prompt or state data.

  ## Public API

    * `start_agent/2` -- start an agent under the supervision tree.
    * `child_spec/2` -- build a child spec for caller-owned supervision.
    * `ask/3` -- synchronous prompt, blocks until the turn finishes.
    * `tell/3` -- async prompt, returns a ref for `poll/3`.
    * `tell_with_completion/4` -- async prompt with request-scoped completion delivery;
      `tell_with_completion/5` adds `stream_to:` for ref-tagged stream events.
    * `poll/3` -- check on a previously-issued `tell/3`.
    * `notify/2` -- push an external event into `c:handle_event/2`.
    * `notify_ack/3` -- acknowledge in-memory notification admission.
    * `interrupt/1` -- cancel an in-flight turn.
    * `interrupt_request/3` -- acknowledge cancellation for a matching request ref.
    * `cancel_request/3` -- remove a queued tell by its request ref.
    * `resume/1` -- unhalt an agent and drain its mailbox.
    * `halt/1` -- halt dispatch after any active turn finishes.
    * `reset_session/2` -- clear a backend's conversation context between turns.
    * `status/2` -- read the agent's current state.
    * `runtime_snapshot/2` -- read bounded runtime metadata.
    * `drain/2` -- refuse new work, finish the active turn, then stop.
    * `stop/1` -- terminate the agent.
    * `stop/2` -- terminate an agent under its caller-owned supervisor.
    * `whereis/1` -- look up an agent's pid.

  ## Data types

    * `GenAgent.Event` -- a normalized event emitted by a backend during a turn.
    * `GenAgent.Response` -- the result of a completed turn delivered to
      `c:handle_response/3`.

  ## Telemetry

  GenAgent emits telemetry events for observability:

    * `[:gen_agent, :turn, :start | :stop | :error | :rejected]`
    * `[:gen_agent, :prompt, :start | :stop | :error]`
    * `[:gen_agent, :event, :received]`
    * `[:gen_agent, :state, :changed]`
    * `[:gen_agent, :mailbox, :queued]`
    * `[:gen_agent, :input, :rejected]`
    * `[:gen_agent, :halted]`
    * `[:gen_agent, :terminated]`

  Use the content-free turn events for metrics. The older prompt and
  event telemetry can include prompts, raw errors, and agent state.
  See `GenAgent.Telemetry` for measurements, units, correlation, and
  ordering.

  ## What GenAgent does not do

    * It does not prescribe agent behavior (no retry logic, no summary format).
    * It does not prescribe inter-agent communication (agents can
      `notify/2` each other but the message format is up to you).
    * It does not manage persistence across restarts.
    * It does not manage cost tracking or budgets.

  See `GenAgent.Backend` for the backend behaviour, `GenAgent.Event` and
  `GenAgent.Response` for the data types delivered to callbacks.
  """

  alias GenAgent.{Event, Response}

  @typedoc """
  Opaque term owned by the implementation module, carried across callbacks.
  """
  @type agent_state :: term()

  @typedoc """
  Return value of callbacks that may request a follow-up action.
  """
  @type callback_return ::
          {:noreply, agent_state()}
          | {:prompt, String.t(), agent_state()}
          | {:halt, agent_state()}

  @typedoc """
  Return value of `c:pre_turn/2`. The hook can pass the prompt through
  (optionally rewritten), skip the turn, or halt the agent.
  """
  @type pre_turn_return ::
          {:ok, prompt :: String.t(), agent_state()}
          | {:skip, agent_state()}
          | {:halt, agent_state()}

  @doc """
  Initialize the agent. Return backend options and the initial agent state.

  `opts` is the keyword list passed to `start_agent/2` minus the reserved
  keys consumed by GenAgent itself (`:name`, `:backend`, etc.).
  Use `current_name/0` to read the registered name without adding it to
  options that might be forwarded to the backend.
  """
  @callback init_agent(opts :: keyword()) ::
              {:ok, backend_opts :: keyword(), agent_state()}
              | {:error, reason :: term()}

  @doc """
  A prompt->response turn completed successfully. Decide what to do next.

  `response.prompt` contains the prompt actually dispatched to the backend,
  including any rewrite by `pre_turn/2`. The request ref and prompt can be
  recorded together for a transcript.

  An exception or malformed return stops the agent. Use one of the three
  `t:callback_return/0` shapes; in particular, a follow-up prompt must be a
  binary.
  """
  @callback handle_response(
              request_ref :: reference(),
              response :: Response.t(),
              agent_state()
            ) :: callback_return()

  @doc """
  A prompt->response turn failed. Optional. Decide what to do next.

  Called when the turn could not complete successfully. Covers:

    * The backend returned a synchronous `{:error, reason}` from `c:GenAgent.Backend.prompt/2`.
    * The event stream ended without a terminal `:result` or `:error` event.
    * The backend's event stream emitted a terminal `:error` event.
    * The prompt task crashed (delivered as `{:task_crashed, reason}`).
    * The configured task supervisor was unavailable before the turn started
      (`:task_supervisor_unavailable`). An immediate retry returned here is
      discarded to avoid a loop; a later request may retry after recovery.
    * The watchdog fired (`:timeout`).
    * The in-flight request was interrupted by `interrupt/1` (`:interrupted`).

  Returns the same value shape as `c:handle_response/3`, so the callback
  can go idle, retry with `{:prompt, prompt, state}`, or halt the agent.
  For ask and tell turns, a retry retains the original request reference and
  caller: ask waits, poll stays pending, and completion is sent exactly once,
  with the final outcome. Each failed attempt calls this callback and
  `c:post_turn/3` again. There is no built-in retry cap; keep a budget in state.
  The watchdog applies separately to each attempt.

  Interruption ends the caller's request with `:interrupted`; a prompt returned
  here becomes an independent follow-up. Errors on event and self-chain turns
  also produce independent follow-ups, as does `c:handle_response/3`.
  A retry rejected by the prompt byte cap delivers the original error.
  Pending retries follow queued-work halt and cancellation rules.
  The default implementation provided by `use GenAgent` is `{:noreply, state}`.
  Exceptions and malformed returns are logged and treated as
  `{:noreply, previous_state}` so the original turn error still reaches its caller.
  """
  @callback handle_error(
              request_ref :: reference(),
              reason :: term(),
              agent_state()
            ) :: callback_return()

  @doc """
  An external event arrived via `notify/2`. Optional.

  Exceptions and malformed returns are logged and treated as
  `{:noreply, previous_state}`, including when the notification was buffered
  during a turn.
  """
  @callback handle_event(event :: term(), agent_state()) :: callback_return()

  @doc """
  Handle an ordinary OTP message sent to the agent process. Optional.

  Timers, monitor `:DOWN` messages, and messages from other agents reach this
  callback after GenAgent has handled its own task and Registry messages.
  For example, `Process.send_after(self(), :retry, delay_ms)` can trigger a
  later `{:prompt, text, state}` without blocking the agent process.
  Messages received during a turn are buffered under the same count and byte
  limits as `notify/2` events, then handled against the completed turn's
  state. Return `{:noreply, state}`, `{:prompt, text, state}`, or
  `{:halt, state}` as in `handle_event/2`. If absent, unexpected messages are
  logged and discarded. Exceptions and invalid returns are logged and leave
  the previous state intact.
  """
  @callback handle_info(message :: term(), agent_state()) :: callback_return()

  @doc """
  A streaming event arrived mid-turn. Optional.

  Runs inside the task that is driving the prompt, not the agent process.
  Returns the updated agent state, which is threaded through subsequent
  stream events. On normal stream completion, including a terminal
  `:error` event or EOF without a terminal event, the final state is
  passed to `c:handle_response/3` or `c:handle_error/3` and then
  `c:post_turn/3`. A task crash, interruption, or watchdog kill cannot
  recover task-local callback state; those paths use the agent state
  from before stream consumption. Callback state is volatile and is not
  a durable record of provider activity.
  """
  @callback handle_stream_event(Event.t(), agent_state()) :: agent_state()

  @doc """
  The agent is shutting down. Optional. Clean up resources.
  """
  @callback terminate_agent(reason :: term(), agent_state()) :: term()

  @doc """
  One-time setup hook, fires after `c:init_agent/1` and before the
  first turn. Optional.

  Runs in the agent process, so it blocks the first turn until it
  returns -- but does NOT block `start_agent/2` from returning to the
  caller. Every synchronous call to the agent (`status/2`, `poll/3`,
  `tell/3`, `runtime_snapshot/2`, and so on) waits until the hook
  returns, and their default timeout is `:infinity`. `notify/2` and
  `whereis/1` do not wait. This is the right home for slow async setup that would
  otherwise freeze the starter: cloning a repo, creating a worktree,
  spinning up a sandbox, fetching secrets.

  Return `{:ok, state}` to continue, or `{:error, reason}` to halt the
  agent before any turn runs. On error, `c:terminate_agent/2` is called
  with `{:pre_run_failed, reason}`.

  Crashes are wrapped: the agent halts with
  `{:pre_run_crashed, exception}` and `c:terminate_agent/2` is called
  with that reason. A malformed return stops the agent with
  `:pre_run_invalid`.

  Default implementation: `{:ok, state}`.
  """
  @callback pre_run(agent_state()) ::
              {:ok, agent_state()} | {:error, reason :: term()}

  @doc """
  Per-turn pre-dispatch hook. Optional.

  Fires before each prompt is dispatched to the backend, inside the
  agent process. Can observe, mutate state, rewrite the prompt (for
  augmentation or templating), skip the turn with `:skip`, or halt the
  agent entirely with `:halt`.

  Use cases: prompt templating (inject context) and gating (halt if an
  external signal says stop). For rate limiting, use a timer and a
  `handle_event/2` callback to start work later, as in the Retry guide.

  The hook runs synchronously in the agent process before the prompt task
  is started. While it runs, synchronous calls to the agent (`status/2`,
  `poll/3`, `tell/3`, `runtime_snapshot/2`, and so on) wait, with a
  default timeout of `:infinity`. Sleeping here therefore delays those
  calls on every dispatch and may prevent orderly shutdown before the
  child spec's `:shutdown` timeout. `notify/2` and `whereis/1` do not wait.

  When the prompt is rewritten, `[:gen_agent, :prompt, :start]`
  telemetry carries both the original and rewritten prompt plus a
  `rewritten: true` flag so the transformation is traceable.

  Crashes are caught: an external ask or tell is skipped with
  `:pre_turn_skipped` and the agent returns to `:idle`. For prompts generated
  by `handle_response/3` or `handle_event/2`, a skip, crash, or malformed
  return emits prompt-error telemetry and calls `c:handle_error/3` so the
  agent can retry or halt. Crashes use `{:pre_turn_crashed, exception_kind}`
  on that generated-prompt path. Immediate generated-prompt retries are
  paced so agent calls remain responsive even if the hook keeps rejecting.

  Default implementation: `{:ok, prompt, state}`.
  """
  @callback pre_turn(prompt :: String.t(), agent_state()) :: pre_turn_return()

  @doc """
  Per-turn post-dispatch hook. Optional.

  Fires after each turn, AFTER `c:handle_response/3` or
  `c:handle_error/3` has returned its decision. The hook sees the
  post-decision state. Runs regardless of which decision callback ran
  or what it returned.

  The outcome is `{:ok, response}` for a successful turn or
  `{:error, reason}` for a failed one -- the same data delivered to
  the decision callbacks. The hook cannot override the decision
  callback's transition (`{:noreply, ...}`, `{:prompt, ...}`,
  `{:halt, ...}`); it only updates state.

  Use cases: commit-per-turn (stateful side effect), persist a turn
  record, update a per-turn metric that needs to live on agent state.
  For pure observation, prefer telemetry handlers on
  `[:gen_agent, :prompt, :stop]`.

  Crashes or malformed returns are logged and the server continues
  with the transition the decision callback chose. The turn is not
  unwound.

  Default implementation: `{:ok, state}`.
  """
  @callback post_turn(
              outcome :: {:ok, Response.t()} | {:error, reason :: term()},
              request_ref :: reference(),
              agent_state()
            ) :: {:ok, agent_state()}

  @doc """
  Clean-completion hook. Optional.

  Fires when `c:handle_response/3`, `c:handle_error/3`,
  `c:handle_event/2`, or `c:pre_turn/2` returns
  `{:halt, state}`. Runs before the `[:gen_agent, :halted]` telemetry
  event is emitted.

  On turn completion, `c:post_turn/3` runs first, then notifications
  buffered during the turn are applied in order, then this hook and
  halted telemetry receive the resulting state. A buffered notification
  that halts does not skip later buffered notifications or finalize
  completion partway through the batch. No further prompt is dispatched
  during this drain.

  Notifications arriving after completion may still update a halted
  agent's state. They do not retroactively change this completion
  snapshot or rerun the hook.

  Runs once per transition to halted. Further halt decisions while the
  agent is already halted do not rerun the hook. After `resume/1`, a new
  halt transition runs it again.

  Does NOT fire on crashes, `stop/1`, supervisor shutdown, or any
  abnormal exit -- `c:terminate_agent/2` covers those paths.

  Use cases: create a PR, post a completion summary, mark a task done
  in an external tracker. The semantic distinction from
  `c:terminate_agent/2` is "completion" vs "termination."

  Crashes are caught: a warning is logged and the halt transition
  still completes normally. A failing last-chance hook does not keep a
  dead agent alive.

  Default implementation: `:ok`.
  """
  @callback post_run(agent_state()) :: :ok

  @optional_callbacks [
    handle_error: 3,
    handle_event: 2,
    handle_info: 2,
    handle_stream_event: 2,
    terminate_agent: 2,
    pre_run: 1,
    pre_turn: 2,
    post_turn: 3,
    post_run: 1
  ]

  # ---------------------------------------------------------------------------
  # use GenAgent
  # ---------------------------------------------------------------------------

  @doc false
  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour GenAgent

      @impl GenAgent
      def handle_error(_ref, _reason, state), do: {:noreply, state}

      @impl GenAgent
      def handle_event(_event, state), do: {:noreply, state}

      @impl GenAgent
      def handle_stream_event(_event, state), do: state

      @impl GenAgent
      def terminate_agent(_reason, _state), do: :ok

      @impl GenAgent
      def pre_run(state), do: {:ok, state}

      @impl GenAgent
      def pre_turn(prompt, state), do: {:ok, prompt, state}

      @impl GenAgent
      def post_turn(_outcome, _ref, state), do: {:ok, state}

      @impl GenAgent
      def post_run(_state), do: :ok

      def child_spec(opts), do: GenAgent.child_spec(__MODULE__, opts)

      defoverridable handle_error: 3,
                     handle_event: 2,
                     handle_stream_event: 2,
                     terminate_agent: 2,
                     pre_run: 1,
                     pre_turn: 2,
                     post_turn: 3,
                     post_run: 1,
                     child_spec: 1
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @typedoc "Name under which an agent is registered in `GenAgent.Registry`."
  @type name :: term()

  @typedoc "Reference returned for `tell/2` requests."
  @type request_ref :: reference()

  @default_call_timeout :infinity

  @doc """
  Return the registered name from an agent callback, or `nil` elsewhere.

  Available in `init_agent/1`, turn and lifecycle callbacks, and
  `handle_stream_event/2`, which runs in the prompt task. The name is scoped
  to those processes; tasks spawned by application callbacks do not inherit
  it. This avoids duplicating `:name` in backend options or agent state just
  to identify the current agent.
  """
  @spec current_name() :: name() | nil
  def current_name, do: Process.get({__MODULE__, :current_name})

  @doc """
  Start an agent under the GenAgent supervision tree.

  `module` is the implementation module (the one that `use GenAgent`).
  `opts` must include:

    * `:name` -- the name the agent will register under in `GenAgent.Registry`.
    * `:backend` -- the backend module implementing `GenAgent.Backend`.

  Event evidence is bounded by `:max_events_per_turn` (default `1_000`)
  and `:max_event_bytes_per_turn` (default `1_048_576`), measured as the
  sum of `:erlang.external_size/1` for retained `GenAgent.Event` values.
  Both limits must be positive integers. With the default
  `event_retention: :compact`, an oversized turn succeeds with a bounded
  prefix in `Response.events` and `Response.event_coverage` reports omissions.
  All normalized events still reach `c:handle_stream_event/2`, and the
  terminal result, full response text, and usage remain available separately.
  Use `event_retention: :lossless` to require a complete event list; an event
  that exceeds either limit then fails the turn with
  `{:event_capture_overflow, diagnostics}` before entering the callback.

  Pending prompt and deferred notification queues have independent count
  and payload-byte limits: `:max_pending_prompts` and
  `:max_pending_notifications` (both default `1_000`), and
  `:max_pending_prompt_bytes` and `:max_pending_notification_bytes`
  (both default `1_048_576`). Limits are non-negative integers; zero
  disables that pending queue. Bytes are the sum of
  `:erlang.external_size/1` of each queued prompt or notification payload
  (including ordinary OTP messages deferred for `c:handle_info/2`),
  not the entire process memory. The active prompt and notifications
  handled immediately while idle are not pending. Self-chaining has one
  reserved slot outside the prompt count limit, but its payload must fit
  `:max_pending_prompt_bytes`.

  `:watchdog_ms` is the per-turn deadline in milliseconds (default
  `600_000`). It must be a positive integer or `:infinity`, which disables
  the watchdog. `:max_tell_results` is the number of completed `tell/2`
  results kept for `poll/2` (default `100`). `:max_tell_result_bytes`
  bounds their combined serialized size (default `8_388_608`, or 8 MiB),
  measured with `:erlang.external_size/1` for each ref and result pair.
  Both limits must be non-negative integers; the oldest results are evicted
  first when either limit is exceeded. Zero retains none. A single result
  larger than the byte limit is immediately evicted. Results sent by
  `tell_with_completion/4` remain pollable until evicted and count against
  both limits. This measures cached payloads, not total process memory.

  `:shutdown` is the supervisor's graceful shutdown timeout in milliseconds
  (default `5_000`), or `:infinity`. A callback still running when this
  timeout expires is killed and termination callbacks cannot run. Choose a
  value longer than any bounded callback or cleanup operation; `:infinity`
  can block the owning supervisor indefinitely. An explicit `nil` uses the
  default.

  Invalid values for the watchdog and the capture and pending limits make
  `start_agent/2` return `{:error, {:init_failed, :error, ArgumentError}}`.
  An invalid `:shutdown` raises `ArgumentError` while building the child spec.
  A missing `:name` or `:backend` raises `KeyError` in the caller.
  An explicit `nil` for a limit is treated as unset and uses the default.

  The reserved keys `:name`, `:backend`, `:watchdog_ms`, `:shutdown`,
  `:max_tell_results`, `:max_tell_result_bytes`, `:max_events_per_turn`,
  `:max_event_bytes_per_turn`, `:event_retention`, `:max_pending_prompts`,
  `:max_pending_prompt_bytes`, `:max_pending_notifications`, and
  `:max_pending_notification_bytes` are consumed and not forwarded. Any
  other option, including `:task_supervisor`, is forwarded to
  `c:init_agent/1`. `start_agent/2` always uses `GenAgent.TaskSupervisor`;
  use `child_spec/2` to select a different task supervisor.

  The child uses `restart: :temporary`. If it exits, call `start_agent/2`
  explicitly to create another agent; its previous state is not restored.
  An agent also exits if its Registry partition is lost, so it cannot remain
  alive but unreachable by name after a Registry restart.
  The returned pid is for monitoring or supervision. Pass the registered
  `:name` to the public client functions, including `stop/1`.
  """
  @spec start_agent(module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(module, opts) when is_atom(module) and is_list(opts) do
    DynamicSupervisor.start_child(
      GenAgent.AgentSupervisor,
      agent_child_spec(module, opts, GenAgent.TaskSupervisor)
    )
  end

  @doc """
  Build a temporary agent child spec for a caller-owned supervisor.

  Requires `:name`, `:backend`, and `:task_supervisor`. The selected
  `Task.Supervisor` must already be running; prompt tasks never fall back
  to `GenAgent.TaskSupervisor`. Other options have the same meaning as in
  `start_agent/2`.

  Start the spec with `DynamicSupervisor.start_child/2`, or place
  `{MyAgent, opts}` in a static `Supervisor` child list when `MyAgent` uses
  `GenAgent`. The tuple calls the module's overridable `child_spec/1`, which
  delegates here. The agent is registered in `GenAgent.Registry`, so the
  regular name-based APIs work.
  Names must be unique across both caller-owned and global agents. Use
  `stop/2` with the owning supervisor to stop an individual agent. Static
  children retain `restart: :temporary`: once stopped or crashed, they are
  removed from the supervisor and must be started explicitly again.

  Put the task supervisor before the agent supervisor in the caller's
  supervision tree so agents shut down before their prompt-task supervisor.
  Use `:rest_for_one` if loss of the task supervisor should also stop the
  agents. See the README for an example.
  """
  @spec child_spec(module(), keyword()) :: Supervisor.child_spec()
  def child_spec(module, opts) when is_atom(module) and is_list(opts) do
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    agent_child_spec(module, Keyword.delete(opts, :task_supervisor), task_supervisor)
  end

  defp agent_child_spec(module, opts, task_supervisor) do
    name = Keyword.fetch!(opts, :name)
    backend = Keyword.fetch!(opts, :backend)

    {server_opts, init_opts} =
      Keyword.split(opts, [
        :name,
        :backend,
        :watchdog_ms,
        :shutdown,
        :max_tell_results,
        :max_tell_result_bytes,
        :max_events_per_turn,
        :max_event_bytes_per_turn,
        :event_retention,
        :max_pending_prompts,
        :max_pending_prompt_bytes,
        :max_pending_notifications,
        :max_pending_notification_bytes
      ])

    child_opts =
      [
        name: name,
        backend: backend,
        module: module,
        task_supervisor: task_supervisor,
        init_opts: init_opts,
        register: via(name)
      ]
      |> maybe_put(:shutdown, Keyword.get(server_opts, :shutdown))
      |> maybe_put(:watchdog_ms, Keyword.get(server_opts, :watchdog_ms))
      |> maybe_put(:max_tell_results, Keyword.get(server_opts, :max_tell_results))
      |> maybe_put(:max_tell_result_bytes, Keyword.get(server_opts, :max_tell_result_bytes))
      |> maybe_put(:max_events_per_turn, Keyword.get(server_opts, :max_events_per_turn))
      |> maybe_put(:max_event_bytes_per_turn, Keyword.get(server_opts, :max_event_bytes_per_turn))
      |> maybe_put(:event_retention, Keyword.get(server_opts, :event_retention))
      |> maybe_put(:max_pending_prompts, Keyword.get(server_opts, :max_pending_prompts))
      |> maybe_put(:max_pending_prompt_bytes, Keyword.get(server_opts, :max_pending_prompt_bytes))
      |> maybe_put(
        :max_pending_notifications,
        Keyword.get(server_opts, :max_pending_notifications)
      )
      |> maybe_put(
        :max_pending_notification_bytes,
        Keyword.get(server_opts, :max_pending_notification_bytes)
      )

    GenAgent.Server.child_spec(child_opts)
  end

  @doc """
  Send a synchronous prompt to an agent.

  Blocks until the logical request completes and returns `{:ok, response}`
  or `{:error, reason}`. A `handle_error/3` retry keeps the caller waiting
  and returns only the final attempt's outcome. If the agent is processing another
  prompt, the caller is queued transparently and unblocks when its
  queued turn finishes.

  If admission to the pending prompt queue fails, returns
  `{:error, {:overloaded, info}}` immediately; no turn is accepted.
  `info` includes the queue, count or byte limit reached, current count
  and bytes, incoming bytes, and configured maxima.

  An orderly agent stop replies to an active or queued ask with
  `{:error, {:agent_terminated, reason}}`. A call the agent has not yet
  handled, an abrupt agent death, or a forced kill can still exit the
  caller; catch `:exit` if the caller must survive those cases.

  The default timeout is `:infinity`. The agent's own watchdog is the
  primary timeout mechanism -- callers generally should not need to set
  their own. Supplying a shorter timeout here will exit on expiry
  without affecting the agent. A queued ask is dropped if its calling
  process dies. If that ask is already active, it keeps running. A live
  caller's timeout leaves its ask queued or running. For cancellable queued
  work, use `tell/3` or `tell_with_completion/4` and `cancel_request/3`.
  Returns `{:error, :not_found}` if the agent name is not registered.
  """
  @spec ask(name(), String.t(), timeout()) ::
          {:ok, Response.t()} | {:error, term()}
  def ask(name, prompt, timeout \\ @default_call_timeout) when is_binary(prompt) do
    call(name, {:ask, prompt}, timeout)
  end

  @doc """
  Send an asynchronous prompt to an agent.

  Returns `{:ok, ref}` when the agent accepts the prompt. A `pre_turn/2`
  callback runs before acceptance for an idle agent, so this call waits for
  that callback even though it does not wait for the backend result. Use
  `poll/2` to check on the result. The same queueing semantics as `ask/2`
  apply. When a pending queue limit is reached, returns
  `{:error, {:overloaded, info}}` without
  an accepted ref.
  Returns `{:error, :not_found}` if the agent name is not registered.
  """
  @spec tell(name(), String.t(), timeout()) :: {:ok, request_ref()} | {:error, term()}
  def tell(name, prompt, timeout \\ @default_call_timeout) when is_binary(prompt) do
    call(name, {:tell, prompt}, timeout)
  end

  @doc """
  Submit an asynchronous prompt and opt into one completion message.

  `recipient` is a pid (defaults to the calling process). On an accepted
  request this returns `{:ok, ref}` and sends the recipient
  `{:gen_agent, :completion, name, ref, {:ok, response}}` or
  `{:gen_agent, :completion, name, ref, {:error, reason}}` when the logical
  request finishes. The recipient is registered within the same agent call
  that accepts the request, so even an immediate `pre_turn/2` skip or fast
  backend response can be delivered before this function returns. Match on
  the returned ref to correlate the message.

  Admission failure returns `{:error, {:overloaded, info}}` with no ref or
  completion message. Accepted queued requests deliver after their turn
  completes, unless cancelled with `cancel_request/3`. A cancelled queued
  request delivers `{:gen_agent, :completion, name, ref, {:error, :cancelled}}`
  without running turn lifecycle callbacks. `pre_turn/2` skip, halt and
  invalid results deliver their corresponding error without starting a
  turn. Successful and failed turns deliver after their decision and
  `post_turn/3` callbacks. Interruptions deliver an error immediately.
  A watchdog timeout or backend failure may be retried by `handle_error/3`;
  the recipient receives only the final success or error under the original
  ref. A crashing `handle_response/3` callback stops
  the agent before completion; monitor the agent when its death matters.

  Delivery is a single BEAM message sent at most once per accepted request.
  It is independent of the bounded `poll/3` result cache. A dead recipient
  does not receive the message, and any agent exit, including an orderly
  stop, can leave accepted requests without a completion message; a monitor
  reports that uncertainty.
  This does not prove that an external provider process has settled.
  The request ref remains suitable for `interrupt_request/3` while active
  or `cancel_request/3` while queued. A new agent under the same name never
  reuses it.

  The five-argument form accepts `on_halt: :fail`. It rejects a new request
  with `{:error, :halted}` when the agent is already halted, and completes
  an opted-in queued request with `{:error, :halted}` if the agent halts
  before dispatch. The default preserves the ordinary queue-until-resume
  behavior. This is useful for callers, such as ensembles, that cannot
  resume a halted agent themselves.

  The five-argument form also accepts `stream_to: pid`. The process
  receives `{:gen_agent, :event, name, ref, %GenAgent.Event{}}` for each
  event the backend streams during that request's turn, in stream order.
  Events are relayed through the agent after `c:handle_stream_event/2`
  runs, so for one ref they arrive before the completion message when
  `stream_to` and `recipient` are the same process. Separate processes
  have no shared arrival order. Streaming is off by default and
  independent of `event_retention`: compact mode relays events that the
  retained history omits, and lossless mode does not relay the event it
  rejects for exceeding the capture limits.
  Caller-owned retries relay each attempt's events under the same request
  ref, so an intermediate `:error` event can precede later successful events
  and the single final completion message.

  Delivery has no backpressure and is best effort. A dead `stream_to`
  process is ignored. An interrupt or watchdog timeout can drop events
  that were generated but not yet relayed; nothing is relayed for a ref
  after its request has finished. A request that never starts a turn
  (cancelled, rejected by `pre_turn/2`, halted or failed dispatch)
  produces no events.
  Returns `{:error, :not_found}` if the agent name is not registered.
  """
  @spec tell_with_completion(name(), String.t(), pid(), timeout()) ::
          {:ok, request_ref()} | {:error, term()}
  def tell_with_completion(name, prompt, recipient \\ self(), timeout \\ @default_call_timeout)
      when is_binary(prompt) and is_pid(recipient) do
    call(name, {:tell_with_completion, prompt, recipient}, timeout)
  end

  @spec tell_with_completion(name(), String.t(), pid(), timeout(), keyword()) ::
          {:ok, request_ref()} | {:error, term()}
  def tell_with_completion(name, prompt, recipient, timeout, opts)
      when is_binary(prompt) and is_pid(recipient) and is_list(opts) do
    on_halt = Keyword.get(opts, :on_halt, :queue)

    if on_halt not in [:queue, :fail] do
      raise ArgumentError, "expected :on_halt to be :queue or :fail"
    end

    stream_to = Keyword.get(opts, :stream_to)

    unless is_nil(stream_to) or is_pid(stream_to) do
      raise ArgumentError, "expected :stream_to to be nil or a pid"
    end

    message =
      if stream_to do
        {:tell_with_completion, prompt, recipient, on_halt, stream_to}
      else
        {:tell_with_completion, prompt, recipient, on_halt}
      end

    call(name, message, timeout)
  end

  @doc """
  Check the status of a previously-issued `tell/2` request.

  Returns:

    * `{:ok, :pending}` if the request is queued, in-flight, or between
      caller-owned retry attempts.
    * `{:ok, :completed, response}` if the turn finished successfully.
    * `{:error, reason}` if the turn failed, including `{:error, :cancelled}`
      for a cancelled queued request.
    * `{:error, :not_found}` if the ref is unknown (never issued, or
      pruned from the bounded result cache).

  Refs returned from `tell/2` and `tell_with_completion/4` are pollable
  until evicted by the count or byte limit. Refs from `ask/2` are internal
  and reply directly to the caller.
  Returns `{:error, :not_found}` if the agent name is not registered.
  """
  @spec poll(name(), request_ref(), timeout()) ::
          {:ok, :pending}
          | {:ok, :completed, Response.t()}
          | {:error, term()}
  def poll(name, ref, timeout \\ @default_call_timeout) when is_reference(ref) do
    call(name, {:poll, ref}, timeout)
  end

  @doc """
  Push an external event into the agent.

  The event is delivered to `c:handle_event/2`. If the callback
  returns `{:prompt, text, state}` the prompt is dispatched (or
  queued, if the agent is busy).

  Asynchronous. Returns `:ok` immediately, including when the agent later
  rejects the event because its pending queue is full. Rejections emit
  `[:gen_agent, :input, :rejected]` telemetry. Use `notify_ack/3` when the
  sender needs an in-memory admission result.
  """
  @spec notify(name(), term()) :: :ok
  def notify(name, event) do
    :gen_statem.cast(via(name), {:notify, event})
  end

  @doc """
  Send an event and wait for the agent to acknowledge admission.

  Returns `:ok` when the event was handled immediately or retained for
  delivery after the current turn. Returns `{:error, {:overloaded, info}}`
  when the pending notification queue cannot hold it, or an event
  handled while halted generates a prompt that cannot be queued. This
  acknowledges in-memory handling or retention, not durable delivery or
  a guarantee that a callback-generated prompt will run. A deferred
  callback-generated prompt can be rejected later if the prompt queue is
  full; the agent's `c:handle_error/3` receives that overload. The legacy
  `notify/2` remains a best-effort asynchronous cast and always returns
  `:ok`.
  Returns `{:error, :not_found}` if the agent name is not registered.
  """
  @spec notify_ack(name(), term(), timeout()) :: :ok | {:error, term()}
  def notify_ack(name, event, timeout \\ @default_call_timeout) do
    call(name, {:notify_ack, event}, timeout)
  end

  @doc """
  Interrupt an in-flight turn.

  Kills the prompt task and delivers `{:error, :interrupted}` to the
  waiting caller (if any). No-op if the agent is idle.

  Asynchronous. Returns `:ok` immediately.
  """
  @spec interrupt(name()) :: :ok
  def interrupt(name) do
    :gen_statem.cast(via(name), :interrupt)
  end

  @doc """
  Interrupt the active turn only if its request reference matches `ref`.

  Returns `{:ok, :accepted}` when the agent has cancelled that turn,
  `{:error, :not_current}` when another turn is active, or
  `{:error, :idle}` when no turn is active. A queued request is not
  interruptible through this API; use `cancel_request/3` for a queued tell.
  Unlike `interrupt/1`, this operation
  is acknowledged by the agent and cannot cancel a successor turn after
  the observed request finishes. It is also safe against a replacement
  agent registered under the same name, because request references are
  unique.

  The acknowledgement describes the agent's decision and BEAM task
  cancellation. It does not establish provider or OS process settlement.
  The default call timeout is `:infinity`.
  Returns `{:error, :not_found}` if the agent name is not registered.
  """
  @spec interrupt_request(name(), request_ref(), timeout()) ::
          {:ok, :accepted} | {:error, :not_current | :idle | :not_found}
  def interrupt_request(name, ref, timeout \\ @default_call_timeout) when is_reference(ref) do
    call(name, {:interrupt_request, ref}, timeout)
  end

  @doc """
  Cancel a queued `tell/3` or `tell_with_completion/4` request by exact ref.

  Returns `{:ok, :cancelled}` when the queued request is removed, or when
  its cancellation result is still cached. The cancellation releases its
  queue count and bytes immediately. `poll/3` then returns
  `{:error, :cancelled}`. A completion recipient receives exactly one
  `{:gen_agent, :completion, name, ref, {:error, :cancelled}}` message.

  Returns `{:error, :current}` for an active tell turn; use
  `interrupt_request/3` to interrupt it. Returns
  `{:error, :already_finished}` for a cached terminal result other than
  cancellation. Returns `{:error, :not_found}` for an unknown ref, a
  pruned result, or an internal ask or event ref. Cancellation results
  count toward the bounded `max_tell_results` cache. Once pruned, a
  cancelled ref also returns `{:error, :not_found}`.

  A queued turn has not started, so cancellation does not call
  `handle_response/3`, `handle_error/3`, or `post_turn/3`. The agent
  processes cancellation and dispatch in order: if dispatch happened
  first, this returns `{:error, :current}` and leaves the turn alone.
  The default call timeout is `:infinity`.
  Returns `{:error, :not_found}` if the agent name is not registered.
  """
  @spec cancel_request(name(), request_ref(), timeout()) ::
          {:ok, :cancelled} | {:error, :current | :already_finished | :not_found}
  def cancel_request(name, ref, timeout \\ @default_call_timeout) when is_reference(ref) do
    call(name, {:cancel_request, ref}, timeout)
  end

  @doc """
  Halt an agent from outside its callback module.

  When idle, the agent enters the halted state and runs `post_run/1`.
  An active turn is allowed to finish its callbacks first; the halt is
  pending until then. Queued prompts remain paused until `resume/1`.
  `resume/1` during the active turn cancels a pending external halt.
  Calling `halt/1` again is idempotent. Asynchronous, like `resume/1`;
  returns `:ok` immediately. `status/2` and `runtime_snapshot/2`
  expose `:halt_pending` while the active turn is finishing.
  """
  @spec halt(name()) :: :ok
  def halt(name) do
    :gen_statem.cast(via(name), :halt)
  end

  @doc """
  Resume a halted agent.

  Clears the `halted` flag and re-drains the mailbox, or cancels a
  pending external halt if an active turn is still running. No-op
  otherwise.

  Asynchronous. Returns `:ok` immediately.
  """
  @spec resume(name()) :: :ok
  def resume(name) do
    :gen_statem.cast(via(name), :resume)
  end

  @doc """
  Reset an agent's backend conversation context without restarting the agent.

  The backend must implement `c:GenAgent.Backend.reset_session/1`. This
  call is accepted only while the agent is idle; an active turn returns
  `{:error, :busy}` so its session cannot be replaced under it. A draining
  agent returns `{:error, :draining}`. Callback state and queued prompts
  are preserved. A backend without the callback returns
  `{:error, :unsupported}`. Returns `{:error, :not_found}` if the agent
  is not registered. The default call timeout is `:infinity`.
  """
  @spec reset_session(name(), timeout()) :: :ok | {:error, term()}
  def reset_session(name, timeout \\ @default_call_timeout) do
    call(name, :reset_session, timeout)
  end

  @doc """
  Read an agent's current status.

  This compatibility API includes the full callback-maintained
  `agent_state`. While a turn is processing, that value is the server's
  latest retained state, not a live read of state inside the prompt task.
  Use `runtime_snapshot/2` for a bounded metadata-only view.
  Returns `{:error, :not_found}` if the agent name is not registered.
  """
  @spec status(name(), timeout()) ::
          %{
            state: :idle | :processing,
            name: term(),
            queued: non_neg_integer(),
            current_request: request_ref() | nil,
            halted: boolean(),
            halt_pending: boolean(),
            draining: boolean(),
            agent_state: term()
          }
          | {:error, :not_found}
  def status(name, timeout \\ @default_call_timeout) do
    call(name, :status, timeout)
  end

  @typedoc "Bounded, metadata-only observation of one agent's runtime state."
  @type runtime_snapshot :: %{
          phase: :idle | :processing,
          halted: boolean(),
          halt_pending: boolean(),
          draining: boolean(),
          pending_prompts: non_neg_integer(),
          pending_notifications: non_neg_integer(),
          self_chain_pending: boolean(),
          current_request:
            nil
            | %{
                ref: request_ref(),
                origin: :ask | :tell | :event | :self_chain,
                attempt: pos_integer(),
                elapsed_ms: non_neg_integer(),
                watchdog_ms: non_neg_integer() | :infinity
              }
        }

  @doc """
  Read a bounded, metadata-only runtime snapshot of an agent.

  `pending_prompts` counts the prompt mailbox; `pending_notifications`
  counts notifications and ordinary OTP messages buffered during a turn;
  `self_chain_pending`
  reports a separately held callback-generated follow-up prompt.
  `halt_pending` means an external halt was requested while a turn was
  active and will take effect after that turn finishes.
  `draining` is true after `drain/2` has stopped accepting work and before
  the agent exits.
  `current_request` is `nil` when idle and otherwise contains the
  volatile request ref, its origin (`:event` and `:self_chain` are
  callback-origin turns), 1-based attempt number, elapsed monotonic
  milliseconds since dispatch,
  and the configured watchdog duration. It excludes prompts, caller
  identities, callback state, backend sessions, events, and queued
  payloads. Elapsed time is an observation, not an exact countdown to
  the watchdog firing.

  The snapshot is a point-in-time view of this BEAM coordinator, not
  durable application state, admission authority, or proof that external
  provider work has settled. The default call timeout is `:infinity`.
  Returns `{:error, :not_found}` if the agent name is not registered.
  """
  @spec runtime_snapshot(name(), timeout()) :: runtime_snapshot() | {:error, :not_found}
  def runtime_snapshot(name, timeout \\ @default_call_timeout) do
    call(name, :runtime_snapshot, timeout)
  end

  @doc """
  Stop an agent after its active turn finishes.

  Drain immediately refuses new asks, tells, and acknowledged notifications
  with `{:error, :draining}`. Already queued asks receive that error and
  queued `tell_with_completion/4` recipients receive a completion with the
  same error. Queued notifications and callback-generated follow-up prompts
  are discarded. The active turn runs through its decision and `post_turn/3`
  callbacks, then the agent terminates its backend session and exits. Plain
  `notify/2` casts sent during drain remain best effort and are ignored.

  Returns `:ok` only after the agent process has exited normally, or
  `{:error, :not_found}` if it is absent at lookup. If it exits abnormally,
  returns `{:error, {:agent_down, reason}}`. The timeout covers both the
  admission call and the wait for process exit; a caller-side timeout does
  not cancel the drain. As with other synchronous APIs, a timeout or a
  concurrent agent death during the admission call can exit the caller.
  The default timeout is `:infinity`.
  """
  @spec drain(name(), timeout()) :: :ok | {:error, :not_found | :timeout | {:agent_down, term()}}
  def drain(name, timeout \\ @default_call_timeout) do
    case whereis(name) do
      nil ->
        {:error, :not_found}

      pid ->
        monitor = Process.monitor(pid)

        deadline =
          if timeout == :infinity,
            do: :infinity,
            else: System.monotonic_time(:millisecond) + timeout

        try do
          :ok = :gen_statem.call(pid, :drain, timeout)

          remaining =
            if deadline == :infinity,
              do: :infinity,
              else: max(deadline - System.monotonic_time(:millisecond), 0)

          receive do
            {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
            {:DOWN, ^monitor, :process, ^pid, reason} -> {:error, {:agent_down, reason}}
          after
            remaining -> {:error, :timeout}
          end
        after
          Process.demonitor(monitor, [:flush])
        end
    end
  end

  @doc """
  Stop an agent.

  Terminates the agent process via its owning supervisor.
  Pass the supervisor as the second argument for an agent started with
  `child_spec/2` or a `{MyAgent, opts}` tuple; the default is
  `GenAgent.AgentSupervisor`. For a static `Supervisor`, the child ID is
  the agent's registered name.
  Active and queued `ask/3` callers receive an `:agent_terminated` error
  when the agent processes the orderly shutdown. Accepted
  `tell_with_completion/4` requests do not receive a synthetic completion;
  recipients should monitor the agent to detect that uncertainty.
  A callback runs inside the agent process and can delay shutdown. If it
  exceeds the child spec's `:shutdown` timeout (default `5_000` ms), the
  supervisor kills the agent and `terminate_agent/2` and backend
  `terminate_session/1` cannot run. Configure `:shutdown` when starting an
  agent whose callbacks or cleanup can take longer. A blocked callback can
  also delay unrelated operations on the same supervisor during
  `stop/2`.
  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec stop(name(), GenServer.server()) :: :ok | {:error, :not_found}
  def stop(name, supervisor \\ GenAgent.AgentSupervisor) do
    case whereis(name) do
      nil ->
        {:error, :not_found}

      pid ->
        case DynamicSupervisor.terminate_child(supervisor, pid) do
          {:error, :not_found} -> stop_static_child(supervisor, name, pid)
          result -> result
        end
    end
  end

  defp stop_static_child(supervisor, name, pid) do
    if Enum.any?(Supervisor.which_children(supervisor), fn
         {^name, ^pid, _, _} -> true
         _ -> false
       end) do
      Supervisor.terminate_child(supervisor, name)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Look up the pid of a registered agent, or `nil` if not found. Pass the name,
  not this pid, to public client functions.
  """
  @spec whereis(name()) :: pid() | nil
  def whereis(name) do
    case Registry.whereis_name({GenAgent.Registry, name}) do
      :undefined -> nil
      pid -> pid
    end
  end

  @doc """
  Return an unordered list of registered agent names.

  This is a point-in-time view of `GenAgent.Registry`; agents running without
  registration are excluded. Returned agents are not guaranteed to remain
  alive, and registry cleanup may briefly lag agent termination.
  """
  @spec list() :: [name()]
  def list do
    Registry.select(GenAgent.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp call(name, request, timeout) do
    case whereis(name) do
      nil -> {:error, :not_found}
      _pid -> :gen_statem.call(via(name), request, timeout)
    end
  end

  defp via(name), do: {:via, Registry, {GenAgent.Registry, name}}

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)
end
