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

  ## Installation

      def deps do
        [
          {:gen_agent, "~> 0.3.0"}, # x-release-please-version
          # Plus at least one backend:
          {:gen_agent_claude, "~> 0.1.0"},
          {:gen_agent_codex, "~> 0.1.0"},
          {:gen_agent_anthropic, "~> 0.1.0"},
          {:gen_agent_openai, "~> 0.1.0"}
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
      {:ok, :completed, response} = GenAgent.poll("my-coder", ref)

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
    * `c:handle_stream_event/2` (optional) -- a backend event arrived mid-turn.
      Runs inside the prompt task, not the agent process.
    * `c:terminate_agent/2` (optional) -- the agent is shutting down.

  Lifecycle hooks (all optional):

    * `c:pre_run/1` -- one-time setup after `init_agent`, before the first turn.
    * `c:pre_turn/2` -- before each dispatch. Can rewrite the prompt, skip, or halt.
    * `c:post_turn/3` -- after each turn, post-decision. For state-mutating side effects.
    * `c:post_run/1` -- on clean `{:halt, state}` from a decision callback or
      `c:pre_turn/2`. For completion side effects.

  The `use GenAgent` macro provides default implementations of the optional
  callbacks and lifecycle hooks.

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

  ## Public API

    * `start_agent/2` -- start an agent under the supervision tree.
    * `child_spec/2` -- build a child spec for caller-owned supervision.
    * `ask/3` -- synchronous prompt, blocks until the turn finishes.
    * `tell/3` -- async prompt, returns a ref for `poll/3`.
    * `tell_with_completion/4` -- async prompt with request-scoped completion delivery.
    * `poll/3` -- check on a previously-issued `tell/3`.
    * `notify/2` -- push an external event into `c:handle_event/2`.
    * `notify_ack/3` -- acknowledge in-memory notification admission.
    * `interrupt/1` -- cancel an in-flight turn.
    * `interrupt_request/3` -- acknowledge cancellation for a matching request ref.
    * `resume/1` -- unhalt an agent and drain its mailbox.
    * `status/2` -- read the agent's current state.
    * `runtime_snapshot/2` -- read bounded runtime metadata.
    * `stop/1` -- terminate the agent.
    * `stop/2` -- terminate an agent under its caller-owned supervisor.
    * `whereis/1` -- look up an agent's pid.

  ## Data types

    * `GenAgent.Event` -- a normalized event emitted by a backend during a turn.
    * `GenAgent.Response` -- the result of a completed turn delivered to
      `c:handle_response/3`.

  ## Telemetry

  GenAgent emits telemetry events for observability:

    * `[:gen_agent, :prompt, :start | :stop | :error]`
    * `[:gen_agent, :event, :received]`
    * `[:gen_agent, :state, :changed]`
    * `[:gen_agent, :mailbox, :queued]`
    * `[:gen_agent, :input, :rejected]`
    * `[:gen_agent, :halted]`

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
  """
  @callback init_agent(opts :: keyword()) ::
              {:ok, backend_opts :: keyword(), agent_state()}
              | {:error, reason :: term()}

  @doc """
  A prompt->response turn completed successfully. Decide what to do next.
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
    * The watchdog fired (`:timeout`).
    * The in-flight request was interrupted by `interrupt/1` (`:interrupted`).

  Returns the same value shape as `c:handle_response/3`, so the callback
  can go idle, self-chain a follow-up prompt (useful for retry), or halt
  the agent. The default implementation provided by `use GenAgent` is
  `{:noreply, state}`.
  """
  @callback handle_error(
              request_ref :: reference(),
              reason :: term(),
              agent_state()
            ) :: callback_return()

  @doc """
  An external event arrived via `notify/2`. Optional.
  """
  @callback handle_event(event :: term(), agent_state()) :: callback_return()

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
  caller. This is the right home for slow async setup that would
  otherwise freeze the starter: cloning a repo, creating a worktree,
  spinning up a sandbox, fetching secrets.

  Return `{:ok, state}` to continue, or `{:error, reason}` to halt the
  agent before any turn runs. On error, `c:terminate_agent/2` is called
  with `{:pre_run_failed, reason}`.

  Crashes are wrapped: the agent halts with
  `{:pre_run_crashed, exception}` and `c:terminate_agent/2` is called
  with that reason.

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

  Use cases: prompt templating (inject context), rate limiting (sleep
  on a budget), gating (halt if an external signal says stop).

  When the prompt is rewritten, `[:gen_agent, :prompt, :start]`
  telemetry carries both the original and rewritten prompt plus a
  `rewritten: true` flag so the transformation is traceable.

  Crashes are caught: the turn is skipped, a warning is logged, and
  the agent returns to `:idle`. Users who want strict crash semantics
  can re-raise from inside a different callback.

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

  Crashes are caught: a warning is logged and the server continues
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
  `{:halt, state}`. Runs before the agent is marked halted and before
  the `[:gen_agent, :halted]` telemetry event is emitted.

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

      defoverridable handle_error: 3,
                     handle_event: 2,
                     handle_stream_event: 2,
                     terminate_agent: 2,
                     pre_run: 1,
                     pre_turn: 2,
                     post_turn: 3,
                     post_run: 1
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
  Start an agent under the GenAgent supervision tree.

  `module` is the implementation module (the one that `use GenAgent`).
  `opts` must include:

    * `:name` -- the name the agent will register under in `GenAgent.Registry`.
    * `:backend` -- the backend module implementing `GenAgent.Backend`.

  Event evidence is bounded by `:max_events_per_turn` (default `1_000`)
  and `:max_event_bytes_per_turn` (default `1_048_576`), measured as the
  sum of `:erlang.external_size/1` for each retained `GenAgent.Event`.
  Both limits must be positive integers. Reaching either limit before a
  terminal event fits fails the turn with
  `{:event_capture_overflow, diagnostics}`. No incomplete success response
  is returned. Accepted stream callbacks keep their state; the rejected
  event is not delivered to `c:handle_stream_event/2`.

  Pending prompt and deferred notification queues have independent count
  and payload-byte limits: `:max_pending_prompts` and
  `:max_pending_notifications` (both default `1_000`), and
  `:max_pending_prompt_bytes` and `:max_pending_notification_bytes`
  (both default `1_048_576`). Limits are non-negative integers; zero
  disables that pending queue. Bytes are the sum of
  `:erlang.external_size/1` of each queued prompt or notification payload,
  not the entire process memory. The active prompt and notifications
  handled immediately while idle are not pending. Self-chaining has one
  reserved slot outside the prompt count limit, but its payload must fit
  `:max_pending_prompt_bytes`.

  Any other option is forwarded to `c:init_agent/1`. GenAgent-level
  knobs (like `:watchdog_ms`) are recognized and stripped before
  forwarding.

  The child uses `restart: :temporary`. If it exits, call `start_agent/2`
  explicitly to create another agent; its previous state is not restored.
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

  Start the spec with `DynamicSupervisor.start_child/2`. The agent is
  registered in `GenAgent.Registry`, so the regular name-based APIs work.
  Names must be unique across both caller-owned and global agents. Use
  `stop/2` with the owning supervisor to stop an individual agent.

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
        :max_tell_results,
        :max_events_per_turn,
        :max_event_bytes_per_turn,
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
      |> maybe_put(:watchdog_ms, Keyword.get(server_opts, :watchdog_ms))
      |> maybe_put(:max_tell_results, Keyword.get(server_opts, :max_tell_results))
      |> maybe_put(:max_events_per_turn, Keyword.get(server_opts, :max_events_per_turn))
      |> maybe_put(:max_event_bytes_per_turn, Keyword.get(server_opts, :max_event_bytes_per_turn))
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

  Blocks until the turn completes and returns `{:ok, response}` or
  `{:error, reason}`. If the agent is currently processing another
  prompt, the caller is queued transparently and unblocks when its
  queued turn finishes.

  If admission to the pending prompt queue fails, returns
  `{:error, {:overloaded, info}}` immediately; no turn is accepted.
  `info` includes the queue, count or byte limit reached, current count
  and bytes, incoming bytes, and configured maxima.

  The default timeout is `:infinity`. The agent's own watchdog is the
  primary timeout mechanism -- callers generally should not need to set
  their own. Supplying a shorter timeout here will raise on expiry
  without affecting the agent.
  """
  @spec ask(name(), String.t(), timeout()) ::
          {:ok, Response.t()} | {:error, term()}
  def ask(name, prompt, timeout \\ @default_call_timeout) when is_binary(prompt) do
    :gen_statem.call(via(name), {:ask, prompt}, timeout)
  end

  @doc """
  Send an asynchronous prompt to an agent.

  Returns `{:ok, ref}` immediately. Use `poll/2` to check on the
  result. The same queueing semantics as `ask/2` apply. When a pending
  queue limit is reached, returns `{:error, {:overloaded, info}}` without
  an accepted ref.
  """
  @spec tell(name(), String.t(), timeout()) :: {:ok, request_ref()} | {:error, term()}
  def tell(name, prompt, timeout \\ @default_call_timeout) when is_binary(prompt) do
    :gen_statem.call(via(name), {:tell, prompt}, timeout)
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
  completes; `pre_turn/2` skip, halt and invalid results deliver their
  corresponding error without starting a turn. Successful and failed turns
  deliver after their decision and `post_turn/3` callbacks. An interrupt,
  watchdog timeout or backend failure delivers an error. A crashing
  `handle_response/3` callback stops the agent before completion; monitor
  the agent when its death matters to the caller.

  Delivery is a single BEAM message sent at most once per accepted request.
  It is independent of the bounded `poll/3` result cache. A dead recipient
  does not receive the message, and abrupt agent death can leave accepted
  requests without a completion message; a monitor reports that uncertainty.
  This does not prove that an external provider process has settled.
  The request ref remains suitable for `interrupt_request/3`, and a new
  agent under the same name never reuses it.
  """
  @spec tell_with_completion(name(), String.t(), pid(), timeout()) ::
          {:ok, request_ref()} | {:error, term()}
  def tell_with_completion(name, prompt, recipient \\ self(), timeout \\ @default_call_timeout)
      when is_binary(prompt) and is_pid(recipient) do
    :gen_statem.call(via(name), {:tell_with_completion, prompt, recipient}, timeout)
  end

  @doc """
  Check the status of a previously-issued `tell/2` request.

  Returns:

    * `{:ok, :pending}` if the request is queued or in-flight.
    * `{:ok, :completed, response}` if the turn finished successfully.
    * `{:error, reason}` if the turn failed.
    * `{:error, :not_found}` if the ref is unknown (never issued, or
      pruned from the bounded result cache).

  Only refs returned from `tell/2` are pollable. Refs from `ask/2` are
  internal and reply directly to the caller.
  """
  @spec poll(name(), request_ref(), timeout()) ::
          {:ok, :pending}
          | {:ok, :completed, Response.t()}
          | {:error, term()}
  def poll(name, ref, timeout \\ @default_call_timeout) when is_reference(ref) do
    :gen_statem.call(via(name), {:poll, ref}, timeout)
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
  """
  @spec notify_ack(name(), term(), timeout()) :: :ok | {:error, term()}
  def notify_ack(name, event, timeout \\ @default_call_timeout) do
    :gen_statem.call(via(name), {:notify_ack, event}, timeout)
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
  interruptible through this API. Unlike `interrupt/1`, this operation
  is acknowledged by the agent and cannot cancel a successor turn after
  the observed request finishes. It is also safe against a replacement
  agent registered under the same name, because request references are
  unique.

  The acknowledgement describes the agent's decision and BEAM task
  cancellation. It does not establish provider or OS process settlement.
  The default call timeout is `:infinity`.
  """
  @spec interrupt_request(name(), request_ref(), timeout()) ::
          {:ok, :accepted} | {:error, :not_current | :idle}
  def interrupt_request(name, ref, timeout \\ @default_call_timeout) when is_reference(ref) do
    :gen_statem.call(via(name), {:interrupt_request, ref}, timeout)
  end

  @doc """
  Resume a halted agent.

  Clears the `halted` flag and re-drains the mailbox. No-op if the
  agent is not halted.

  Asynchronous. Returns `:ok` immediately.
  """
  @spec resume(name()) :: :ok
  def resume(name) do
    :gen_statem.cast(via(name), :resume)
  end

  @doc """
  Read an agent's current status.

  This compatibility API includes the full callback-maintained
  `agent_state`. While a turn is processing, that value is the server's
  latest retained state, not a live read of state inside the prompt task.
  Use `runtime_snapshot/2` for a bounded metadata-only view.
  """
  @spec status(name(), timeout()) :: %{
          state: :idle | :processing,
          name: term(),
          queued: non_neg_integer(),
          current_request: request_ref() | nil,
          halted: boolean(),
          agent_state: term()
        }
  def status(name, timeout \\ @default_call_timeout) do
    :gen_statem.call(via(name), :status, timeout)
  end

  @typedoc "Bounded, metadata-only observation of one agent's runtime state."
  @type runtime_snapshot :: %{
          phase: :idle | :processing,
          halted: boolean(),
          pending_prompts: non_neg_integer(),
          pending_notifications: non_neg_integer(),
          self_chain_pending: boolean(),
          current_request:
            nil
            | %{
                ref: request_ref(),
                origin: :ask | :tell | :event | :self_chain,
                elapsed_ms: non_neg_integer(),
                watchdog_ms: non_neg_integer() | :infinity
              }
        }

  @doc """
  Read a bounded, metadata-only runtime snapshot of an agent.

  `pending_prompts` counts the prompt mailbox; `pending_notifications`
  counts notifications buffered during a turn; `self_chain_pending`
  reports a separately held callback-generated follow-up prompt.
  `current_request` is `nil` when idle and otherwise contains the
  volatile request ref, its origin (`:event` and `:self_chain` are
  callback-origin turns), elapsed monotonic milliseconds since dispatch,
  and the configured watchdog duration. It excludes prompts, caller
  identities, callback state, backend sessions, events, and queued
  payloads. Elapsed time is an observation, not an exact countdown to
  the watchdog firing.

  The snapshot is a point-in-time view of this BEAM coordinator, not
  durable application state, admission authority, or proof that external
  provider work has settled. The default call timeout is `:infinity`.
  """
  @spec runtime_snapshot(name(), timeout()) :: runtime_snapshot()
  def runtime_snapshot(name, timeout \\ @default_call_timeout) do
    :gen_statem.call(via(name), :runtime_snapshot, timeout)
  end

  @doc """
  Stop an agent.

  Terminates the agent process cleanly via its owning `DynamicSupervisor`.
  Pass the supervisor as the second argument for an agent started with
  `child_spec/2`; the default is `GenAgent.AgentSupervisor`.
  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec stop(name(), GenServer.server()) :: :ok | {:error, :not_found}
  def stop(name, supervisor \\ GenAgent.AgentSupervisor) do
    case whereis(name) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(supervisor, pid)
    end
  end

  @doc """
  Look up the pid of a registered agent, or `nil` if not found.
  """
  @spec whereis(name()) :: pid() | nil
  def whereis(name) do
    case Registry.lookup(GenAgent.Registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(name), do: {:via, Registry, {GenAgent.Registry, name}}

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)
end
