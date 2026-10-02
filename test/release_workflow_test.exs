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

  defp job_block(workflow, name) do
    [_, body] = String.split(workflow, "  #{name}:\n", parts: 2)
    body |> String.split(~r/\n  [a-z][a-z-]*:\n/, parts: 2) |> hd()
  end
end
