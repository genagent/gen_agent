import ExUnit.Assertions

defmodule EventsAgent do
  use GenAgent

  @impl true
  def init_agent(opts) do
    {:ok, Keyword.take(opts, [:script]), %{owner: Keyword.fetch!(opts, :owner), history: []}}
  end

  @impl true
  def handle_response(ref, response, state) do
    send(state.owner, {:response, ref, response.text})
    {:noreply, record(state, {:response, response.text})}
  end

  @impl true
  def handle_event({:record, value}, state), do: {:noreply, record(state, value)}
  def handle_event({:prompt, text}, state), do: {:prompt, text, record(state, :prompt)}
  def handle_event(:halt, state), do: {:halt, record(state, :halt)}

  defp record(state, value), do: %{state | history: state.history ++ [value]}
end

{:ok, _pid} =
  GenAgent.start_agent(EventsAgent,
    name: :events,
    backend: Primitives.ScriptedBackend,
    owner: self(),
    max_pending_notifications: 2,
    script: %{"busy" => {:gate, self()}}
  )

IO.puts("notify is asynchronous; notify_ack acknowledges in-memory admission.")
assert :ok = GenAgent.notify(:events, {:record, :initial})
assert :ok = GenAgent.notify_ack(:events, {:prompt, "from event"}, 5_000)
assert_receive {:response, _, "from event"}, 5_000

assert %{agent_state: %{history: [:initial, :prompt, {:response, "from event"}]}} =
         GenAgent.status(:events, 5_000)

{:ok, busy} = GenAgent.tell(:events, "busy")
assert_receive {:scripted_turn, "busy", task, token}, 5_000
assert :ok = GenAgent.notify(:events, {:record, :first})
assert :ok = GenAgent.notify_ack(:events, {:record, :second}, 5_000)

assert {:error, {:overloaded, %{limit: :count, pending_count: 2, max_count: 2}}} =
         GenAgent.notify_ack(:events, {:record, :rejected}, 5_000)

# A cast still returns :ok when full. The subsequent status call is a barrier.
assert :ok = GenAgent.notify(:events, {:record, :dropped})

assert %{state: :processing, agent_state: %{history: before_turn}} =
         GenAgent.status(:events, 5_000)

assert before_turn == [:initial, :prompt, {:response, "from event"}]
assert %{pending_notifications: 2} = GenAgent.runtime_snapshot(:events, 5_000)
send(task, {:release, token})
assert_receive {:response, ^busy, "busy"}, 5_000
assert {:ok, :completed, _response} = GenAgent.poll(:events, busy, 5_000)
assert %{agent_state: %{history: history}} = GenAgent.status(:events, 5_000)
assert history == before_turn ++ [{:response, "busy"}, :first, :second]
IO.puts("Deferred events ran after the response in FIFO order; rejected events were not applied.")

assert :ok = GenAgent.notify_ack(:events, :halt, 5_000)
{:ok, retained} = GenAgent.tell(:events, "after resume")

assert %{state: :idle, halted: true, queued: 1, agent_state: %{history: halted_history}} =
         GenAgent.status(:events, 5_000)

assert halted_history == history ++ [:halt]
assert {:ok, :pending} = GenAgent.poll(:events, retained, 5_000)
assert :ok = GenAgent.resume(:events)
assert_receive {:response, ^retained, "after resume"}, 5_000

assert {:ok, :completed, %GenAgent.Response{text: "after resume"}} =
         GenAgent.poll(:events, retained, 5_000)

assert %{halted: false, queued: 0} = GenAgent.status(:events, 5_000)
IO.puts("A halted agent retained its prompt until resume.")
assert :ok = GenAgent.stop(:events)
IO.puts("03_events: ok")
