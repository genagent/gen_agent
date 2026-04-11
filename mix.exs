defmodule GenAgent.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/genagent/gen_agent"

  def project do
    [
      app: :gen_agent,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      name: "GenAgent",
      description:
        "A behaviour and supervision framework for long-running LLM agent processes, modeled as OTP state machines.",
      dialyzer: [plt_file: {:no_warn, "_build/dev/dialyxir_#{System.otp_release()}.plt"}]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {GenAgent.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "GenAgent",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "guides/patterns/overview.md": [title: "Patterns Overview"],
        "guides/patterns/switchboard.md": [title: "Switchboard"],
        "guides/patterns/research.md": [title: "Research"],
        "guides/patterns/debate.md": [title: "Debate"],
        "guides/patterns/pipeline.md": [title: "Pipeline"],
        "guides/patterns/supervisor.md": [title: "Supervisor"],
        "guides/patterns/pool.md": [title: "Pool"],
        "guides/patterns/watcher.md": [title: "Watcher"],
        "guides/patterns/checkpointer.md": [title: "Checkpointer"],
        "guides/patterns/retry.md": [title: "Retry"],
        "guides/patterns/workspace.md": [title: "Workspace"]
      ],
      groups_for_extras: [
        Patterns: ~r"guides/patterns/.*"
      ],
      groups_for_modules: [
        Core: [
          GenAgent,
          GenAgent.Backend,
          GenAgent.Event,
          GenAgent.Response
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides mix.exs README.md CHANGELOG.md LICENSE .formatter.exs),
      maintainers: ["Josh Rotenberg"]
    ]
  end
end
