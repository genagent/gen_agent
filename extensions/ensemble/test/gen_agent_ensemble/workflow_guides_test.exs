defmodule GenAgentEnsemble.WorkflowGuidesTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble.Strategies.Supervisor, as: SupStrat

  @guides Path.expand("../../guides/workflows", __DIR__)

  defp guide(name), do: File.read!(Path.join(@guides, name))

  defp config_blocks(name) do
    ~r/```elixir\n(.*?)```/s
    |> Regex.scan(guide(name), capture: :all_but_first)
    |> Enum.map(fn [code] -> code end)
    |> Enum.filter(&String.contains?(&1, "config :gen_agent_ensemble"))
  end

  defp read_config(code, verify \\ fn _config -> :ok end) do
    path = Path.join(System.tmp_dir!(), "guide_config_#{System.unique_integer([:positive])}.exs")
    File.write!(path, "import Config\n" <> code)

    try do
      config = Config.Reader.read!(path)
      verify.(config)
      config
    after
      File.rm(path)
      :code.purge(DecisionParser)
      :code.delete(DecisionParser)
    end
  end

  defp agent_modules(config) do
    for {:gen_agent_ensemble, opts} <- config,
        {:ensembles, ensembles} <- opts,
        ensemble <- ensembles,
        {:agents, agents} <- Keyword.get(ensemble, :opts, []),
        {_name, mod, _opts} <- agents,
        do: mod
  end

  describe "debate.md" do
    test "config evaluates and every agent callback module exists" do
      [code | _] = config_blocks("debate.md")
      modules = code |> read_config() |> agent_modules()

      assert modules != []
      for mod <- modules, do: assert(Code.ensure_loaded?(mod), "#{inspect(mod)} is not defined")
    end
  end

  describe "consensus.md" do
    test "config evaluates self-contained and the parser runs" do
      [code | _] = config_blocks("consensus.md")

      read_config(code, fn config ->
        assert [_ | _] = agent_modules(config)
        parser = Module.concat(["DecisionParser"])
        assert {:ok, :approve, "Ready"} = parser.parse("Ready\nVERDICT: APPROVE")
        assert parser.system_prompt() =~ "VERDICT: APPROVE"
      end)
    end
  end

  describe "supervisor.md" do
    test "status examples use the phase shapes handle_status returns" do
      text = guide("supervisor.md")
      assert text =~ "phase: :decomposing"
      assert text =~ "phase: {:fanning_out, 0, 3}"

      state = %{
        coordinator: "c",
        queue: GenAgentEnsemble.Queue.new(),
        phase: {:decomposing, "tok"}
      }

      assert SupStrat.handle_status(state).phase == :decomposing

      fanning = %{state | phase: {:fanning_out, "tok", %{"a" => {:done, "x"}, "b" => :pending}}}
      assert SupStrat.handle_status(fanning).phase == {:fanning_out, 1, 2}
    end
  end
end
