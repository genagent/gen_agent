defmodule GenAgentEnsemble.RequestBoundariesTest do
  use ExUnit.Case, async: false
  alias GenAgentEnsemble, as: E
  alias GenAgentEnsemble.Strategies.{Pipeline, Pool, Solo, Switchboard}

  defmodule CallbackAgent do
    use GenAgent

    def init_agent(opts) do
      {:ok, Keyword.take(opts, [:observer, :tag]), %{observer: opts[:observer], responses: 0}}
    end

    def handle_response(ref, response, state) do
      send(state.observer, {:callback_response, ref, response.text})
      next = %{state | responses: state.responses + 1}

      if state.responses == 0,
        do: {:prompt, "followup", next},
        else: {:noreply, next}
    end
  end

  defp start(strategy) do
    name = {:contract_probe, strategy, make_ref()}

    worker =
      {"w", CallbackAgent, backend: GenAgentEnsemble.ControlledBackend, observer: self(), tag: :w}

    opts =
      case strategy do
        Solo ->
          [agent: worker]

        Pool ->
          [worker_count: 1, worker_template: worker]

        Switchboard ->
          [agents: [worker]]

        Pipeline ->
          [
            stages: [
              worker,
              {"tail", GenAgentEnsemble.Agents.Simple,
               backend: GenAgentEnsemble.Backends.Echo, transform: &Function.identity/1}
            ]
          ]
      end

    {:ok, _} = E.start_link(name: name, strategy: strategy, opts: opts)

    on_exit(fn ->
      try do
        E.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    {name, if(strategy == Switchboard, do: [agent: "w"], else: [])}
  end

  for strategy <- [Solo, Pool, Switchboard, Pipeline] do
    @strategy strategy
    test "#{strategy}: response follow-up does not finish a later token" do
      {name, opts} = start(@strategy)
      {:ok, first} = E.tell_with_completion(name, "first", self(), opts)
      assert_receive {:controlled_prompt, :w, "first", backend}, 1_000
      send(backend, {:result, "first result"})
      assert_receive {:callback_response, original_ref, "first result"}, 1_000
      assert_receive {:controlled_prompt, :w, "followup", followup}, 1_000

      assert_receive {:gen_agent_ensemble, :completion, ^name, ^first,
                      {:ok, %{text: "first result"}}},
                     1_000

      {:ok, second} = E.tell_with_completion(name, "second", self(), opts)
      assert E.poll(name, second) == {:ok, :pending}
      send(followup, {:result, "unowned followup"})
      assert_receive {:callback_response, followup_ref, "unowned followup"}, 1_000
      refute original_ref == followup_ref
      assert_receive {:controlled_prompt, :w, "second", queued}, 1_000
      assert E.poll(name, second) == {:ok, :pending}
      refute_receive {:gen_agent_ensemble, :completion, ^name, ^second, _}, 0
      send(queued, {:result, "second result"})

      assert_receive {:gen_agent_ensemble, :completion, ^name, ^second,
                      {:ok, %{text: "second result"}}},
                     1_000

      assert {:ok, %{text: "second result"}} = E.await(name, second, 1_000)
      refute_receive {:gen_agent_ensemble, :completion, ^name, ^first, _}, 50
      refute_receive {:gen_agent_ensemble, :completion, ^name, ^second, _}, 50
    end
  end
end
