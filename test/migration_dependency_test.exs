defmodule GenAgent.MigrationDependencyTest do
  # Builds a local Git repository shaped like the monorepo (core at the root,
  # a sibling package under integrations/claude whose gen_agent dependency
  # switches on GEN_AGENT_HEX) and consumes it from throwaway Mix projects.
  # Everything is file:// and path based, so no network is needed.
  #
  # Limitation: the Hex branch of the real package cannot be fetched offline.
  # The fixture's GEN_AGENT_HEX=1 branch points at a local stand-in core
  # ("published" core) instead, which checks the environment switch and that
  # the sparse checkout no longer needs ../.., not the real Hex resolution.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  setup %{tmp_dir: tmp} do
    standin = Path.join(tmp, "published_core")
    write(standin, "mix.exs", core_mix("published"))
    write(standin, "lib/gen_agent.ex", core_lib("published"))

    repo = Path.join(tmp, "monorepo")
    write(repo, "mix.exs", core_mix("source"))
    write(repo, "lib/gen_agent.ex", core_lib("source"))
    write(repo, "integrations/claude/mix.exs", sibling_mix(standin))

    write(
      repo,
      "integrations/claude/lib/gen_agent_claude.ex",
      """
      defmodule GenAgentClaude do
        def core, do: GenAgent.origin()
      end
      """
    )

    git!(repo, ["init", "-q"])
    git!(repo, ["add", "."])

    git!(repo, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@example.com",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-q",
      "-m",
      "fixture"
    ])

    %{tmp: tmp, repo: repo}
  end

  test "subdir resolves core from the full checkout without GEN_AGENT_HEX", ctx do
    dir = consumer(ctx, ~s|git: "file://#{ctx.repo}", subdir: "integrations/claude"|)

    assert {_, 0} = mix(dir, ["deps.get"], [])
    assert {_, 0} = mix(dir, ["compile"], [])
    assert origin(dir, []) == "source"
  end

  test "sparse with GEN_AGENT_HEX=1 compiles against the published core", ctx do
    dir = consumer(ctx, ~s|git: "file://#{ctx.repo}", sparse: "integrations/claude"|)
    env = [{"GEN_AGENT_HEX", "1"}]

    assert {_, 0} = mix(dir, ["deps.get"], env)
    assert {_, 0} = mix(dir, ["compile"], env)
    assert origin(dir, env) == "published"
  end

  test "sparse without GEN_AGENT_HEX gets deps but fails to compile", ctx do
    dir = consumer(ctx, ~s|git: "file://#{ctx.repo}", sparse: "integrations/claude"|)

    assert {_, 0} = mix(dir, ["deps.get"], [])
    assert {out, status} = mix(dir, ["compile"], [])
    assert status != 0
    assert out =~ "gen_agent"
    refute File.exists?(Path.join([dir, "deps", "gen_agent_claude", "mix.exs"]))
  end

  test "local path dependency finds core in the checkout without GEN_AGENT_HEX", ctx do
    dir = consumer(ctx, ~s|path: "#{Path.join(ctx.repo, "integrations/claude")}"|)

    assert {_, 0} = mix(dir, ["deps.get"], [])
    assert {_, 0} = mix(dir, ["compile"], [])
    assert origin(dir, []) == "source"
  end

  defp consumer(%{tmp: tmp}, dep_opts) do
    dir = Path.join(tmp, "consumer_#{System.unique_integer([:positive])}")

    write(dir, "mix.exs", """
    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [app: :consumer, version: "0.1.0", deps: [{:gen_agent_claude, #{dep_opts}}]]
      end
    end
    """)

    write(dir, "lib/consumer.ex", "defmodule Consumer do\nend\n")
    dir
  end

  defp origin(dir, env) do
    {out, 0} = mix(dir, ["run", "-e", "IO.puts(GenAgentClaude.core())"], env)
    out |> String.split("\n", trim: true) |> List.last()
  end

  defp mix(dir, args, env) do
    # Drop GEN_AGENT_HEX inherited from the outer shell so each case is explicit.
    env = [{"GEN_AGENT_HEX", nil}, {"HEX_OFFLINE", "1"}, {"MIX_ENV", "dev"} | env]
    System.cmd("mix", args, cd: dir, env: env, stderr_to_stdout: true)
  end

  defp git!(dir, args) do
    {out, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    if status != 0, do: flunk("git #{Enum.join(args, " ")} failed: #{out}")
  end

  defp write(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp core_mix(_origin) do
    """
    defmodule GenAgent.MixProject do
      use Mix.Project

      def project, do: [app: :gen_agent, version: "0.6.2", deps: []]
    end
    """
  end

  defp core_lib(origin) do
    """
    defmodule GenAgent do
      def origin, do: "#{origin}"
    end
    """
  end

  defp sibling_mix(standin) do
    """
    defmodule GenAgentClaude.MixProject do
      use Mix.Project

      def project do
        [app: :gen_agent_claude, version: "0.2.2", deps: [gen_agent_dep()]]
      end

      defp gen_agent_dep do
        if System.get_env("GEN_AGENT_HEX") == "1" do
          {:gen_agent, path: "#{standin}"}
        else
          {:gen_agent, path: "../.."}
        end
      end
    end
    """
  end
end
