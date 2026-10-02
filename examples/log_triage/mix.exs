defmodule LogTriage.MixProject do
  use Mix.Project

  def project do
    [
      app: :log_triage,
      version: "0.0.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {LogTriage.Application, []}]
  end

  defp deps do
    [{:gen_agent, path: "../.."}]
  end
end
