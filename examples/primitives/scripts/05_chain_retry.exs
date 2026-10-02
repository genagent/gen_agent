import ExUnit.Assertions

defmodule ChainRetryAgent do
  use GenAgent

  @impl true
  def init_agent(opts) do
    {:ok, Keyword.take(opts, [:script]),
     %{
       owner: Keyword.fetch!(opts, :owner),
       retry_prompt: Keyword.get(opts, :retry_prompt),
       retries: 0,
       max_retries: 2
     }}
  end

  @impl true
  def handle_response(ref, response, state) do
    send(state.owner, {:response, ref, response.text})

    case response.text do
      "first" -> {:prompt, "second", state}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_error(ref, reason, state) do
    send(state.owner, {:failed, ref, reason, state.retries})

    if state.retries < state.max_retries do
      {:prompt, state.retry_prompt, %{state | retries: state.retries + 1}}
    else
      {:halt, state}
    end
  end
end

{:ok, _pid} =
  GenAgent.start_agent(ChainRetryAgent,
    name: :chain,
    backend: Primitives.ScriptedBackend,
    owner: self()
  )

IO.puts("A response can enqueue a follow-up prompt with its own request ref.")
{:ok, first} = GenAgent.tell(:chain, "first")
assert_receive {:response, ^first, "first"}, 5_000
assert_receive {:response, second, "second"}, 5_000
assert second != first
assert {:ok, :completed, %GenAgent.Response{text: "first"}} = GenAgent.poll(:chain, first, 5_000)
assert %{state: :idle} = GenAgent.status(:chain, 5_000)
assert :ok = GenAgent.stop(:chain)

IO.puts("Both synchronous failures and terminal error events use bounded handle_error retries.")

for {name, behavior} <- [sync_retry: {:fail, :unavailable}, event_retry: {:error, :unavailable}] do
  {:ok, _pid} =
    GenAgent.start_agent(ChainRetryAgent,
      name: name,
      backend: Primitives.ScriptedBackend,
      owner: self(),
      retry_prompt: "retry",
      script: %{"retry" => behavior}
    )

  {:ok, original} = GenAgent.tell(name, "retry")

  refs =
    for attempt <- 0..2 do
      assert_receive {:failed, ref, :unavailable, retries}, 5_000
      assert retries == attempt
      ref
    end

  assert hd(refs) == original
  assert Enum.uniq(refs) == [original]
  # Every failed attempt stays with the original request; the final failure
  # is stored only after the retry budget is exhausted.
  assert {:error, :unavailable} = GenAgent.poll(name, original, 5_000)

  assert %{state: :idle, halted: true, queued: 0, agent_state: %{retries: 2}} =
           GenAgent.status(name, 5_000)

  assert :ok = GenAgent.stop(name)
end

IO.puts("05_chain_retry: ok")
