defmodule GenAgentStructured.MixProject do
  use Mix.Project

  def project do
    [app: :gen_agent_structured, version: "0.0.0", elixir: "~> 1.19", deps: deps()]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {GenAgent.Structured.Application, []}]
  end

  defp deps do
    [
      {:gen_agent, path: "../.."},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11.5"},
      {:gen_agent_claude, path: "../claude", optional: true},
      {:gen_agent_codex, path: "../codex", optional: true}
    ]
  end
end
