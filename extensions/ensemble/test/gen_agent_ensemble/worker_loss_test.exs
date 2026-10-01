defmodule GenAgentEnsemble.WorkerLossTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.Supervisor

  setup do
    name = "worker-loss-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case Registry.lookup(GenAgentEnsemble.Registry, name) do
        [{server, _}] -> if Process.alive?(server), do: Ensemble.stop(name)
        [] -> :ok
      end
    end)

    {:ok, name: name}
  end

  defp start_supervisor(name) do
    coordinator =
      {"coordinator", ControlledAgent,
       [backend: ControlledBackend, observer: self(), tag: "coordinator"]}

    worker =
      {"worker", ControlledAgent, [backend: ControlledBackend, observer: self(), tag: "worker"]}

    Ensemble.start_link(
      name: name,
      strategy: Supervisor,
      opts: [
        coordinator: coordinator,
        worker_template: worker,
        decomposer: &String.split(&1, "\n", trim: true)
      ]
    )
  end

  defp await_poll(name, token, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    case Ensemble.poll(name, token) do
      {:ok, :pending} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_poll(name, token, deadline)
        else
          flunk("token #{token} did not complete")
        end

      other ->
        other
    end
  end

  defp await_phase(name, phase, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    {:ok, status} = Ensemble.status(name)

    if status.phase == phase do
      status
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        await_phase(name, phase, deadline)
      else
        flunk("session did not reach #{inspect(phase)}; got #{inspect(status.phase)}")
      end
    end
  end

  test "worker death fails the current and queued tokens once, then permits fresh work", %{
    name: name
  } do
    {:ok, server} = start_supervisor(name)
    {:ok, first} = Ensemble.tell(name, "first")
    assert_receive {:controlled_prompt, "coordinator", "first", coordinator1}, 2_000
    {:ok, second} = Ensemble.tell(name, "second")
    {:ok, third} = Ensemble.tell(name, "third")

    send(coordinator1, {:result, "one\ntwo"})
    assert_receive {:controlled_prompt, "worker", "one", _worker1_task}, 2_000
    assert_receive {:controlled_prompt, "worker", "two", worker2_task}, 2_000

    {late_ref, _} =
      Enum.find(:sys.get_state(server).in_flight, fn {_ref, {agent, _token}} ->
        agent == "worker-2"
      end)

    [{worker1, _}] = Registry.lookup(GenAgent.Registry, "#{name}/worker-1")
    Process.exit(worker1, :kill)

    failure = {:worker_down, "worker-1", :killed}
    assert {:error, ^failure} = await_poll(name, first)
    assert {:error, ^failure} = await_poll(name, second)
    assert {:error, ^failure} = await_poll(name, third)
    assert {:error, :not_found} = Ensemble.poll(name, first)
    assert {:error, :not_found} = Ensemble.poll(name, second)
    assert {:error, :not_found} = Ensemble.poll(name, third)

    # Any sibling result already in flight, or delivered after the stop, is
    # fenced out before it can replay queued work or replace the errors.
    send(worker2_task, {:result, "LATE"})
    send(server, {:gen_agent_stop, "#{name}/worker-2", late_ref})
    assert {:ok, status} = Ensemble.status(name)
    assert status.phase == :idle
    assert status.queued == 0
    assert status.in_flight == 0
    assert status.agents == ["coordinator"]
    refute_received {:controlled_prompt, "coordinator", "second", _}
    refute_received {:controlled_prompt, "coordinator", "third", _}

    {:ok, fresh} = Ensemble.tell(name, "fresh")
    assert_receive {:controlled_prompt, "coordinator", "fresh", coordinator2}, 2_000
    send(coordinator2, {:result, "new"})
    assert_receive {:controlled_prompt, "worker", "new", fresh_worker}, 2_000
    send(fresh_worker, {:result, "FRESH_RESULT"})
    assert {:ok, :completed, response} = await_poll(name, fresh)
    assert response.text == "FRESH_RESULT"
  end

  test "a completed sibling does not conceal a later worker death", %{name: name} do
    {:ok, _server} = start_supervisor(name)
    {:ok, token} = Ensemble.tell(name, "first")
    assert_receive {:controlled_prompt, "coordinator", "first", coordinator}, 2_000
    send(coordinator, {:result, "one\ntwo"})
    assert_receive {:controlled_prompt, "worker", "one", _worker1_task}, 2_000
    assert_receive {:controlled_prompt, "worker", "two", worker2_task}, 2_000

    send(worker2_task, {:result, "FINISHED"})
    assert %{phase: {:fanning_out, 1, 2}} = await_phase(name, {:fanning_out, 1, 2})

    [{worker1, _}] = Registry.lookup(GenAgent.Registry, "#{name}/worker-1")
    Process.exit(worker1, :kill)

    assert {:error, {:worker_down, "worker-1", :killed}} = await_poll(name, token)
    assert {:error, :not_found} = Ensemble.poll(name, token)
    assert {:ok, %{phase: :idle, agents: ["coordinator"]}} = Ensemble.status(name)
  end
end
