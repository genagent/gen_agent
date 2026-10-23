defmodule GenAgent.CICacheTest do
  use ExUnit.Case, async: true

  @workflow Path.expand("../.github/workflows/ci.yml", __DIR__)

  test "package caches reuse dependency downloads without stale compiled artifacts" do
    workflow = File.read!(@workflow)

    for {job, namespace, toolchain} <- [
          {"packages", "mix-package-deps-v2", "1.20-29"},
          {"publish-toolchain", "mix-publish-deps-v2", "1.19-27"}
        ] do
      [_, body] = String.split(workflow, "  #{job}:\n", parts: 2)
      body = body |> String.split(~r/\n  [a-z][a-z-]*:\n/, parts: 2) |> hd()

      caches =
        body
        |> String.split(~r/\n      - /)
        |> Enum.filter(&String.contains?(&1, "uses: actions/cache@"))

      assert length(caches) == 1, "expected one deps-only cache in #{job}"

      for cache <- caches do
        # An allowlist rejects _build, PLTs, parent directories and broad globs.
        assert [_, paths] = Regex.run(~r/          path: \|\n(.*?)          key:/s, cache)

        assert String.split(paths, "\n", trim: true) |> Enum.map(&String.trim/1) ==
                 ["${{ matrix.package }}/deps"]

        prefix = "#{namespace}-${{ matrix.package }}-#{toolchain}-"
        assert cache =~ "key: #{prefix}${{ hashFiles("
        assert cache =~ "format('{0}/mix.lock', matrix.package)"
        assert cache =~ "format('{0}/mix.exs', matrix.package)"

        # Even a deps-only path must never restore the old mixed-artifact archive.
        assert [_, restore_keys] = Regex.run(~r/          restore-keys: \|\n(.*)/s, cache)

        assert String.split(restore_keys, "\n", trim: true) |> Enum.map(&String.trim/1) ==
                 [prefix]
      end
    end
  end
end
