defmodule GenAgent.TestPollingAssertions do
  @moduledoc false

  import ExUnit.Assertions

  @default_timeout 1_000
  @default_interval 10

  @doc """
  Polls `fun` until it returns a truthy value or the deadline passes.

  `fun` is always evaluated once more at the deadline before failing, so the
  final state is what decides the outcome. Options: `:timeout` (ms, default
  #{@default_timeout}), `:interval` (ms between attempts, default
  #{@default_interval}), and `:message` (label included in the failure).
  """
  def wait_until(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, @default_interval)
    message = Keyword.get(opts, :message, "condition")
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait(fun, deadline, interval, timeout, message, 1)
  end

  defp do_wait(fun, deadline, interval, timeout, message, attempts) do
    result = fun.()

    cond do
      result ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "#{message} did not become truthy within #{timeout}ms " <>
            "(#{attempts} attempts, last result: #{inspect(result)})"
        )

      true ->
        Process.sleep(interval)
        do_wait(fun, deadline, interval, timeout, message, attempts + 1)
    end
  end
end
