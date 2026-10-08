defmodule GenAgent.ReleaseWorkflowTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  test "manifest versions match package mix files and release configuration" do
    manifest =
      @root
      |> Path.join(".release-please-manifest.json")
      |> File.read!()
      |> Jason.decode!()

    config =
      @root
      |> Path.join("release-please-config.json")
      |> File.read!()
      |> Jason.decode!()

    assert Map.keys(manifest) |> Enum.sort() == Map.keys(config["packages"]) |> Enum.sort()

    for {path, version} <- manifest do
      mix_file = File.read!(Path.join([@root, path, "mix.exs"]))
      assert [_, ^version] = Regex.run(~r/@version\s+"([^"]+)"/, mix_file)
    end

    core_excludes = config["packages"]["."]["exclude-paths"]

    for path <- [".github", "scripts", "design", "RELEASING.md", "MIGRATION.md"] do
      assert path in core_excludes
    end
  end

  test "publish jobs have read-only repository access and immutable actions" do
    release = File.read!(Path.join(@root, ".github/workflows/release.yml"))
    recovery = File.read!(Path.join(@root, ".github/workflows/publish-recovery.yml"))

    assert release =~ "permissions: {}"
    assert job_block(release, "release-please") =~ "contents: write"
    assert job_block(release, "release-please") =~ "pull-requests: write"

    for job <- ["publish-core", "publish-integrations", "publish-ensemble"] do
      block = job_block(release, job)
      assert block =~ "contents: read"
      refute block =~ "contents: write"
      refute block =~ "pull-requests: write"
      assert block =~ "persist-credentials: false"
    end

    assert job_block(recovery, "publish") =~ "contents: read" or
             recovery =~ "permissions:\n  contents: read"

    assert recovery =~ "persist-credentials: false"

    for workflow <- [release, recovery],
        step <- String.split(workflow, "      - name:") do
      if step =~ "publish-package.sh" do
        if step =~ " prepare" do
          refute step =~ "HEX_API_KEY"
          assert step =~ "id: prepare"
        else
          assert step =~ " publish"
          assert step =~ "HEX_API_KEY"
          assert step =~ "steps.prepare.outputs.already_published == 'false'"
        end
      end
    end

    actions =
      for workflow <- [release, recovery],
          [_, action] <- Regex.scan(~r/uses:\s+([^\s#]+)/, workflow),
          do: action

    assert length(actions) == 9
    assert Enum.all?(actions, &Regex.match?(~r/\A[^@]+@[0-9a-f]{40}\z/, &1))
  end

  test "only the publish command inherits the Hex key" do
    {output, status} = System.cmd("bash", [Path.join(@root, "scripts/test-publish-package.sh")])
    assert status == 0, output
  end

  test "package archive checks fail with clear diagnostics" do
    {output, status} = System.cmd("bash", [Path.join(@root, "scripts/test-package-check.sh")])
    assert status == 0, output
  end

  test "example scope only skips documentation-only PRs" do
    {output, status} = System.cmd("bash", [Path.join(@root, "scripts/test-ci-example-scope.sh")])
    assert status == 0, output
  end

  test "publish jobs check out the tag for the released component" do
    release = File.read!(Path.join(@root, ".github/workflows/release.yml"))

    for {path, output} <- [
          {"integrations/claude", "claude_tag"},
          {"integrations/codex", "codex_tag"},
          {"integrations/anthropic", "anthropic_tag"},
          {"integrations/openai", "openai_tag"},
          {"extensions/ensemble", "ensemble_tag"}
        ] do
      assert release =~
               "#{output}: \${{ steps.release.outputs['#{path}--tag_name'] }}"
    end

    assert release =~ "core_tag: \${{ steps.release.outputs.tag_name }}"

    for {job, tag_ref} <- [
          {"publish-core", "needs.release-please.outputs.core_tag"},
          {"publish-integrations", "needs.release-please.outputs[matrix.tag_output]"},
          {"publish-ensemble", "needs.release-please.outputs.ensemble_tag"}
        ] do
      block = job_block(release, job)
      assert block =~ "RELEASE_TAG: \${{ #{tag_ref} }}"
      assert block =~ "run: test -n \"$RELEASE_TAG\""
      assert block =~ "ref: \${{ #{tag_ref} }}"
      assert index!(block, "run: test -n") < index!(block, "actions/checkout@")
    end

    for {path, output} <- [
          {"integrations/claude", "claude_tag"},
          {"integrations/codex", "codex_tag"},
          {"integrations/anthropic", "anthropic_tag"},
          {"integrations/openai", "openai_tag"}
        ] do
      assert release =~ "package: #{path}\n            tag_output: #{output}"
    end
  end

  test "Release Please only follows successful CI for current main" do
    release = File.read!(Path.join(@root, ".github/workflows/release.yml"))
    [trigger, _jobs] = String.split(release, "jobs:\n", parts: 2)
    verify = job_block(release, "verify-ci")
    release_please = job_block(release, "release-please")

    assert trigger =~ "workflow_run:"
    assert trigger =~ "workflows: [CI]"
    assert trigger =~ "types: [completed]"
    assert trigger =~ "branches: [main]"
    refute trigger =~ "  push:"
    refute trigger =~ "workflow_dispatch:"

    assert verify =~ "github.event.workflow_run.event == 'push'"
    assert verify =~ "github.event.workflow_run.conclusion == 'success'"
    assert verify =~ "github.event.workflow_run.head_repository.full_name == github.repository"
    assert verify =~ "github.event.workflow_run.head_sha"
    assert verify =~ "git/ref/heads/main"
    assert verify =~ ~s(if [[ "$current_sha" == "$PASSED_SHA" ]])
    assert release_please =~ "needs: verify-ci"
    assert release_please =~ "needs.verify-ci.outputs.current == 'true'"
  end

  test "each Release Please component owns its installation version" do
    config = @root |> Path.join("release-please-config.json") |> File.read!() |> JSON.decode!()

    manifest =
      @root |> Path.join(".release-please-manifest.json") |> File.read!() |> JSON.decode!()

    assert config["packages"]["."]["extra-files"] == ["README.md", "lib/gen_agent.ex"]

    for {path, version} <- manifest do
      package = if path == ".", do: "gen_agent", else: "gen_agent_#{Path.basename(path)}"
      readme = File.read!(Path.join([@root, path, "README.md"]))
      expected = ~s({:#{package}, "~> #{version}"})

      assert readme =~ expected
      assert length(Regex.scan(~r/x-release-please-version/, readme)) == 1

      assert Enum.any?(String.split(readme, "\n"), fn line ->
               String.contains?(line, expected) and
                 String.contains?(line, "x-release-please-version")
             end)

      if path == "." do
        moduledoc = File.read!(Path.join(@root, "lib/gen_agent.ex"))
        assert moduledoc =~ expected
        assert length(Regex.scan(~r/x-release-please-version/, moduledoc)) == 1

        assert Enum.any?(String.split(moduledoc, "\n"), fn line ->
                 String.contains?(line, expected) and
                   String.contains?(line, "x-release-please-version")
               end)

        refute readme =~ ~r/\{:gen_agent_(?:claude|codex|anthropic|openai), "~>/
        refute moduledoc =~ ~r/\{:gen_agent_(?:claude|codex|anthropic|openai), "~>/
      else
        assert config["packages"][path]["extra-files"] == ["README.md"]
        refute readme =~ ~r/\{:gen_agent, "~>/
      end
    end
  end

  test "consumer check uses exact manifest versions only in post-publish mode" do
    manifest =
      @root |> Path.join(".release-please-manifest.json") |> File.read!() |> JSON.decode!()

    {output, 0} =
      System.cmd("bash", [
        Path.join(@root, "scripts/consumer-check.sh"),
        "--manifest",
        "--print-requirements"
      ])

    lines = String.split(output, "\n", trim: true)
    assert length(lines) == map_size(manifest)

    for {path, version} <- manifest do
      package = if path == ".", do: "gen_agent", else: "gen_agent_#{Path.basename(path)}"
      assert Enum.any?(lines, &String.contains?(&1, ~s({:#{package}, "== #{version}"})))
    end
  end

  test "CI consumer mode queries published Hex versions instead of manifest versions" do
    stub_dir =
      Path.join(System.tmp_dir!(), "consumer-check-curl-#{System.unique_integer([:positive])}")

    File.mkdir_p!(stub_dir)
    on_exit(fn -> File.rm_rf!(stub_dir) end)

    File.write!(Path.join(stub_dir, "curl"), """
    #!/usr/bin/env bash
    printf '%s\\n' "${!#}" >> "$CONSUMER_CURL_LOG"
    printf '{"latest_stable_version":"9.9.9"}\\n'
    """)

    File.chmod!(Path.join(stub_dir, "curl"), 0o755)
    log = Path.join(stub_dir, "requests")

    {output, 0} =
      System.cmd("bash", [Path.join(@root, "scripts/consumer-check.sh"), "--print-requirements"],
        env: [
          {"PATH", "#{stub_dir}:#{System.fetch_env!("PATH")}"},
          {"CONSUMER_CURL_LOG", log}
        ]
      )

    lines = String.split(output, "\n", trim: true)
    assert length(lines) == 6
    assert Enum.all?(lines, &String.contains?(&1, "== 9.9.9"))

    requests = File.read!(log)
    assert length(String.split(requests, "\n", trim: true)) == 6
    assert requests =~ "https://hex.pm/api/packages/gen_agent_claude"
  end

  test "release guide covers Hex lock refresh and changelogs have no empty tail" do
    guide = File.read!(Path.join(@root, "RELEASING.md"))
    assert guide =~ "GEN_AGENT_HEX=1 mix deps.update gen_agent"
    assert guide =~ "scripts/publish-package.sh"

    for path <- [
          "integrations/claude",
          "integrations/codex",
          "integrations/anthropic",
          "integrations/openai",
          "extensions/ensemble"
        ] do
      changelog = File.read!(Path.join([@root, path, "CHANGELOG.md"]))
      assert String.starts_with?(changelog, "# Changelog\n")
      refute Regex.match?(~r/^## Changelog$/m, changelog)
      refute changelog =~ "compare/v0.1.0...v0.1.0"
      assert changelog =~ "releases/tag/v0.1.0"
    end
  end

  defp index!(text, needle) do
    {index, _length} = :binary.match(text, needle)
    index
  end

  defp job_block(workflow, name) do
    [_, body] = String.split(workflow, "  #{name}:\n", parts: 2)
    body |> String.split(~r/\n  [a-z][a-z-]*:\n/, parts: 2) |> hd()
  end
end
