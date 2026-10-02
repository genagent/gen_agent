import ExUnit.Assertions

defmodule HelloAgent do
  use GenAgent

  @impl true
  def init_agent(opts) do
    {:ok, Keyword.take(opts, [:delay_ms, :script]),
     %{owner: Keyword.fetch!(opts, :owner), responses: []}}
  end

  @impl true
  def handle_response(ref, response, state) do
    send(state.owner, {:response, ref, response.text})
    {:noreply, %{state | responses: state.responses ++ [response.text]}}
  end
end

{:ok, _pid} =
  GenAgent.start_agent(HelloAgent,
    name: :hello,
    backend: Primitives.ScriptedBackend,
    owner: self(),
    delay_ms: 0,
    script: %{"first" => {:gate, self()}}
  )

IO.puts("ask waits for a response; init_agent and handle_response maintain callback state.")
{:ok, %GenAgent.Response{text: "hello world"} = response} = GenAgent.ask(:hello, "hello world")
assert response.usage == %{input_tokens: 2, output_tokens: 2}
assert Enum.map(response.events, & &1.kind) == [:text, :text, :usage, :result]
assert response.terminal.kind == :result
assert response.event_coverage.mode == :exact
assert response.duration_ms >= 0
assert response.session_id == nil
assert_receive {:response, _, "hello world"}, 5_000

IO.puts("tell returns a ref; poll reports pending while the backend gate is closed.")
{:ok, first} = GenAgent.tell(:hello, "first")
assert_receive {:scripted_turn, "first", task, token}, 5_000
assert {:ok, :pending} = GenAgent.poll(:hello, first, 5_000)
{:ok, second} = GenAgent.tell(:hello, "second")
{:ok, third} = GenAgent.tell(:hello, "third")
assert %{state: :processing, queued: 2, current_request: ^first} = GenAgent.status(:hello, 5_000)
send(task, {:release, token})

# Consume the next response without selecting a particular ref, so order is tested.
for {ref, text} <- [{first, "first"}, {second, "second"}, {third, "third"}] do
  assert_receive {:response, received_ref, received_text}, 5_000
  assert {received_ref, received_text} == {ref, text}
  assert {:ok, :completed, %GenAgent.Response{text: ^text}} = GenAgent.poll(:hello, ref, 5_000)
end

IO.puts("poll now reports completed; all three tells ran in FIFO order.")

assert %{state: :idle, queued: 0, halted: false, agent_state: state} =
         GenAgent.status(:hello, 5_000)

assert state.responses == ["hello world", "first", "second", "third"]
assert :ok = GenAgent.stop(:hello)
IO.puts("01_hello: ok")
