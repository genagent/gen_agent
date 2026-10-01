defmodule GenAgentApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :gen_agent_app,
      version: "0.0.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {GenAgentApp.Application, []}]
  end

  defp deps do
    [
      {:gen_agent, path: "../..", override: true},
      {:gen_agent_ensemble, path: "../../extensions/ensemble"},
      {:gen_agent_claude, path: "../../integrations/claude"},
      {:gen_agent_codex, path: "../../integrations/codex"}
    ]
  end
end
