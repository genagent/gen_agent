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
          {:gen_agent, "~> 0.1.0"},
          # Plus at least one backend:
          {:gen_agent_claude, "~> 0.1.0"},
          {:gen_agent_codex, "~> 0.1.0"}
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

  Halting: any callback can return `{:halt, state}` to go idle but freeze
  the mailbox. A halted agent ignores queued prompts until `resume/1` is
  called.

  ## Backends

  Backends implement `GenAgent.Backend` and translate the LLM-specific wire
  protocol into the normalized `GenAgent.Event` stream the state machine
  consumes. Available backends (in sibling packages):

    * `GenAgent.Backends.Claude` (package: `gen_agent_claude`) --
      wraps the Anthropic `claude` CLI via `ClaudeWrapper`.
    * `GenAgent.Backends.Codex` (package: `gen_agent_codex`) --
      wraps the OpenAI `codex` CLI via `CodexWrapper`.

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
    * `c:post_run/1` -- on clean `{:halt, state}` from any callback. For completion side effects.

  The `use GenAgent` macro provides default implementations of the optional
  callbacks and lifecycle hooks.

  ## Public API

    * `start_agent/2` -- start an agent under the supervision tree.
    * `ask/3` -- synchronous prompt, blocks until the turn finishes.
    * `tell/3` -- async prompt, returns a ref for `poll/3`.
    * `poll/3` -- check on a previously-issued `tell/3`.
    * `notify/2` -- push an external event into `c:handle_event/2`.
    * `interrupt/1` -- cancel an in-flight turn.
    * `resume/1` -- unhalt an agent and drain its mailbox.
    * `status/2` -- read the agent's current state.
    * `stop/1` -- terminate the agent.
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
  stream events and then into `c:handle_response/3`.
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

  Fires when any callback (`c:handle_response/3`, `c:handle_error/3`,
  `c:handle_event/2`, `c:pre_turn/2`, `c:post_turn/3`) returns
  `{:halt, state}`. Runs before the agent is marked halted and before
  the `[:gen_agent, :halted]` telemetry event is emitted.

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

  Any other option is forwarded to `c:init_agent/1`. GenAgent-level
  knobs (like `:watchdog_ms`) are recognized and stripped before
  forwarding.
  """
  @spec start_agent(module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(module, opts) when is_atom(module) and is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    backend = Keyword.fetch!(opts, :backend)

    {server_opts, init_opts} =
      Keyword.split(opts, [:name, :backend, :watchdog_ms, :max_tell_results])

    child_opts =
      [
        name: name,
        backend: backend,
        module: module,
        task_supervisor: GenAgent.TaskSupervisor,
        init_opts: init_opts,
        register: via(name)
      ]
      |> maybe_put(:watchdog_ms, Keyword.get(server_opts, :watchdog_ms))
      |> maybe_put(:max_tell_results, Keyword.get(server_opts, :max_tell_results))

    DynamicSupervisor.start_child(GenAgent.AgentSupervisor, {GenAgent.Server, child_opts})
  end

  @doc """
  Send a synchronous prompt to an agent.

  Blocks until the turn completes and returns `{:ok, response}` or
  `{:error, reason}`. If the agent is currently processing another
  prompt, the caller is queued transparently and unblocks when its
  queued turn finishes.

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
  result. The same queueing semantics as `ask/2` apply.
  """
  @spec tell(name(), String.t(), timeout()) :: {:ok, request_ref()}
  def tell(name, prompt, timeout \\ @default_call_timeout) when is_binary(prompt) do
    :gen_statem.call(via(name), {:tell, prompt}, timeout)
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

  Asynchronous. Returns `:ok` immediately.
  """
  @spec notify(name(), term()) :: :ok
  def notify(name, event) do
    :gen_statem.cast(via(name), {:notify, event})
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

  @doc """
  Stop an agent.

  Terminates the agent process cleanly via its DynamicSupervisor.
  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec stop(name()) :: :ok | {:error, :not_found}
  def stop(name) do
    case whereis(name) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(GenAgent.AgentSupervisor, pid)
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
