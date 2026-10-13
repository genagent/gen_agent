defmodule GenAgentEnsemble.PackagingTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  test "production loads the complete config without repository example ensembles" do
    config = Config.Reader.read!(Path.join([@root, "config", "config.exs"]), env: :prod)
    assert get_in(config, [:gen_agent_ensemble, :ensembles]) == []
  end

  test "evaluated package metadata excludes config and includes documentation artifacts" do
    project = Mix.Project.config()
    files = project[:package][:files]
    refute "config" in files

    for file <- ["CHANGELOG.md", "LICENSE"] do
      assert file in files
      assert file in project[:docs][:extras]
      assert File.regular?(Path.join(@root, file))
    end

    for strategy <- ~w(Solo Switchboard Pool Pipeline Supervisor Debate Consensus) do
      assert project[:description] =~ strategy
    end
  end
end
