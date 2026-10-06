defmodule GenAgent.ReleaseWorkflowTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

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

  defp index!(text, needle) do
    {index, _length} = :binary.match(text, needle)
    index
  end

  defp job_block(workflow, name) do
    [_, body] = String.split(workflow, "  #{name}:\n", parts: 2)
    body |> String.split(~r/\n  [a-z][a-z-]*:\n/, parts: 2) |> hd()
  end
end
