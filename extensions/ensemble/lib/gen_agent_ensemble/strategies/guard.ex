defmodule GenAgentEnsemble.Strategies.Guard do
  @moduledoc false

  # Contains failures of user-supplied functions that a built-in strategy
  # invokes (verdict parsers, deciders, synthesizers). Only the function call
  # is guarded -- never the strategy's own state transitions. Failures are
  # reduced to redacted, typed reasons: the exception message, stacktrace,
  # arguments and returned value may carry prompts, responses or secrets and
  # are never included.

  @type label :: atom()
  @type failure ::
          {:strategy_function_failed, label(), :error | :throw | :exit, module() | :other}
          | {:invalid_strategy_result, label()}

  @doc """
  Applies `fun` to `args`.

  Returns `{:ok, value}` when the call returns and `valid?.(value)` is true,
  `{:error, {:invalid_strategy_result, label}}` when it returns anything else,
  and `{:error, {:strategy_function_failed, label, kind, class}}` when it
  raises, throws or exits. `class` is the exception module, or `:other`.

  Only the invocation of `fun` is protected. `fun` having the arity of `args`
  is a precondition of the strategy's own state, and `valid?` is the
  strategy's own total check; a violation of either raises to the caller
  instead of being reported as a user-function failure.
  """
  @spec call(label(), function(), [term()], (term() -> boolean())) ::
          {:ok, term()} | {:error, failure()}
  def call(label, fun, args, valid? \\ fn _ -> true end)
      when is_function(fun, length(args)) do
    with {:ok, value} <- invoke(label, fun, args) do
      if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_strategy_result, label}}
    end
  end

  defp invoke(label, fun, args) do
    {:ok, apply(fun, args)}
  catch
    kind, reason -> {:error, {:strategy_function_failed, label, kind, class(kind, reason)}}
  end

  defp class(:error, reason) do
    case Exception.normalize(:error, reason) do
      %{__struct__: module} -> module
      _ -> :other
    end
  end

  defp class(_kind, _reason), do: :other
end
