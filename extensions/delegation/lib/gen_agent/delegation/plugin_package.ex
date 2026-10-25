defmodule GenAgent.Delegation.PluginPackage do
  @moduledoc """
  Local, no-overwrite plugin exporter. The builder receives a fresh runtime path
  and must return `:ok`; tests can supply a builder without compiling a release.
  """

  @version Mix.Project.config()[:version]
  @guidance [
    "SKILL.md",
    "references/parallel-tasks.md",
    "references/implementation-review.md",
    "references/follow-up.md",
    "references/model-effort.md",
    "references/profiles.md"
  ]
  @assets [
            "README.md",
            "LICENSE",
            "plugin.json",
            "mcp.json",
            ".claude-plugin/plugin.json",
            ".mcp.json",
            "bin/gen-agent-delegate",
            "bin/runtime-crypto.sh",
            "bin/check-install"
          ] ++ Enum.map(@guidance, &("skills/delegate/" <> &1))

  def asset_root do
    priv = :code.priv_dir(:gen_agent_delegation) |> to_string()
    # Mix links the application's priv directory to the packaged source during
    # local builds. Resolve that known link before enforcing the asset allowlist's
    # no-symlink rule; a relocated release has an ordinary priv directory.
    priv =
      case File.read_link(priv) do
        {:ok, target} -> Path.expand(target, Path.dirname(priv))
        {:error, :einval} -> priv
        {:error, reason} -> raise File.Error, reason: reason, action: "read priv", path: priv
      end

    Path.join(priv, "plugin")
  end

  def guidance, do: @guidance
  def assets, do: @assets

  def export!(output, opts \\ []) do
    source = Keyword.get(opts, :assets, asset_root()) |> Path.expand()
    version = Keyword.get(opts, :version, @version)

    unless version == @version,
      do: fail!("Manifest version differs from package version #{@version}")

    builder = Keyword.get(opts, :builder, &build_runtime!/1)
    resource = Keyword.get(opts, :resource_text, &GenAgent.Delegation.MCP.resource_text/1)
    validate_output!(output, source)
    # This is the ownership boundary: never clean up unless mkdir succeeded.
    File.mkdir!(output)

    try do
      for relative <- @assets do
        from = Path.join(source, relative)
        reject_symlink_components!(from)
        copy_file!(from, Path.join(output, relative))
      end

      for executable <- ["bin/gen-agent-delegate", "bin/check-install"] do
        unless Bitwise.band(File.stat!(Path.join(output, executable)).mode, 0o111) != 0,
          do: fail!("Plugin #{Path.basename(executable)} must be executable")
      end

      for manifest <- ["plugin.json", ".claude-plugin/plugin.json"] do
        data = output |> Path.join(manifest) |> File.read!() |> Jason.decode!()

        # The canonical files are templates; versions come from this package.
        File.write!(
          Path.join(output, manifest),
          Jason.encode!(Map.put(data, "version", version), pretty: true) <> "\n"
        )
      end

      runtime = Path.join(output, "runtime")
      staging = Path.join(output, ".runtime-build")

      case builder.(staging) do
        :ok -> :ok
        other -> fail!("Release builder failed: #{inspect(other)}")
      end

      reject_symlink_components!(staging)
      copy_runtime!(staging, runtime, staging, [])
      File.rm_rf!(staging)
      launcher = Path.join(runtime, "bin/delegation_spike")

      unless Bitwise.band(File.stat!(launcher).mode, 0o111) != 0,
        do: fail!("Runtime launcher must be executable")

      for relative <- @guidance do
        unless File.read!(Path.join(output, "skills/delegate/" <> relative)) ==
                 resource.(relative),
               do: fail!("Compiled MCP guidance differs: #{relative}")
      end

      marketplace = %{
        "name" => "genagent-local",
        "plugins" => [
          %{
            "name" => "gen-agent-delegate",
            "source" => %{"source" => "local", "path" => "./"},
            "policy" => %{"installation" => "AVAILABLE", "authentication" => "ON_INSTALL"},
            "category" => "Engineering"
          }
        ]
      }

      path = Path.join(output, ".agents/plugins/marketplace.json")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(marketplace, pretty: true) <> "\n")

      claude_marketplace = %{
        "name" => "genagent-local",
        "description" => "Local GenAgent Delegate installation candidates.",
        "owner" => %{"name" => "Josh Rotenberg"},
        "plugins" => [
          %{
            "name" => "gen-agent-delegate",
            "source" => "./",
            "description" => "Delegate bounded local tasks to Claude and Codex through GenAgent.",
            "version" => version
          }
        ]
      }

      File.write!(
        Path.join(output, ".claude-plugin/marketplace.json"),
        Jason.encode!(claude_marketplace, pretty: true) <> "\n"
      )

      output
    rescue
      error ->
        File.rm_rf!(output)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        File.rm_rf!(output)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp validate_output!(output, source) do
    unless Path.type(output) == :absolute, do: fail!("--output must be absolute")

    for root <- [source, asset_root()] do
      if inside?(Path.expand(output), root), do: fail!("Output cannot be inside source assets")
    end

    reject_symlink_components!(Path.dirname(Path.expand(output)))
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp reject_symlink_components!(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce(nil, fn part, parent ->
      current = if parent, do: Path.join(parent, part), else: part

      case File.lstat(current) do
        {:ok, %{type: :symlink}} ->
          fail!(
            "Symlink not allowed: #{current}; use an absolute path without symlink components"
          )

        _ ->
          :ok
      end

      current
    end)
  end

  defp copy_file!(from, to) do
    unless File.lstat!(from).type == :regular, do: fail!("Expected regular asset: #{from}")
    File.mkdir_p!(Path.dirname(to))
    File.cp!(from, to)
    File.chmod!(to, Bitwise.band(File.stat!(from).mode, 0o777))
  end

  defp copy_runtime!(from, to, root, seen) do
    unless inside?(from, root), do: fail!("Runtime symlink escapes release: #{from}")
    if from in seen, do: fail!("Runtime symlink cycle: #{from}")
    stat = File.lstat!(from)

    case stat.type do
      :symlink ->
        target = Path.expand(File.read_link!(from), Path.dirname(from))
        # Resolve component links as well as links at the leaf.
        target = resolve_runtime!(target, root, [from | seen])
        copy_runtime!(target, to, root, [from | seen])

      :directory ->
        File.mkdir!(to)

        for name <- File.ls!(from),
            do: copy_runtime!(Path.join(from, name), Path.join(to, name), root, [from | seen])

        File.chmod!(to, Bitwise.band(stat.mode, 0o777))

      :regular ->
        copy_file!(from, to)

      _ ->
        fail!("Unsupported runtime entry: #{from}")
    end
  end

  defp resolve_runtime!(path, root, seen) do
    unless inside?(path, root), do: fail!("Runtime symlink escapes release: #{path}")
    parts = Path.relative_to(path, root) |> Path.split()

    Enum.reduce(parts, root, fn part, parent ->
      current = Path.join(parent, part)

      if File.lstat!(current).type == :symlink do
        if current in seen, do: fail!("Runtime symlink cycle: #{current}")
        resolve_runtime!(Path.expand(File.read_link!(current), parent), root, [current | seen])
      else
        current
      end
    end)
  end

  def build_runtime!(runtime) do
    unless Mix.Project.config()[:app] == :gen_agent_delegation,
      do: fail!("Build from extensions/delegation so the release belongs to this package")

    unless Mix.env() == :prod, do: fail!("Build requires MIX_ENV=prod")
    Mix.Task.run("compile", ["--warnings-as-errors"])
    config = Mix.Project.config()

    releases =
      Keyword.update!(config[:releases], :delegation_spike, fn options ->
        Keyword.merge(options, include_erts: true, cookie: "gen_agent_delegate_local")
      end)

    Mix.ProjectStack.post_config(releases: releases)
    Mix.Task.run("release", ["delegation_spike", "--no-compile", "--path", runtime])
    :ok
  end

  defp fail!(message), do: raise(ArgumentError, message)
end
