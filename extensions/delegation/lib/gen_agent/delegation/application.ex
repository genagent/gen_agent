defmodule GenAgent.Delegation.Application do
  use Application

  def start(_type, _args) do
    children =
      case Application.fetch_env(:gen_agent_delegation, :manager_opts) do
        {:ok, opts} -> [{GenAgent.Delegation, opts}]
        :error -> []
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: GenAgent.Delegation.Supervisor
    )
  end

  def runtime_options(getenv \\ &System.get_env/1) do
    [
      default_backend: getenv.("GEN_AGENT_DEFAULT_BACKEND") || "claude",
      state_dir: state_directory(getenv),
      max_running: max_running(getenv.("GEN_AGENT_MAX_RUNNING"))
    ]
  end

  defp state_directory(getenv) do
    case getenv.("GEN_AGENT_STATE_DIR") do
      nil ->
        root = Path.expand("~/.local/state/gen-agent-delegate")

        case session_identity(getenv) do
          {source, id} ->
            # Hash caller-controlled identifiers: never interpret them as paths,
            # and keep namespaces distinct between hosts and explicit labels.
            digest = :crypto.hash(:sha256, id) |> Base.encode16(case: :lower)
            Path.join([root, "sessions", source <> "-" <> digest])

          nil ->
            # Hosts need not supply an identity. A fresh launch must still be
            # able to coexist with other stdio servers without adopting their data.
            token = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
            Path.join([root, "launches", token])
        end

      directory ->
        directory
    end
  end

  defp session_identity(getenv) do
    Enum.find_value(
      [{"explicit", "GEN_AGENT_SESSION_ID"}, {"codex", "CODEX_THREAD_ID"}],
      fn {source, key} ->
        case getenv.(key) do
          value when is_binary(value) and byte_size(value) > 0 -> {source, value}
          _ -> nil
        end
      end
    )
  end

  defp max_running(nil), do: 3

  defp max_running(value) do
    if is_binary(value) and Regex.match?(~r/\A[0-9]+\z/, value) do
      case Integer.parse(value) do
        {capacity, ""} when capacity in 1..32 -> capacity
        _ -> invalid_max_running!(value)
      end
    else
      invalid_max_running!(value)
    end
  end

  defp invalid_max_running!(value) do
    raise ArgumentError,
          "GEN_AGENT_MAX_RUNNING must be a decimal integer from 1 to 32; got #{inspect(value)}. " <>
            "Set it to a value such as 5 or unset it to use the default of 3."
  end
end
