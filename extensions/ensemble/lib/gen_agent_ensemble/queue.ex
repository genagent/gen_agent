defmodule GenAgentEnsemble.Queue do
  @moduledoc """
  FIFO helper for `{token, prompt}` pairs awaiting dispatch.

  Thin wrapper over `:queue` with the shape every queueing strategy
  reaches for: enqueue when busy, pop when going idle.

  Strategies using this helper typically keep a `queue: Queue.new()`
  field and call `enqueue/3` in `handle_tell/ask` when they can't
  dispatch immediately, then `pop/1` in `handle_response` (or similar)
  when they free up.
  """

  @opaque t :: :queue.queue({String.t(), String.t()})

  @spec new() :: t
  def new, do: :queue.new()

  @spec enqueue(t, String.t(), String.t()) :: t
  def enqueue(queue, token, prompt), do: :queue.in({token, prompt}, queue)

  @spec len(t) :: non_neg_integer()
  def len(queue), do: :queue.len(queue)

  @doc """
  Pop the next `{token, prompt}` pair.

  Returns `{:ok, {token, prompt}, rest}` if the queue was non-empty,
  `:empty` if it was empty.
  """
  @spec pop(t) :: {:ok, {String.t(), String.t()}, t} | :empty
  def pop(queue) do
    case :queue.out(queue) do
      {{:value, pair}, rest} -> {:ok, pair, rest}
      {:empty, _} -> :empty
    end
  end
end
