defmodule GenAgentEnsemble.HaltSupport do
  @moduledoc false
  # Shared assertions for the halted-façade contract: the session process and
  # name survive a halt while its owned tree is shut down.
  import ExUnit.Assertions

  alias GenAgentEnsemble, as: E

  @doc "Monitor the processes the session owns, before the halt is triggered."
  def watch(server) do
    state = :sys.get_state(server)

    owned =
      for pid <- [state.agent_tree, state.agent_supervisor, state.task_supervisor],
          do: {pid, Process.monitor(pid)}

    %{server: server, owned: owned, server_ref: Process.monitor(server)}
  end

  @doc "Wait until every watched owned process is gone while the session lives."
  def assert_tree_gone(%{server: server, owned: owned, server_ref: server_ref}) do
    for {pid, ref} <- owned do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end

    refute_received {:DOWN, ^server_ref, :process, ^server, _}
    assert Process.alive?(server)
  end

  @doc "The session is a live, terminal façade with the given halt reason."
  def assert_halted(name, reason) do
    assert assert_halted(name) == reason
  end

  @doc "Like `assert_halted/2` for reasons that are matched, not compared. Returns the reason."
  def assert_halted(name) do
    assert {:ok, %{lifecycle: :halted} = status} = E.status(name)
    assert status.agents == []
    assert status.pending_tokens == []
    assert status.in_flight == 0
    assert {:error, {:halted, reason}} = E.ask(name, "after", timeout: 1_000)
    assert E.tell(name, "after") == {:error, {:halted, reason}}
    reason
  end
end
