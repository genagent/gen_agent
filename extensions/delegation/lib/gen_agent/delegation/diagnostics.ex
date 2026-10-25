defmodule GenAgent.Delegation.Diagnostics do
  @moduledoc """
  Read-only executable, version, and authentication checks for this launch context.

  `check/1` accepts an optional `"backend"` (`"claude"` or `"codex"`). Omitting
  it checks both. Readiness means a recognized version and authenticated CLI;
  it does not establish network access, model availability, or task success.

  Probes share a 10-second execution budget. Each subprocess uses Forcola's
  bounded pull delivery with a 64 KiB cumulative output limit, a 64 KiB line
  limit, and 250 ms termination grace. Cleanup is awaited, including Forcola's
  additional bounded confirmation window; this can extend the execution budget.
  No model requests, login attempts, or configuration changes are made.

  Raw output, exception details, and credential values are never returned.
  `check/2` accepts `:runner`, `:find_executable`, and `:get_env` functions for
  isolated tests; these are internal injection points, not MCP arguments.
  """

  alias Forcola.Duplex

  @probe_budget_ms 10_000
  @output_limit 64 * 1024
  @kill_grace_ms 250
  @auth_vars ~w(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY CODEX_API_KEY)
  @version_token "[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}(?:-(?:alpha|beta|rc)\\.[0-9]{1,6})?"
  @versions %{
    "claude" => Regex.compile!("\\A(" <> @version_token <> ") \\(Claude Code\\)\\z"),
    "codex" => Regex.compile!("\\Acodex-cli (" <> @version_token <> ")\\z")
  }

  @spec check(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def check(args, opts \\ []) do
    with {:ok, backends} <- backends(args) do
      resolver = Keyword.get(opts, :find_executable, &System.find_executable/1)
      runner = Keyword.get(opts, :runner, &run_probe/2)
      get_env = Keyword.get(opts, :get_env, &System.get_env/1)
      deadline = System.monotonic_time(:millisecond) + @probe_budget_ms
      providers = Enum.map(backends, &check_provider(&1, resolver, runner, deadline))

      {:ok,
       %{
         "environment" => environment(get_env),
         "providers" => providers,
         "ready" => Enum.all?(providers, & &1["ready"]),
         "hints" => [
           "Status-only checks describe this launch context; they do not prove network access, model availability, or task success.",
           "Sandbox environment markers are inherited hints, not proof of the effective sandbox or network policy."
         ]
       }}
    end
  end

  defp backends(args) when is_map(args) and not is_struct(args) do
    if Map.keys(args) -- ["backend"] == [] do
      case Map.fetch(args, "backend") do
        :error -> {:ok, ["claude", "codex"]}
        {:ok, backend} when backend in ["claude", "codex"] -> {:ok, [backend]}
        _ -> invalid_arguments()
      end
    else
      invalid_arguments()
    end
  end

  defp backends(_args), do: invalid_arguments()

  defp invalid_arguments do
    {:error,
     %{
       code: "invalid_arguments",
       message: "Expected an object with only an optional backend: claude or codex."
     }}
  end

  defp environment(get_env) do
    %{
      "home" => safe_path(get_env.("HOME")),
      "claude_config_dir" => safe_path(get_env.("CLAUDE_CONFIG_DIR")),
      "codex_home" => safe_path(get_env.("CODEX_HOME")),
      "codex_sandbox_present" => not is_nil(get_env.("CODEX_SANDBOX")),
      "network_disabled_marker" => network_marker(get_env.("CODEX_SANDBOX_NETWORK_DISABLED")),
      "auth_env_present" => Map.new(@auth_vars, &{&1, not is_nil(get_env.(&1))})
    }
  end

  defp network_marker(nil), do: "absent"
  defp network_marker(value) when value in ["1", "true", "yes"], do: "true"
  defp network_marker(value) when value in ["0", "false", "no"], do: "false"
  defp network_marker(_value), do: "unknown"

  defp check_provider(backend, resolver, runner, deadline) do
    executable = resolve_executable(resolver, backend)

    report = %{
      "backend" => backend,
      "executable" => executable,
      "version" => nil,
      "authentication" => "unknown",
      "ready" => false,
      "hints" => []
    }

    if is_nil(executable) do
      %{
        report
        | "hints" => [
            "CLI executable could not be resolved in this launch context. Check the plugin host's PATH."
          ]
      }
    else
      {version, version_hints} =
        version(backend, probe(runner, [executable, "--version"], deadline))

      auth_args =
        case backend do
          "claude" -> [executable, "auth", "status", "--json"]
          "codex" -> [executable, "login", "status"]
        end

      {authentication, auth_hints} = authentication(backend, probe(runner, auth_args, deadline))

      %{
        report
        | "version" => version,
          "authentication" => authentication,
          "ready" => not is_nil(version) and authentication == "authenticated",
          "hints" => version_hints ++ auth_hints ++ authentication_hints(authentication)
      }
    end
  end

  defp resolve_executable(resolver, backend) do
    safe_path(resolver.(backend))
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp safe_path(value) when is_binary(value) and byte_size(value) in 1..4096 do
    if String.valid?(value) and not String.contains?(value, <<0>>), do: value
  end

  defp safe_path(_value), do: nil

  defp probe(runner, argv, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      runner.(argv,
        timeout_ms: remaining,
        max_output_bytes: @output_limit,
        max_line_bytes: @output_limit,
        max_pending_bytes: @output_limit + 1,
        kill_grace_ms: @kill_grace_ms
      )
      |> normalize_probe()
    else
      {:error, :budget_exhausted}
    end
  rescue
    _ -> {:error, :failed}
  catch
    _, _ -> {:error, :failed}
  end

  defp normalize_probe({:ok, %{status: status, stdout: stdout, stderr: stderr}})
       when is_integer(status) and is_binary(stdout) and is_binary(stderr) do
    cond do
      byte_size(stdout) + byte_size(stderr) > @output_limit -> {:error, :output_limit}
      not String.valid?(stdout) or not String.valid?(stderr) -> {:error, :failed}
      true -> {:ok, %{status: status, stdout: stdout, stderr: stderr}}
    end
  end

  defp normalize_probe({:error, reason})
       when reason in [:timeout, :output_limit, :cleanup_unconfirmed, :launch, :failed],
       do: {:error, reason}

  defp normalize_probe(_other), do: {:error, :failed}

  defp version(backend, {:ok, %{status: 0, stdout: stdout}}) do
    case Regex.run(Map.fetch!(@versions, backend), String.trim(stdout), capture: :all_but_first) do
      [version] -> {version, []}
      _ -> {nil, ["CLI version output was not recognized; raw output is withheld."]}
    end
  end

  defp version(_backend, {:ok, _result}),
    do: {nil, ["CLI version probe exited unsuccessfully; raw output is withheld."]}

  defp version(_backend, {:error, reason}), do: {nil, [failure_hint("CLI version", reason)]}

  defp authentication("claude", {:ok, %{status: status, stdout: stdout}}) do
    auth =
      case Jason.decode(stdout) do
        {:ok, %{"loggedIn" => true}} when status == 0 -> "authenticated"
        {:ok, %{"loggedIn" => false}} -> "unavailable"
        _ -> "unknown"
      end

    {auth, []}
  end

  defp authentication("codex", {:ok, %{status: status, stdout: stdout, stderr: stderr}}) do
    lines = String.split(stdout <> "\n" <> stderr, "\n") |> Enum.map(&String.trim/1)
    logged_in = Enum.any?(lines, &(&1 == "Logged in" or String.starts_with?(&1, "Logged in ")))

    logged_out =
      Enum.any?(lines, &(&1 == "Not logged in" or String.starts_with?(&1, "Not logged in ")))

    auth =
      case {logged_in, logged_out, status} do
        {true, false, 0} -> "authenticated"
        {false, true, _} -> "unavailable"
        _ -> "unknown"
      end

    {auth, []}
  end

  defp authentication(_backend, {:error, reason}),
    do: {"unknown", [failure_hint("Authentication status", reason)]}

  defp authentication_hints("authenticated"), do: []

  defp authentication_hints("unavailable"),
    do: [
      "The CLI reports authentication unavailable in this launch context. Compare the plugin host and terminal environments before deciding that login is required."
    ]

  defp authentication_hints("unknown"),
    do: [
      "The probe could not establish authentication. An unknown result is not evidence that credentials are missing; host or macOS Keychain access may differ."
    ]

  defp failure_hint(probe, reason) do
    description =
      case reason do
        :timeout -> "timed out; process-group cleanup was confirmed"
        :output_limit -> "exceeded the 64 KiB output limit"
        :cleanup_unconfirmed -> "could not confirm process-group cleanup"
        :launch -> "could not launch the CLI"
        :budget_exhausted -> "was skipped because the shared 10-second probe budget expired"
        _ -> "failed without a recognized status"
      end

    "#{probe} probe #{description}; raw output is withheld."
  end

  defp run_probe(argv, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :timeout_ms)
    duplex_opts = opts |> Keyword.delete(:timeout_ms) |> Keyword.put(:delivery, :pull)

    case Duplex.open(argv, duplex_opts) do
      {:ok, session} ->
        try do
          Duplex.send_eof(session)
          collect(session, deadline, %{stdout: [], stderr: [], bytes: 0})
        after
          Duplex.close(session)
        end

      {:error, _reason} ->
        {:error, :launch}
    end
  end

  defp collect(session, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      stop_probe(session, :timeout)
    else
      case Duplex.recv(session, remaining) do
        {:ok, {stream, line}} when stream in [:stdout, :stderr] ->
          bytes = acc.bytes + byte_size(line) + 1

          if bytes > @output_limit do
            stop_probe(session, :output_limit)
          else
            acc = acc |> Map.update!(stream, &[[line, "\n"] | &1]) |> Map.put(:bytes, bytes)
            collect(session, deadline, acc)
          end

        {:done, %{status: status, confirmation: :confirmed, output: :complete}}
        when is_integer(status) ->
          {:ok,
           %{
             status: status,
             stdout: acc.stdout |> Enum.reverse() |> IO.iodata_to_binary(),
             stderr: acc.stderr |> Enum.reverse() |> IO.iodata_to_binary()
           }}

        {:done, %{output: {:limit, _, _, _}} = terminal} ->
          terminal_failure(terminal, :output_limit)

        {:error, {:output_limit, terminal}} ->
          terminal_failure(terminal, :output_limit)

        {:done, terminal} ->
          terminal_failure(terminal, :failed)

        {:error, :timeout} ->
          stop_probe(session, :timeout)

        _ ->
          stop_probe(session, :failed)
      end
    end
  end

  defp stop_probe(session, reason) do
    case Duplex.shutdown(session) do
      {:ok, terminal} -> terminal_failure(terminal, reason)
      _ -> {:error, :cleanup_unconfirmed}
    end
  end

  defp terminal_failure(%{confirmation: :confirmed}, reason), do: {:error, reason}
  defp terminal_failure(%{confirmation: :not_started}, _reason), do: {:error, :launch}
  defp terminal_failure(_terminal, _reason), do: {:error, :cleanup_unconfirmed}
end
