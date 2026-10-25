defmodule Mix.Tasks.GenAgent.Plugin.Build do
  use Mix.Task

  @shortdoc "Export a new local plugin with a production runtime (no install or fetch)"
  @moduledoc """
  Run with MIX_ENV=prod mix gen_agent.plugin.build --output /absolute/new/plugin-dir.
  Requires provisioned production dependencies; never fetches dependencies or starts
  the application. The destination must not exist. No force/overwrite option.
  Its parent directories must contain no symlinks; on macOS use /private/tmp
  instead of /tmp when exporting to a temporary directory.
  """

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [output: :string])

    unless positional == [] and invalid == [] and length(opts) == 1 and opts[:output],
      do: Mix.raise("Expected only --output /absolute/new/plugin-dir")

    unless Mix.env() == :prod, do: Mix.raise("Build requires MIX_ENV=prod")

    unless Mix.Project.config()[:app] == :gen_agent_delegation,
      do: Mix.raise("Run from extensions/delegation")

    # Compile makes the helper available on a fresh checkout; it does not start apps.
    Mix.Task.run("compile", ["--warnings-as-errors"])

    try do
      output = GenAgent.Delegation.PluginPackage.export!(opts[:output])
      IO.puts(:stderr, "Exported #{output} for #{:erlang.system_info(:system_architecture)}")

      IO.puts(
        :stderr,
        "Register this export root with codex plugin marketplace add, then install gen-agent-delegate@genagent-local. Installation is manual."
      )
    rescue
      error -> Mix.raise(Exception.message(error))
    end
  end
end
