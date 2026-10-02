import ExUnit.Assertions

defmodule RequestsAgent do
  use GenAgent

  @impl true
  def init_agent(opts), do: {:ok, opts, nil}

  @impl true
  def handle_response(_ref, _response, state), do: {:noreply, state}
end

{:ok, _pid} =
  GenAgent.start_agent(RequestsAgent,
    name: :requests,
    backend: Primitives.ScriptedBackend,
    max_pending_prompts: 1,
    script: %{"active" => {:gate, self()}, "failure" => {:error, :scripted_failure}}
  )

# The recipient can receive completion before the submitting process sends its ref.
# Selective receive safely correlates both messages in either arrival order.
owner = self()

recipient =
  spawn_link(fn ->
    receive do
      {:expect, ref} ->
        receive do
          {:gen_agent, :completion, :requests, ^ref, outcome} ->
            send(owner, {:delivered, ref, outcome})
        after
          5_000 -> raise "completion not delivered"
        end
    after
      5_000 -> raise "request ref not delivered"
    end
  end)

IO.puts("tell_with_completion delivers to a separate process, correlated by request ref.")
{:ok, active} = GenAgent.tell_with_completion(:requests, "active", recipient, 5_000)
send(recipient, {:expect, active})
assert_receive {:scripted_turn, "active", _task, _token}, 5_000
{:ok, queued} = GenAgent.tell(:requests, "queued")
assert {:error, :not_current} = GenAgent.interrupt_request(:requests, queued, 5_000)

assert {:error, {:overloaded, %{limit: :count, pending_count: 1, max_count: 1}}} =
         GenAgent.tell(:requests, "too many")

assert %{
         phase: :processing,
         pending_prompts: 1,
         pending_notifications: 0,
         current_request: %{ref: ^active, origin: :tell, elapsed_ms: elapsed}
       } = GenAgent.runtime_snapshot(:requests, 5_000)

assert elapsed >= 0

IO.puts("A queued ref cannot interrupt the active turn; cancellation frees its queue slot.")
assert {:ok, :cancelled} = GenAgent.cancel_request(:requests, queued, 5_000)
assert {:error, :cancelled} = GenAgent.poll(:requests, queued, 5_000)
assert %{pending_prompts: 0} = GenAgent.runtime_snapshot(:requests, 5_000)
assert {:ok, :accepted} = GenAgent.interrupt_request(:requests, active, 5_000)
assert_receive {:delivered, ^active, {:error, :interrupted}}, 5_000
assert {:error, :interrupted} = GenAgent.poll(:requests, active, 5_000)
assert {:error, :idle} = GenAgent.interrupt_request(:requests, active, 5_000)
assert {:error, :scripted_failure} = GenAgent.ask(:requests, "failure")
assert :ok = GenAgent.stop(:requests)

IO.puts(
  "The watchdog times out a slow turn; poll recovers the outcome independently of delivery."
)

{:ok, _pid} =
  GenAgent.start_agent(RequestsAgent,
    name: :watchdog,
    backend: Primitives.ScriptedBackend,
    watchdog_ms: 100,
    script: %{"slow" => {:slow, 60_000}}
  )

{:ok, slow} = GenAgent.tell_with_completion(:watchdog, "slow", self(), 5_000)
assert_receive {:gen_agent, :completion, :watchdog, ^slow, {:error, :timeout}}, 5_000
assert {:error, :timeout} = GenAgent.poll(:watchdog, slow, 5_000)
assert %{phase: :idle, current_request: nil} = GenAgent.runtime_snapshot(:watchdog, 5_000)
assert :ok = GenAgent.stop(:watchdog)
IO.puts("02_requests: ok")
