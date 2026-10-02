import ExUnit.Assertions

defmodule HooksAgent do
  use GenAgent

  @impl true
  def init_agent(opts) do
    {:ok, [], %{owner: Keyword.fetch!(opts, :owner), ready: false, used: 0, budget: 8, turns: 0}}
  end

  @impl true
  def pre_run(state) do
    send(state.owner, :ready)
    {:ok, %{state | ready: true}}
  end

  @impl true
  def pre_turn("skip", state), do: {:skip, state}

  def pre_turn(_prompt, %{used: used, budget: budget} = state) when used >= budget,
    do: {:halt, state}

  def pre_turn(prompt, %{ready: true} = state), do: {:ok, "context " <> prompt, state}

  @impl true
  def handle_response(_ref, _response, state), do: {:noreply, %{state | turns: state.turns + 1}}

  @impl true
  def post_turn({:ok, response}, ref, state) do
    used = state.used + response.usage.input_tokens + response.usage.output_tokens
    send(state.owner, {:accounted, ref, used, state.turns})
    {:ok, %{state | used: used}}
  end
end

{:ok, _pid} =
  GenAgent.start_agent(HooksAgent,
    name: :hooks,
    backend: Primitives.ScriptedBackend,
    owner: self()
  )

IO.puts("pre_run prepares state once; pre_turn rewrites or skips a prompt.")
assert_receive :ready, 5_000
assert {:ok, %GenAgent.Response{text: "context hello"}} = GenAgent.ask(:hooks, "hello")
assert_receive {:accounted, _, 4, 1}, 5_000
assert {:error, :pre_turn_skipped} = GenAgent.ask(:hooks, "skip")
assert %{agent_state: %{used: 4, turns: 1}, halted: false} = GenAgent.status(:hooks, 5_000)

IO.puts("post_turn accounts for usage after handle_response; pre_turn enforces the budget.")
assert {:ok, %GenAgent.Response{text: "context again"}} = GenAgent.ask(:hooks, "again")
assert_receive {:accounted, _, 8, 2}, 5_000
# post_turn only updates state. The next pre_turn halts before backend dispatch.
assert {:error, :pre_turn_halted} = GenAgent.ask(:hooks, "over budget")

assert %{state: :idle, halted: true, agent_state: %{ready: true, used: 8, turns: 2}} =
         GenAgent.status(:hooks, 5_000)

assert :ok = GenAgent.stop(:hooks)
IO.puts("06_hooks: ok")
