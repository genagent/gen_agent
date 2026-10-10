defmodule GenAgentEnsemble.Strategies.Failure do
  @moduledoc """
  Opt-in reason for handled terminal runtime failures in Debate, Consensus
  and Supervisor. `reason` is the original legacy reason, including Guard
  redaction. `partial` contains completed text only, never failed turn output.

  Agent death, halt, cancellation, timeouts, initialization and custom strategy
  failures are outside this contract. Enable with `failure_reply: :structured`;
  the default `:legacy` preserves existing error reasons.
  """

  defstruct [:strategy, :phase, :agent, :reason, partial: []]

  @type entry :: %{
          agent: term(),
          phase: :turn | :coordinator | :worker,
          index: non_neg_integer(),
          text: binary()
        }
  @type t :: %__MODULE__{
          strategy: module(),
          phase: atom(),
          agent: term(),
          reason: term(),
          partial: [entry()]
        }

  @doc false
  def option!(opts) do
    value = Keyword.get(opts, :failure_reply, :legacy)

    unless value in [:legacy, :structured] do
      raise ArgumentError, ":failure_reply must be :legacy or :structured"
    end

    value
  end

  @doc false
  def wrap(:legacy, _strategy, _phase, _agent, reason, _partial), do: reason

  def wrap(:structured, strategy, phase, agent, reason, partial) do
    %__MODULE__{strategy: strategy, phase: phase, agent: agent, reason: reason, partial: partial}
  end

  @doc false
  def record(%{failure_reply: :legacy} = state, _agent, _phase, _index, _text), do: state

  def record(state, agent, phase, index, text) do
    entry = %{agent: agent, phase: phase, index: index, text: text}
    %{state | partial: state.partial ++ [entry]}
  end
end
