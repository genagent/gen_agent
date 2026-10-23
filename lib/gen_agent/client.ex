defmodule GenAgent.Client do
  @moduledoc """
  Correlated submission and exact-request controls for a captured local agent PID.

  `submit_with_completion/4` creates a request ref and sends once without
  waiting for the agent's callbacks or admission decision. `{:submitted, ref}`
  means sent, not accepted, queued or started. It also returns for a dead PID.
  There is no Registry lookup, liveness handshake, automatic retry or retargeting
  to a replacement. Existing `GenAgent` APIs still interpret targets as names,
  including PID-valued Registry names.

  Monitor the captured PID **before** submitting when death matters. Admission,
  events and completion come directly from the agent. Consume these and `:DOWN`
  in mailbox order: a terminal completion remains known even if admission never
  arrives. An admission `:ok` followed by death leaves the outcome uncertain;
  death alone leaves acceptance uncertain. No completion is invented on stop.
  A monitor does not prove that external provider work has settled.

  This API adds no worker, monitor, timer or outstanding-submission registry.
  Pending queue limits do not bound casts waiting in the BEAM mailbox. Callers
  should bound unresolved submissions and retain each capacity permit until
  rejection, terminal completion, confirmed cancellation or `:DOWN`. A logical
  timeout or abandoned user request does not confirm cancellation or justify
  repeatedly replacing unresolved work. Do not retry a missing admission with
  a fresh submission; each invocation sends new work with a new ref.

  PID controls are synchronous and retain native `:gen_statem.call/3` timeout
  and death exits. They cannot respond while an agent callback blocks. A
  callback may dispatch backend work before processing cancellation, even if
  cancellation was requested before admission arrived. Run blocking cleanup
  outside any coordinator that must remain responsive; a cleanup deadline can
  report uncertainty, but cannot prove that work stopped.
  """

  alias GenAgent.{Event, Response}

  @typedoc "Admission decision for a submitted request, independent of its terminal outcome."
  @type admission :: :ok | {:error, GenAgent.error_reason()}

  @type admission_message ::
          {:gen_agent, :admission, GenAgent.name(), GenAgent.request_ref(), admission()}

  @type completion_message ::
          {:gen_agent, :completion, GenAgent.name(), GenAgent.request_ref(),
           {:ok, Response.t()} | {:error, GenAgent.error_reason()}}

  @type event_message ::
          {:gen_agent, :event, GenAgent.name(), GenAgent.request_ref(), Event.t()}

  @type submit_option :: {:on_halt, :queue | :fail} | {:stream_to, pid() | nil}

  @doc """
  Send one prompt to a local PID and return `{:submitted, ref}` without waiting
  for admission. Validates the PID, binary prompt, PID recipient and options
  before minting the ref and issuing a single asynchronous cast.

  On processing, the agent sends the recipient
  `{:gen_agent, :admission, name, ref, :ok | {:error, reason}}` at most once,
  provided the handler reaches that send. Admission rejection (`:draining`,
  `:halted` or overload) sends no completion and retains no request. An idle
  `pre_turn/2` skip, halt, invalid return, crash or task dispatch failure is
  accepted work: its error completion can arrive **before** admission `:ok`.
  That completion proves acceptance; a later admission must not reopen it.

  Normal admission precedes events and backend completion for the same
  recipient. Scheduling may let the agent enter or finish a callback before
  this function returns; the guarantee is that submission does not wait for it.

  Options match `GenAgent.tell_with_completion/5`: `on_halt: :queue` (default)
  or `:fail`, and `stream_to: nil` (default) or a PID. Completion, optional
  stream events, retries, poll cache and cancellation all use this same ref.
  Retries produce one final completion and no additional admission. Stream
  events remain best effort without backpressure; events to a separate
  recipient have no shared arrival ordering with completion.
  """
  @spec submit_with_completion(pid(), String.t(), pid(), [submit_option()]) ::
          {:submitted, GenAgent.request_ref()}
  def submit_with_completion(pid, prompt, recipient \\ self(), opts \\ []) do
    validate_target!(pid)
    unless is_binary(prompt), do: raise(ArgumentError, "expected a binary prompt")
    unless is_pid(recipient), do: raise(ArgumentError, "expected a pid recipient")

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:on_halt, :stream_to] == [] do
      raise ArgumentError, "expected keyword options :on_halt and :stream_to"
    end

    on_halt = Keyword.get(opts, :on_halt, :queue)
    stream_to = Keyword.get(opts, :stream_to)

    if on_halt not in [:queue, :fail] do
      raise ArgumentError, "expected :on_halt to be :queue or :fail"
    end

    unless is_nil(stream_to) or is_pid(stream_to) do
      raise ArgumentError, "expected :stream_to to be nil or a pid"
    end

    ref = make_ref()
    :gen_statem.cast(pid, {:submit_with_completion, ref, prompt, recipient, on_halt, stream_to})
    {:submitted, ref}
  end

  @doc """
  Poll the captured PID using `GenAgent.poll/3` result semantics.

  Defaults to 5 seconds. `:not_found` can mean not yet processed, rejected,
  unknown or evicted; it is not proof of cancellation. Native timeout/death
  exits propagate, and a held callback delays this call.
  """
  @spec poll(pid(), GenAgent.request_ref(), timeout()) ::
          {:ok, :pending} | {:ok, :completed, Response.t()} | {:error, GenAgent.error_reason()}
  def poll(pid, ref, timeout \\ 5_000), do: call(pid, ref, :poll, timeout)

  @doc """
  Cancel a queued request on the captured PID by exact ref.

  Uses `GenAgent.cancel_request/3` semantics and a 5 second default timeout.
  If it returns `{:error, :current}`, use `interrupt_request/3` for that ref.
  Native timeout/death exits propagate; a timeout leaves cancellation uncertain.
  This call cannot confirm cancellation while a callback blocks.
  """
  @spec cancel_request(pid(), GenAgent.request_ref(), timeout()) ::
          {:ok, :cancelled} | {:error, :current | :already_finished | :not_found}
  def cancel_request(pid, ref, timeout \\ 5_000), do: call(pid, ref, :cancel_request, timeout)

  @doc """
  Interrupt only the matching active request on the captured PID.

  Uses `GenAgent.interrupt_request/3` semantics and a 5 second default timeout.
  Native timeout/death exits propagate. Callback blocking delays this call;
  acknowledgement confirms BEAM task cancellation, not provider settlement.
  """
  @spec interrupt_request(pid(), GenAgent.request_ref(), timeout()) ::
          {:ok, :accepted} | {:error, :not_current | :idle}
  def interrupt_request(pid, ref, timeout \\ 5_000),
    do: call(pid, ref, :interrupt_request, timeout)

  defp call(pid, ref, operation, timeout) do
    validate_target!(pid)
    unless is_reference(ref), do: raise(ArgumentError, "expected a request reference")
    :gen_statem.call(pid, {operation, ref}, timeout)
  end

  defp validate_target!(pid) do
    unless is_pid(pid) and node(pid) == node() do
      raise ArgumentError, "expected a local agent pid"
    end
  end
end
