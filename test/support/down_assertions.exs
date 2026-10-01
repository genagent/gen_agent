defmodule GenAgent.TestDownAssertions do
  @moduledoc false

  import ExUnit.Assertions

  def assert_killed_or_gone(monitor, pid, timeout \\ 100) do
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, timeout

    # A monitor registered while another process kills the target can report
    # :noproc even though the target exited because it was killed.
    assert reason in [:killed, :noproc]
  end
end
