defmodule GenAgent.Delegation.LauncherTest do
  use ExUnit.Case, async: true
  alias GenAgent.Delegation.PluginPackage

  test "exported entrypoints isolate parent release settings and retain caller options" do
    parent = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(parent, "delegate-launcher-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    output = Path.join(root, "export")
    mock_bin = Path.join(root, "host-bin")
    File.mkdir!(mock_bin)

    for {name, body} <- [
          {"uname", ~s(case "$1" in -s\) echo Darwin;; -m\) echo arm64;; esac)},
          {"sw_vers", "echo 27.0"},
          {"lockf", "exit 0"}
        ] do
      executable!(Path.join(mock_bin, name), "#!/bin/sh\n" <> body <> "\n")
    end

    variables = ~w(RELEASE_NAME RELEASE_VSN RELEASE_COOKIE RELEASE_NODE RELEASE_TMP
      RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS RELEASE_SYS_CONFIG RELEASE_MODE
      RELEASE_BOOT_SCRIPT RELEASE_BOOT_SCRIPT_CLEAN RELEASE_PROG RELEASE_COMMAND
      RELEASE_ROOT BINDIR ROOTDIR ERL_ROOTDIR)

    modules = Path.join(output, "runtime/lib/crypto-fixture/priv/lib/ossl-modules")

    builder = fn runtime ->
      File.mkdir_p!(Path.join(runtime, "bin"))
      File.mkdir_p!(Path.join(runtime, "lib/crypto-fixture/priv/lib/ossl-modules"))

      executable!(Path.join(runtime, "bin/delegation_spike"), """
      #!/bin/sh
      set -eu
      for variable in #{Enum.join(variables, " ")} ; do
        if printenv "$variable" >/dev/null; then
          echo "inherited $variable" >&2
          exit 9
        fi
      done
      [ "$RELEASE_DISTRIBUTION" = none ]
      [ "$GEN_AGENT_STATE_DIR" = caller-state ]
      [ "$GEN_AGENT_MAX_RUNNING" = 2 ]
      [ "$ANTHROPIC_API_KEY" = fixture-credential ]
      [ "$OPENSSL_MODULES" = '#{modules}' ]
      [ "$GEN_AGENT_DELEGATE_BOOT_OPENSSL_MODULES_VALUE" = caller-modules ]
      [ "$GEN_AGENT_DELEGATE_BOOT_OPENSSL_MODULES_WAS_SET" = 1 ]
      [ "$1" = eval ]
      case "$2" in *System.delete_env*OPENSSL_MODULES*) ;; *) exit 10;; esac
      echo '{"launcher":"ok"}'
      """)

      :ok
    end

    PluginPackage.export!(output, builder: builder)

    env =
      Enum.map(variables, &{&1, "/parent-release/poison"}) ++
        [
          {"RELEASE_DISTRIBUTION", "name"},
          {"PATH", mock_bin <> ":" <> System.fetch_env!("PATH")},
          {"GEN_AGENT_STATE_DIR", "caller-state"},
          {"GEN_AGENT_MAX_RUNNING", "2"},
          {"ANTHROPIC_API_KEY", "fixture-credential"},
          {"OPENSSL_MODULES", "caller-modules"}
        ]

    for launcher <- ["gen-agent-delegate", "check-install"] do
      assert {report, 0} =
               System.cmd("sh", [Path.join(output, "bin/" <> launcher)],
                 env: env,
                 cd: root,
                 stderr_to_stdout: true
               )

      assert Jason.decode!(report) == %{"launcher" => "ok"}
    end
  end

  defp executable!(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end
end
