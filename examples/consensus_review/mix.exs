defmodule ConsensusReview.MixProject do
  use Mix.Project

  def project do
    [
      app: :consensus_review,
      version: "0.0.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:gen_agent, path: "../..", override: true},
      {:gen_agent_ensemble, path: "../../extensions/ensemble"}
    ]
  end
end
