#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deps_lines="$(jq -er '
  to_entries
  | map("        {:" + (if .key == "." then "gen_agent" else "gen_agent_" + (.key | split("/")[-1]) end) + ", \"~> " + .value + "\"},")
  | join("\n")
' "${root}/.release-please-manifest.json")"

if [[ "${1:-}" == "--print-requirements" && "$#" -eq 1 ]]; then
  printf '%s\n' "${deps_lines}"
  exit 0
elif [[ "$#" -ne 0 ]]; then
  echo "Usage: $0 [--print-requirements]" >&2
  exit 2
fi

consumer_dir="$(mktemp -d)"
trap 'rm -rf "${consumer_dir}"' EXIT

cat > "${consumer_dir}/mix.exs" <<EOF
defmodule GenAgentConsumerCheck.MixProject do
  use Mix.Project

  def project do
    [
      app: :gen_agent_consumer_check,
      version: "0.0.0",
      elixir: "~> 1.19",
      deps: [
${deps_lines}
      ]
    ]
  end
end
EOF

(
  cd "${consumer_dir}"
  mix deps.get
  mix run --no-start --no-compile -e '
    lock = Mix.Dep.Lock.read()

    Enum.each(Mix.Project.config()[:deps], fn {app, requirement} ->
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
