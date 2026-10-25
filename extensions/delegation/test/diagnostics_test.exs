defmodule GenAgent.Delegation.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias GenAgent.Delegation.Diagnostics

  test "checks both CLIs with bounded read-only probes and withholds credentials" do
    runner = fn argv, opts ->
      assert opts[:timeout_ms] > 0 and opts[:timeout_ms] <= 10_000
      assert opts[:max_output_bytes] == 65_536
      assert opts[:max_line_bytes] == 65_536
      assert opts[:max_pending_bytes] == 65_537
      assert opts[:kill_grace_ms] == 250

      case argv do
        ["/bin/claude", "--version"] ->
          output("2.1.3 (Claude Code)\n")

        ["/bin/codex", "--version"] ->
          output("codex-cli 0.105.0-rc.3\n")

        ["/bin/claude", "auth", "status", "--json"] ->
          output(~s({"loggedIn":true,"email":"secret@example.com","token":"secret-token"}))

        ["/bin/codex", "login", "status"] ->
          output("", 0, "Logged in using API key: secret-key\n")
      end
    end

    get_env = fn
      "HOME" -> "/fake/home"
      "OPENAI_API_KEY" -> "secret-environment-key"
      "CODEX_SANDBOX" -> "secret-marker"
      "CODEX_SANDBOX_NETWORK_DISABLED" -> "1"
      _ -> nil
    end

    assert {:ok, report} = Diagnostics.check(%{}, options(runner, get_env: get_env))
    assert report["ready"]
    assert Enum.map(report["providers"], & &1["backend"]) == ["claude", "codex"]
    assert Enum.map(report["providers"], & &1["version"]) == ["2.1.3", "0.105.0-rc.3"]
    assert Enum.all?(report["providers"], &(&1["authentication"] == "authenticated"))
    assert report["environment"]["auth_env_present"]["OPENAI_API_KEY"]
    refute report["environment"]["auth_env_present"]["ANTHROPIC_API_KEY"]
    assert report["environment"]["codex_sandbox_present"]
    assert report["environment"]["network_disabled_marker"] == "true"
    assert Snodo.JSONValue.valid?(report)
    refute Jason.encode!(report) =~ "secret"
  end

  test "backend selection and missing executable skip other probes" do
    runner = fn _, _ -> flunk("a missing executable must never be invoked") end

    assert {:ok, report} =
             Diagnostics.check(%{"backend" => "codex"},
               runner: runner,
               find_executable: fn "codex" -> nil end,
               get_env: fn _ -> nil end
             )

    assert [%{"backend" => "codex", "executable" => nil, "authentication" => "unknown"}] =
             report["providers"]

    refute report["ready"]
  end

  test "invalid arguments cannot select arbitrary executables or pass shell arguments" do
    for args <- [
          nil,
          [],
          %URI{},
          %{backend: "codex"},
          %{"backend" => nil},
          %{"backend" => "echo"},
          %{"backend" => "claude", "args" => ["login"]}
        ] do
      assert {:error, %{code: "invalid_arguments"}} = Diagnostics.check(args)
    end
  end

  test "unavailable, unknown and authenticated are distinct for both providers" do
    cases = [
      {"claude", output(~s({"loggedIn":false}), 1), "unavailable"},
      {"claude", output(~s({"loggedIn":true}), 1), "unknown"},
      {"claude", output(~s({"loggedIn":"true"})), "unknown"},
      {"claude", output("unknown output secret"), "unknown"},
      {"codex", output("", 1, "Not logged in\n"), "unavailable"},
      {"codex", output("Logged in\n", 1), "unknown"},
      {"codex", output("Logged in\nNot logged in\n"), "unknown"},
      {"codex", output("a diagnostic mentions Logged in"), "unknown"}
    ]

    for {backend, auth_result, expected} <- cases do
      runner = fn
        [_, "--version"], _ -> valid_version(backend)
        _, _ -> auth_result
      end

      assert {:ok, report} = Diagnostics.check(%{"backend" => backend}, options(runner))
      assert [provider] = report["providers"]
      assert provider["authentication"] == expected
      refute provider["ready"]
      refute Jason.encode!(report) =~ "secret"
    end
  end

  test "only strictly recognized numeric versions and known prereleases are disclosed" do
    for value <- [
          "2.1.3-secret-token (Claude Code)",
          "2.1.3 (Claude Code)\nsecret",
          "secret version",
          "2.1.3-beta.secret (Claude Code)"
        ] do
      runner = fn
        [_, "--version"], _ -> output(value)
        _, _ -> output(~s({"loggedIn":true}))
      end

      assert {:ok, %{"providers" => [provider]}} =
               Diagnostics.check(%{"backend" => "claude"}, options(runner))

      assert provider["version"] == nil
      refute provider["ready"]
      refute Jason.encode!(provider) =~ "secret"
    end
  end

  test "timeouts and output limits remain unknown and exceptions never expose raw details" do
    for failure <- [
          {:error, :timeout},
          {:error, :output_limit},
          {:error, :cleanup_unconfirmed},
          {:error, :launch},
          {:error, {:spawn, "secret error"}},
          output(String.duplicate("x", 65_537)),
          output(<<255>>)
        ] do
      runner = fn _, _ -> failure end

      assert {:ok, %{"providers" => [provider]}} =
               Diagnostics.check(%{"backend" => "claude"}, options(runner))

      assert provider["authentication"] == "unknown"
      refute provider["ready"]
      refute Jason.encode!(provider) =~ "secret"
    end

    for runner <- [
          fn _, _ -> raise "secret exception" end,
          fn _, _ -> exit("secret exit") end,
          fn _, _ -> throw("secret throw") end
        ] do
      assert {:ok, report} = Diagnostics.check(%{"backend" => "codex"}, options(runner))
      refute report["ready"]
      refute Jason.encode!(report) =~ "secret"
    end
  end

  test "oversized combined stdout and stderr is rejected before authentication parsing" do
    runner = fn
      [_, "--version"], _ ->
        valid_version("codex")

      _, _ ->
        output("Logged in\n" <> String.duplicate("x", 32_768), 0, String.duplicate("y", 32_768))
    end

    assert {:ok, %{"providers" => [provider]}} =
             Diagnostics.check(%{"backend" => "codex"}, options(runner))

    assert provider["authentication"] == "unknown"
    assert Enum.any?(provider["hints"], &String.contains?(&1, "64 KiB"))
  end

  test "invalid environment paths and arbitrary network markers remain JSON safe" do
    get_env = fn
      "HOME" -> <<255>>
      "CODEX_HOME" -> String.duplicate("x", 4097)
      "CLAUDE_CONFIG_DIR" -> "bad\0path"
      "CODEX_SANDBOX_NETWORK_DISABLED" -> "secret arbitrary marker"
      _ -> nil
    end

    assert {:ok, report} =
             Diagnostics.check(%{},
               get_env: get_env,
               find_executable: fn _ -> nil end
             )

    assert report["environment"]["home"] == nil
    assert report["environment"]["codex_home"] == nil
    assert report["environment"]["claude_config_dir"] == nil
    assert report["environment"]["network_disabled_marker"] == "unknown"
    assert Snodo.JSONValue.valid?(report)
    refute Jason.encode!(report) =~ "secret"
  end

  defp options(runner, extra \\ []) do
    Keyword.merge(
      [runner: runner, find_executable: &("/bin/" <> &1), get_env: fn _ -> nil end],
      extra
    )
  end

  defp output(stdout, status \\ 0, stderr \\ ""),
    do: {:ok, %{status: status, stdout: stdout, stderr: stderr}}

  defp valid_version("claude"), do: output("2.1.3 (Claude Code)")
  defp valid_version("codex"), do: output("codex-cli 0.105.0")
end
