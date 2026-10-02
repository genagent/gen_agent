import ExUnit.Assertions

defmodule StreamAgent do
  use GenAgent

  @impl true
  def init_agent(opts) do
    {:ok, Keyword.take(opts, [:script]), %{sink: Keyword.fetch!(opts, :sink)}}
  end

  @impl true
  def handle_stream_event(event, state) do
    send(state.sink, {:delta, event.kind, event.data})
    state
  end

  @impl true
  def handle_response(_ref, _response, state), do: {:noreply, state}
end

{:ok, _pid} =
  GenAgent.start_agent(StreamAgent,
    name: :stream,
    backend: Primitives.ScriptedBackend,
    sink: self(),
    script: %{"hello tools" => {:tools, [{"lookup", %{id: 7}, "found"}]}}
  )

IO.puts("Stream callbacks run in the prompt task and forward deltas to a sink pid.")
assert {:ok, response} = GenAgent.ask(:stream, "hello tools")

expected = [
  {:text, %{text: "hello"}},
  {:text, %{text: " tools"}},
  {:tool_use, %{name: "lookup", input: %{id: 7}}},
  {:tool_result, %{name: "lookup", output: "found"}},
  {:usage, %{input_tokens: 2, output_tokens: 2}},
  {:result, %{text: "hello tools"}}
]

for pair <- expected do
  # Match the next delta regardless of kind, so this checks arrival order.
  assert_receive {:delta, kind, data}, 5_000
  assert {kind, data} == pair
end

assert Enum.map(response.events, &{&1.kind, &1.data}) == expected
assert :ok = GenAgent.stop(:stream)

IO.puts("Lossless retention fails the turn when max_events_per_turn is exceeded.")

{:ok, _pid} =
  GenAgent.start_agent(StreamAgent,
    name: :overflow,
    backend: Primitives.ScriptedBackend,
    sink: self(),
    max_events_per_turn: 2,
    event_retention: :lossless
  )

assert {:error,
        {:event_capture_overflow,
         %{max_events: 2, retained_events: 2, rejected_event_kind: :text}}} =
         GenAgent.ask(:overflow, "one two three")

assert %{state: :idle} = GenAgent.status(:overflow, 5_000)
assert :ok = GenAgent.stop(:overflow)
IO.puts("04_stream: ok")
