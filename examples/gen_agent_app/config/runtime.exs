import Config

providers =
  System.get_env("GEN_AGENT_APP_PROVIDERS", "echo")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)

cwd = System.get_env("GEN_AGENT_APP_CWD", File.cwd!())

backends = %{
  "echo" => GenAgentEnsemble.Backends.Echo,
  "claude" => GenAgent.Backends.Claude,
  "codex" => GenAgent.Backends.Codex
}

agents =
  for provider <- providers do
    backend =
      case Map.fetch(backends, provider) do
        {:ok, module} -> module
        :error -> raise ArgumentError, "unknown GEN_AGENT_APP_PROVIDERS value: #{provider}"
      end

    {provider, GenAgentEnsemble.Agents.Simple, [backend: backend, cwd: cwd]}
  end

config :gen_agent_app,
  session_name: "workbench",
  agents: agents
