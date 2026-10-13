defmodule GenAgentEnsemble.MixProject do
  use Mix.Project

  @version "0.6.1"
  @source_url "https://github.com/genagent/gen_agent"
  @source_path "extensions/ensemble"

  def project do
    [
      app: :gen_agent_ensemble,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      dialyzer: [plt_file: {:no_warn, "_build/dev/dialyxir_#{System.otp_release()}.plt"}]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {GenAgentEnsemble.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      gen_agent_dep(),
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ] ++ backend_deps()
  end

  defp gen_agent_dep do
    if System.get_env("GEN_AGENT_HEX") == "1" do
      {:gen_agent, "~> 0.7.0"}
    else
      {:gen_agent, path: "../.."}
    end
  end

  # Backends are development-only so installing Ensemble does not pull in a
  # wrapper or HTTP client. Use the local packages in the repository and Hex
  # dependencies when building a publishable archive.
  defp backend_deps do
    backends = [
      {:gen_agent_anthropic, "anthropic", "~> 0.4.2"},
      {:gen_agent_claude, "claude", "~> 0.2.7"},
      {:gen_agent_openai, "openai", "~> 0.4.1"},
      {:gen_agent_codex, "codex", "~> 0.5.0"}
    ]

    for {app, path, hex_constraint} <- backends do
      if System.get_env("GEN_AGENT_HEX") == "1" and
           System.get_env("GEN_AGENT_BACKENDS_PATH") != "1" do
        {app, hex_constraint, only: [:dev, :test]}
      else
        {app, path: "../../integrations/#{path}", only: [:dev, :test]}
      end
    end
  end

  defp description do
    "Multi-agent orchestration strategies for GenAgent. " <>
      "One ensemble process owns N sub-agents under a strategy " <>
      "(Solo, Switchboard, Pool, Pipeline, Supervisor, Debate, Consensus)."
  end

  defp package do
    [
      maintainers: ["Josh Rotenberg"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/#{@source_path}/CHANGELOG.md",
        "GenAgent" => "https://hex.pm/packages/gen_agent"
      },
      files: ~w(lib guides mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "guides/workflows/overview.md",
        "guides/workflows/solo.md",
        "guides/workflows/switchboard.md",
        "guides/workflows/pool.md",
        "guides/workflows/pipeline.md",
        "guides/workflows/supervisor.md",
        "guides/workflows/debate.md",
        "guides/workflows/consensus.md"
      ],
      groups_for_extras: [
        "Strategy workflows": ~r"guides/workflows/.*"
      ],
      source_ref: "gen_agent_ensemble-v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/gen_agent_ensemble-v#{@version}/#{@source_path}/%{path}#L%{line}"
    ]
  end
end
