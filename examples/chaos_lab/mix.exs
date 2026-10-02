defmodule ChaosLab.MixProject do
  use Mix.Project

  def project do
    [
      app: :chaos_lab,
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
    [{:gen_agent, path: "../.."}]
  end
end
