#!/usr/bin/env bash
set -euo pipefail

consumer_dir="$(mktemp -d)"
trap 'rm -rf "${consumer_dir}"' EXIT

cat > "${consumer_dir}/mix.exs" <<'EOF'
defmodule GenAgentConsumerCheck.MixProject do
  use Mix.Project

  def project do
    [
      app: :gen_agent_consumer_check,
      version: "0.0.0",
      elixir: "~> 1.19",
      deps: [
        {:gen_agent, "~> 0.6.1"},
        {:gen_agent_claude, "~> 0.2.0"},
        {:gen_agent_codex, "~> 0.4.0"},
        {:gen_agent_anthropic, "~> 0.3.0"},
        {:gen_agent_openai, "~> 0.3.0"},
        {:gen_agent_ensemble, "~> 0.3.0"}
      ]
    ]
  end
end
EOF

(
  cd "${consumer_dir}"
  mix deps.get
  mix run --no-start --no-compile -e '
    expected = [
      gen_agent: "~> 0.6.1",
      gen_agent_claude: "~> 0.2.0",
      gen_agent_codex: "~> 0.4.0",
      gen_agent_anthropic: "~> 0.3.0",
      gen_agent_openai: "~> 0.3.0",
      gen_agent_ensemble: "~> 0.3.0"
    ]

    lock = Mix.Dep.Lock.read()

    Enum.each(expected, fn {app, requirement} ->
      case Map.get(lock, app) do
        {:hex, _, version, _, _, _, _, _} ->
          unless Version.match?(version, requirement),
            do: raise("expected #{app} #{requirement}, resolved #{version}")

          IO.puts("#{app}: #{version}")

        other ->
          raise "expected #{app} #{requirement}, resolved #{inspect(other)}"
      end
    end)
  '
  mix compile --warnings-as-errors
  mix run --no-start -e 'Enum.each([GenAgent, GenAgent.Backends.Claude, GenAgent.Backends.Codex, GenAgent.Backends.Anthropic, GenAgent.Backends.OpenAI, GenAgentEnsemble], fn module -> unless Code.ensure_loaded?(module), do: raise("missing #{inspect(module)}") end)'
)
