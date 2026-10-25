defmodule GenAgent.Delegation.PluginPackageTest do
  use ExUnit.Case, async: true
  alias GenAgent.Delegation.PluginPackage, as: Package

  setup do
    tmp = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(tmp, "plugin package #{System.unique_integer([:positive])}")
    File.mkdir!(root)
    source = Path.join(root, "assets")
    File.mkdir!(source)

    for asset <- Package.assets() do
      target = Path.join(source, asset)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(Package.asset_root(), asset), target)
    end

    File.write!(Path.join(source, "secret"), "excluded")
    output = Path.join(root, "new export")
    on_exit(fn -> File.rm_rf!(root) end)

    opts = [
      assets: source,
      version: "0.0.12",
      builder: &fake_runtime/1,
      resource_text: fn relative ->
        File.read!(Path.join(source, "skills/delegate/" <> relative))
      end
    ]

    %{root: root, source: source, output: output, opts: opts}
  end

  defp fake_runtime(runtime) do
    File.mkdir_p!(Path.join(runtime, "bin"))
    File.write!(Path.join(runtime, "bin/delegation_spike"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(runtime, "bin/delegation_spike"), 0o755)
    File.ln_s!("delegation_spike", Path.join(runtime, "bin/alias"))

    File.ln_s!(
      Path.join(runtime, "bin/delegation_spike"),
      Path.join(runtime, "bin/absolute-alias")
    )

    :ok
  end

  defp files(root) do
    for name <- File.ls!(root), reduce: [] do
      acc ->
        path = Path.join(root, name)
        assert File.lstat!(path).type != :symlink
        acc ++ if(File.dir?(path), do: Enum.map(files(path), &Path.join(name, &1)), else: [name])
    end
  end

  test "task rejects missing output and unknown options before compilation" do
    for args <- [[], ["--output", "/unused", "--force"], ["--output", "/unused", "extra"]] do
      assert_raise Mix.Error, "Expected only --output /absolute/new/plugin-dir", fn ->
        Mix.Tasks.GenAgent.Plugin.Build.run(args)
      end
    end
  end

  test "missing runtime explains bundle recovery without assuming a source checkout", ctx do
    assert {message, 1} =
             System.cmd("sh", [Path.join(ctx.source, "bin/gen-agent-delegate")],
               stderr_to_stdout: true
             )

    assert message =~ "re-extract the complete package"
    assert message =~ "executable permissions preserved"
    assert message =~ "From a source checkout"
  end

  test "exports exactly the assets, guidance, marketplace and materialized runtime with spaces",
       ctx do
    assert Package.export!(ctx.output, ctx.opts) == ctx.output

    assert Enum.sort(files(ctx.output)) ==
             Enum.sort(
               Package.assets() ++
                 [
                   ".agents/plugins/marketplace.json",
                   ".claude-plugin/marketplace.json",
                   "runtime/bin/delegation_spike",
                   "runtime/bin/alias",
                   "runtime/bin/absolute-alias"
                 ]
             )

    for asset <- Package.assets() do
      if asset in ["plugin.json", ".claude-plugin/plugin.json"] do
        template = ctx.source |> Path.join(asset) |> File.read!() |> Jason.decode!()
        manifest = ctx.output |> Path.join(asset) |> File.read!() |> Jason.decode!()
        assert manifest == Map.put(template, "version", "0.0.12")
      else
        assert File.read!(Path.join(ctx.output, asset)) ==
                 File.read!(Path.join(ctx.source, asset))
      end
    end

    for executable <- [
          "bin/gen-agent-delegate",
          "bin/check-install",
          "runtime/bin/delegation_spike",
          "runtime/bin/alias",
          "runtime/bin/absolute-alias"
        ] do
      assert Bitwise.band(File.stat!(Path.join(ctx.output, executable)).mode, 0o777) == 0o755
    end

    marketplace =
      ctx.output
      |> Path.join(".agents/plugins/marketplace.json")
      |> File.read!()
      |> Jason.decode!()

    assert marketplace["name"] == "genagent-local"
    assert hd(marketplace["plugins"])["source"] == %{"source" => "local", "path" => "./"}

    claude_marketplace =
      ctx.output
      |> Path.join(".claude-plugin/marketplace.json")
      |> File.read!()
      |> Jason.decode!()

    assert claude_marketplace["name"] == "genagent-local"
    assert hd(claude_marketplace["plugins"])["source"] == "./"
    assert hd(claude_marketplace["plugins"])["version"] == "0.0.12"
  end

  test "default export uses packaged priv assets and the compiled package identity", ctx do
    assert Package.export!(ctx.output, builder: &fake_runtime/1) == ctx.output
    manifest = ctx.output |> Path.join("plugin.json") |> File.read!() |> Jason.decode!()
    assert manifest["version"] == GenAgent.Delegation.MCP.runtime().server_info["version"]
    assert manifest["version"] == "0.0.12"

    for relative <- Package.guidance() do
      assert File.read!(Path.join(ctx.output, "skills/delegate/" <> relative)) ==
               GenAgent.Delegation.MCP.resource_text(relative)
    end
  end

  test "rejects relative, asset-contained and existing destinations without changing them", ctx do
    for output <- [
          "relative",
          Path.join(ctx.source, "export"),
          Path.join(Package.asset_root(), "export")
        ] do
      assert_raise ArgumentError, fn -> Package.export!(output, ctx.opts) end
    end

    File.mkdir!(ctx.output)
    sentinel = Path.join(ctx.output, "keep")
    File.write!(sentinel, "user data")
    assert_raise File.Error, fn -> Package.export!(ctx.output, ctx.opts) end
    assert File.read!(sentinel) == "user data"
  end

  test "builder and validation failures remove only the new output", ctx do
    builders = [
      fn runtime ->
        fake_runtime(runtime)
        {:error, :failed}
      end,
      fn runtime ->
        fake_runtime(runtime)
        raise "builder failure"
      end
    ]

    for {error, builder} <- Enum.zip([ArgumentError, RuntimeError], builders) do
      assert_raise error, fn ->
        Package.export!(ctx.output, Keyword.put(ctx.opts, :builder, builder))
      end

      refute File.exists?(ctx.output)
    end

    for opts <- [
          Keyword.put(ctx.opts, :version, "mismatch"),
          Keyword.put(ctx.opts, :resource_text, fn _ -> "stale" end)
        ] do
      assert_raise ArgumentError, fn -> Package.export!(ctx.output, opts) end
      refute File.exists?(ctx.output)
    end

    assert File.read!(Path.join(ctx.source, "secret")) == "excluded"
  end

  test "symlinked output parent explains the requirement before building or cleanup", ctx do
    real = Path.join(ctx.root, "real-parent")
    linked = Path.join(ctx.root, "linked-parent")
    File.mkdir!(real)
    File.write!(Path.join(real, "keep"), "existing data")
    File.ln_s!(real, linked)

    error =
      assert_raise ArgumentError, fn ->
        Package.export!(
          Path.join(linked, "export"),
          Keyword.put(ctx.opts, :builder, fn _ -> flunk("must not build") end)
        )
      end

    assert error.message =~ "Symlink not allowed: #{linked}"
    assert error.message =~ "use an absolute path without symlink components"
    assert File.read!(Path.join(real, "keep")) == "existing data"
    refute File.exists?(Path.join(real, "export"))
    assert File.lstat!(linked).type == :symlink
  end

  test "rejects source links and escaping runtime links", ctx do
    asset = Path.join(ctx.source, "mcp.json")
    File.rename!(asset, asset <> ".real")
    File.ln_s!("mcp.json.real", asset)
    assert_raise ArgumentError, fn -> Package.export!(ctx.output, ctx.opts) end
    refute File.exists?(ctx.output)
    File.rm!(asset)
    File.rename!(asset <> ".real", asset)

    builder = fn runtime ->
      fake_runtime(runtime)
      File.ln_s!(ctx.source, Path.join(runtime, "outside"))
      :ok
    end

    assert_raise ArgumentError, fn ->
      Package.export!(ctx.output, Keyword.put(ctx.opts, :builder, builder))
    end

    refute File.exists?(ctx.output)
  end

  test "rejects a non-executable plugin launcher", ctx do
    File.chmod!(Path.join(ctx.source, "bin/gen-agent-delegate"), 0o644)

    assert_raise ArgumentError, "Plugin gen-agent-delegate must be executable", fn ->
      Package.export!(ctx.output, ctx.opts)
    end

    refute File.exists?(ctx.output)
  end

  test "rejects a non-executable preflight", ctx do
    File.chmod!(Path.join(ctx.source, "bin/check-install"), 0o644)

    assert_raise ArgumentError, "Plugin check-install must be executable", fn ->
      Package.export!(ctx.output, ctx.opts)
    end

    refute File.exists?(ctx.output)
  end

  test "rejects component links and cyclic or dangling runtime links", ctx do
    skills = Path.join(ctx.source, "skills")
    File.rename!(skills, skills <> ".real")
    File.ln_s!("skills.real", skills)
    assert_raise ArgumentError, fn -> Package.export!(ctx.output, ctx.opts) end
    refute File.exists?(ctx.output)
    File.rm!(skills)
    File.rename!(skills <> ".real", skills)

    for target <- ["cycle", "missing"] do
      builder = fn runtime ->
        fake_runtime(runtime)
        File.ln_s!(target, Path.join(runtime, "cycle"))
        :ok
      end

      assert_raise if(target == "cycle", do: ArgumentError, else: File.Error), fn ->
        Package.export!(ctx.output, Keyword.put(ctx.opts, :builder, builder))
      end

      refute File.exists?(ctx.output)
    end
  end

  test "exclusive destination reservation permits only one exporter", ctx do
    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          try do
            Package.export!(ctx.output, ctx.opts)
            :ok
          rescue
            File.Error -> :exists
          end
        end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.sort(results) == [:exists, :ok]
    assert File.exists?(Path.join(ctx.output, "runtime/bin/delegation_spike"))
  end
end
