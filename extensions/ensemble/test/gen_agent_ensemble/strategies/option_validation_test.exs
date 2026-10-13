defmodule GenAgentEnsemble.Strategies.OptionValidationTest do
  use ExUnit.Case, async: true

  alias GenAgent.Backends.Mock
  alias GenAgentEnsemble.Strategies.{Consensus, Debate, Pool, Supervisor, Switchboard}
  alias GenAgentEnsemble.TestAgent

  defp spec(name), do: {name, TestAgent, [backend: Mock, scripts: []]}
  defp parser, do: fn _ -> :error end

  # Overrides replace base keys; `++` would leave the base value first, and
  # `Keyword.get/3` reads the first duplicate.
  defp consensus_opts(extra) do
    [agents: [spec("a"), spec("b"), spec("c")], verdict_parser: parser()]
    |> Keyword.merge(extra)
  end

  defp debate_opts(extra), do: Keyword.merge([agents: [spec("a"), spec("b")]], extra)

  defp supervisor_opts(extra) do
    [
      coordinator: spec("coord"),
      worker_template: {"w", TestAgent, [backend: Mock, scripts: []]},
      decomposer: &String.split(&1, "\n")
    ]
    |> Keyword.merge(extra)
  end

  defp pool_opts(extra) do
    [worker_template: {"w", TestAgent, [backend: Mock, scripts: []]}]
    |> Keyword.merge(extra)
  end

  describe "Consensus" do
    test "rejects invalid :rounds" do
      for bad <- [nil, 0, -1, 1.5, "3"] do
        assert_raise ArgumentError, ~r/:rounds must be a positive integer/, fn ->
          Consensus.init(consensus_opts(rounds: bad))
        end
      end
    end

    test "rejects unsupported :reply" do
      for bad <- [:last, :bogus, nil, {:synthesize, fn -> :ok end}, {:synthesize, :nope}] do
        assert_raise ArgumentError, ~r/:reply must be/, fn ->
          Consensus.init(consensus_opts(reply: bad))
        end
      end
    end

    test "rejects malformed :agents specs naming only the index" do
      secret_opts = [{:api_key, "s3cret"}, :flag]

      for bad <- [
            :nope,
            [spec("a"), :bad, spec("c")],
            [spec("a"), {"b", TestAgent}, spec("c")],
            [spec("a"), {"b", "NotAnAtom", []}, spec("c")],
            [spec("a"), {"b", TestAgent, :not_a_list}, spec("c")],
            [spec("a"), {"b", TestAgent, secret_opts}, spec("c")]
          ] do
        error =
          assert_raise ArgumentError, fn ->
            Consensus.init(consensus_opts(agents: bad))
          end

        refute error.message =~ "s3cret"
      end

      error =
        assert_raise ArgumentError, ~r/:agents entry 1 must be/, fn ->
          Consensus.init(consensus_opts(agents: [spec("a"), {"b", TestAgent, secret_opts}]))
        end

      refute error.message =~ "s3cret"
    end

    test "malformed specs are reported before the count and duplicate checks" do
      assert_raise ArgumentError, ~r/:agents entry 0 must be/, fn ->
        Consensus.init(consensus_opts(agents: [:bad]))
      end

      assert_raise ArgumentError, ~r/duplicate agent names/, fn ->
        Consensus.init(consensus_opts(agents: [spec("a"), spec("a")]))
      end
    end

    test "accepts defaults and custom options" do
      assert {:ok, state, specs} = Consensus.init(consensus_opts([]))
      assert state.rounds == 3
      assert state.reply_kind == :synthesis
      assert length(specs) == 3

      assert {:ok, state, _} =
               Consensus.init(consensus_opts(rounds: 1, reply: {:synthesize, &inspect/1}))

      assert state.rounds == 1
      assert {:synthesize, _} = state.reply_kind
    end
  end

  describe "Debate" do
    test "rejects invalid :rounds" do
      for bad <- [nil, 0, -2, 2.0, :six] do
        assert_raise ArgumentError, ~r/:rounds must be a positive integer/, fn ->
          Debate.init(debate_opts(rounds: bad))
        end
      end
    end

    test "rejects invalid :converge" do
      for bad <- [nil, :never, fn -> false end, fn _, _ -> false end] do
        assert_raise ArgumentError, ~r/:converge must be a 1-arity function/, fn ->
          Debate.init(debate_opts(converge: bad))
        end
      end
    end

    test "rejects unsupported :reply" do
      for bad <- [:synthesis, :bogus, nil, {:synthesize, fn -> :ok end}, {:synthesize, :nope}] do
        assert_raise ArgumentError, ~r/:reply must be/, fn ->
          Debate.init(debate_opts(reply: bad))
        end
      end
    end

    test "accepts defaults and custom options" do
      assert {:ok, state, _} = Debate.init(debate_opts([]))
      assert state.rounds == 6
      assert state.reply_kind == :transcript
      assert state.converge.("x") == false

      for reply <- [:transcript, :last, {:synthesize, &inspect/1}] do
        assert {:ok, state, _} =
                 Debate.init(debate_opts(rounds: 2, converge: &(&1 == "done"), reply: reply))

        assert state.rounds == 2
        assert state.reply_kind == reply
      end
    end
  end

  describe "Supervisor" do
    test "rejects invalid :decomposer" do
      for bad <- [nil, :split, fn -> [] end, fn _, _ -> [] end] do
        assert_raise ArgumentError, ~r/:decomposer must be a 1-arity function/, fn ->
          Supervisor.init(supervisor_opts(decomposer: bad))
        end
      end
    end

    test "rejects invalid :synthesizer" do
      for bad <- [nil, :join, fn -> "" end, fn _, _, _ -> "" end] do
        assert_raise ArgumentError, ~r/:synthesizer must be a 1- or 2-arity function/, fn ->
          Supervisor.init(supervisor_opts(synthesizer: bad))
        end
      end
    end

    test "rejects worker options that are not a keyword list with :backend" do
      secret = "s3cret"

      for bad <- [
            [],
            [scripts: []],
            [{:api_key, secret}],
            [{:api_key, secret}, :flag],
            [{:backend, Mock} | secret],
            :not_a_list,
            %{backend: Mock, api_key: secret},
            nil
          ] do
        error =
          assert_raise ArgumentError, ~r/:worker_template options/, fn ->
            Supervisor.init(supervisor_opts(worker_template: {"w", TestAgent, bad}))
          end

        refute error.message =~ secret
      end
    end

    test "invalid worker options fail zero-work startup before any agent tree" do
      name = "optval-#{System.unique_integer([:positive])}"

      opts =
        supervisor_opts(
          worker_template: {"w", TestAgent, [api_key: "s3cret"]},
          decomposer: fn _ -> [] end
        )

      assert {:error, {:init_failed, :error, ArgumentError}} =
               GenAgentEnsemble.start_link(name: name, strategy: Supervisor, opts: opts)

      assert Registry.lookup(GenAgentEnsemble.Registry, name) == []
      assert Registry.lookup(GenAgentEnsemble.AgentTreeRegistry, name) == []
    end

    test "accepts defaults and 1- or 2-arity synthesizers" do
      assert {:ok, state, [{"coord", _, _}]} = Supervisor.init(supervisor_opts([]))
      assert state.max_subtasks == 10
      assert is_function(state.synthesizer, 2)

      assert {:ok, _, _} = Supervisor.init(supervisor_opts(synthesizer: &inspect/1))
      assert {:ok, _, _} = Supervisor.init(supervisor_opts(synthesizer: fn o, s -> {o, s} end))
    end
  end

  describe "Pool" do
    test "rejects non-positive or non-integer :worker_count" do
      for bad <- [nil, 0, -3, 1.5, "2"] do
        assert_raise ArgumentError, ~r/:worker_count must be a positive integer/, fn ->
          Pool.init(pool_opts(worker_count: bad))
        end
      end
    end

    test "starts exactly :worker_count ascending workers" do
      assert {:ok, _state, specs} = Pool.init(pool_opts(worker_count: 3))
      assert Enum.map(specs, &elem(&1, 0)) == ["w-1", "w-2", "w-3"]
    end
  end

  describe "Switchboard" do
    test "rejects an empty fleet" do
      assert_raise ArgumentError, ~r/at least 1 agent/, fn ->
        Switchboard.init(agents: [])
      end
    end

    test "accepts a single agent" do
      assert {:ok, _state, [{"solo", _, _}]} = Switchboard.init(agents: [spec("solo")])
    end
  end

  test "malformed options fail public startup before creating an agent tree" do
    cases = [
      {Consensus, consensus_opts(rounds: nil)},
      {Consensus, consensus_opts(agents: [spec("a"), {"b", TestAgent, [:bare]}])},
      {Debate, debate_opts(reply: :bogus)},
      {Supervisor, supervisor_opts(decomposer: nil)},
      {Pool, pool_opts(worker_count: 0)},
      {Switchboard, [agents: []]}
    ]

    for {strategy, opts} <- cases do
      name = "optval-#{System.unique_integer([:positive])}"

      assert {:error, {:init_failed, :error, ArgumentError}} =
               GenAgentEnsemble.start_link(name: name, strategy: strategy, opts: opts)

      assert Registry.lookup(GenAgentEnsemble.Registry, name) == []
      assert Registry.lookup(GenAgentEnsemble.AgentTreeRegistry, name) == []
    end
  end
end
