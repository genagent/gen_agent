defmodule GenAgent.Delegation.OptionsTest do
  use ExUnit.Case, async: true
  alias GenAgent.Delegation.Options

  test "capability brief matches Claude read and write tool restrictions" do
    for access <- ~w(read_only workspace_write) do
      spec = %{
        "backend" => "claude",
        "access" => access,
        "cwd" => File.cwd!(),
        "task" => "Inspect."
      }

      opts = Options.backend_opts(spec)
      prompt = Options.task_prompt(spec)
      assert prompt =~ "Claude tools: #{Enum.join(opts[:tools], ", ")}."
      assert opts[:tools] == opts[:allowed_tools]
      assert opts[:strict_mcp_config]
      assert opts[:mcp_config] == ~s({"mcpServers":{}})
      assert prompt =~ "Bash/shell and MCP tools are disabled"
      assert prompt =~ "not an OS filesystem sandbox"
    end
  end

  test "Codex brief permits source inspection while retaining its configured sandbox and approvals" do
    for access <- ~w(read_only workspace_write) do
      spec = %{
        "backend" => "codex",
        "access" => access,
        "cwd" => File.cwd!(),
        "task" => "Inspect."
      }

      opts = Options.backend_opts(spec)
      prompt = Options.task_prompt(spec)
      assert prompt =~ "shell commands such as rg, sed, and git diff"
      assert prompt =~ "#{opts[:sandbox]} sandbox"
      assert opts[:ignore_user_config]
      assert opts[:approval_policy] == :never
      assert prompt =~ "do not\noverride narrower restrictions"
      assert String.ends_with?(prompt, "Inspect.")
    end
  end

  test "Codex accepts a non-Git cwd while retaining restrictions for both access modes" do
    cwd = Path.join(System.tmp_dir!(), "delegation-options-#{System.unique_integer([:positive])}")
    File.mkdir!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    refute File.exists?(Path.join(cwd, ".git"))

    for {access, sandbox} <- [{"read_only", :read_only}, {"workspace_write", :workspace_write}] do
      assert {:ok, spec} =
               Options.spawn(%{
                 "backend" => "codex",
                 "access" => access,
                 "cwd" => cwd,
                 "task" => "Inspect."
               })

      opts = Options.backend_opts(spec)
      assert opts[:working_dir] == cwd
      assert opts[:skip_git_repo_check] == true
      assert opts[:sandbox] == sandbox
      assert opts[:approval_policy] == :never
      assert opts[:ignore_user_config] == true
    end
  end

  test "test-only Echo prompts remain unchanged" do
    assert Options.task_prompt(%{"backend" => "echo", "task" => "echo me"}) == "echo me"
  end
end
