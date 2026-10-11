defmodule GenAgentAnthropic.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/genagent/gen_agent"
  @source_path "integrations/anthropic"

  def project do
    [
      app: :gen_agent_anthropic,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      name: "GenAgentAnthropic",
      description: "Anthropic HTTP API backend for GenAgent, built on Req.",
      dialyzer: [plt_file: {:no_warn, "_build/dev/dialyxir_#{System.otp_release()}.plt"}]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      gen_agent_dep(),
      {:req, "~> 0.7.4"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "GenAgent.Backends.Anthropic",
      source_url: @source_url,
      source_ref: "gen_agent_anthropic-v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/gen_agent_anthropic-v#{@version}/#{@source_path}/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp gen_agent_dep do
    if System.get_env("GEN_AGENT_HEX") == "1" do
      {:gen_agent, "~> 0.2.0 or ~> 0.3.0 or ~> 0.4.0 or ~> 0.5.0 or ~> 0.6.0 or ~> 0.7.0"}
    else
      {:gen_agent, path: "../.."}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/#{@source_path}/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs),
      maintainers: ["Josh Rotenberg"]
    ]
  end
end
