defmodule GenAgentEnsemble.ConfiguredLifecycleTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.Server

  defmodule Backend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts), do: {:ok, opts}

    @impl true
    def prompt(session, _prompt), do: {:ok, [], session}

    @impl true
    def terminate_session(_session), do: :ok
  end

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, opts, opts}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  defmodule Strategy do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(opts), do: {:ok, nil, Keyword.fetch!(opts, :agents)}

    @impl true
    def handle_tell(_prompt, _opts, _token, state), do: {:ok, [{:halt, :done}], state}

    @impl true
    def handle_ask(_prompt, _opts, _token, state), do: {:ok, [], state}

    @impl true
    def handle_response(_agent, _response, state), do: {:ok, [], state}
  end

  setup do
    original_env = Application.fetch_env(:gen_agent_ensemble, :ensembles)
    prefix = "configured-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.stop(:gen_agent_ensemble)

      case original_env do
        {:ok, value} -> Application.put_env(:gen_agent_ensemble, :ensembles, value)
        :error -> Application.delete_env(:gen_agent_ensemble, :ensembles)
      end

      {:ok, _} = Application.ensure_all_started(:gen_agent_ensemble)
    end)

    %{prefix: prefix}
  end

  defp config(name) do
    [
      name: name,
      strategy: Strategy,
      opts: [agents: [{"worker", Agent, [backend: Backend]}]]
    ]
  end

  defp boot(names) do
    :ok = Application.stop(:gen_agent_ensemble)
    Application.put_env(:gen_agent_ensemble, :ensembles, Enum.map(names, &config/1))
    {:ok, _} = Application.ensure_all_started(:gen_agent_ensemble)
  end

  defp lookup(name) do
    case Registry.lookup(GenAgentEnsemble.Registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Registry removes dead owners asynchronously, after their monitor fires.
  defp await_gone(name, attempts \\ 100) do
    cond do
      lookup(name) == nil and GenAgent.whereis("#{name}/worker") == nil ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        await_gone(name, attempts - 1)

      true ->
        flunk("#{name} was not cleaned up")
    end
  end

  defp await_restart(name, old_pid, attempts \\ 200) do
    case lookup(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        await_restart(name, old_pid, attempts - 1)

      _ ->
        flunk("#{name} was not restarted")
    end
  end

  test "manual Server child spec keeps its permanent restart policy" do
    assert Map.get(Server.child_spec(name: "x"), :restart, :permanent) == :permanent
  end

  test "repeated explicit stops stay stopped and do not exhaust the supervisor", %{prefix: prefix} do
    stopped = for i <- 1..5, do: "#{prefix}-stop-#{i}"
    keep = "#{prefix}-keep"
    boot(stopped ++ [keep])

    supervisor = Process.whereis(GenAgentEnsemble.Supervisor)
    keep_pid = lookup(keep)
    assert is_pid(keep_pid)

    for name <- stopped do
      assert :ok = Ensemble.stop(name)
      await_gone(name)
    end

    # Ordered call: any restart would have been issued by now.
    assert %{active: 1} = DynamicSupervisor.count_children(GenAgentEnsemble.Supervisor)
    assert Process.whereis(GenAgentEnsemble.Supervisor) == supervisor
    assert lookup(keep) == keep_pid
    assert {:ok, _} = Ensemble.status(keep)
    for name <- stopped, do: assert(lookup(name) == nil)
  end

  test "strategy halt stays stopped", %{prefix: prefix} do
    halted = for i <- 1..4, do: "#{prefix}-halt-#{i}"
    keep = "#{prefix}-keep"
    boot(halted ++ [keep])

    supervisor = Process.whereis(GenAgentEnsemble.Supervisor)
    keep_pid = lookup(keep)

    for name <- halted do
      pid = lookup(name)
      ref = Process.monitor(pid)
      {:ok, _token} = Ensemble.tell(name, "go")
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
      await_gone(name)
    end

    assert %{active: 1} = DynamicSupervisor.count_children(GenAgentEnsemble.Supervisor)
    assert Process.whereis(GenAgentEnsemble.Supervisor) == supervisor
    assert lookup(keep) == keep_pid
  end

  test "abnormal exit of a configured session is still restarted", %{prefix: prefix} do
    name = "#{prefix}-crash"
    boot([name])

    old = lookup(name)
    old_agent = GenAgent.whereis("#{name}/worker")
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}, 2_000

    new = await_restart(name, old)
    assert Process.alive?(new)
    assert {:ok, _} = Ensemble.status(name)
    assert GenAgent.whereis("#{name}/worker") != old_agent
  end
end
