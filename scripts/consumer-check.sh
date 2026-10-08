#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${root}/.release-please-manifest.json"
mode=published
print_requirements=false

if [[ "${1:-}" == "--manifest" ]]; then
  mode=manifest
  shift
fi
if [[ "${1:-}" == "--print-requirements" ]]; then
  print_requirements=true
  shift
fi
if [[ "$#" -ne 0 ]]; then
  echo "Usage: $0 [--manifest] [--print-requirements]" >&2
  exit 2
fi

entries="$(jq -er 'to_entries | map([.key, .value] | @tsv) | join("\n")' "${manifest}")"
deps_lines=""
while IFS=$'\t' read -r path manifest_version; do
  if [[ "${path}" == "." ]]; then
    package=gen_agent
  else
    package="gen_agent_${path##*/}"
  fi

  if [[ "${mode}" == "manifest" ]]; then
    version="${manifest_version}"
  else
    package_json="$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
      "https://hex.pm/api/packages/${package}")"
    version="$(jq -er '(.latest_stable_version // .latest_version) |
      select(type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$"))' \
      <<< "${package_json}")"
  fi

  deps_lines+="        {:${package}, \"== ${version}\"},"$'\n'
done <<< "${entries}"

if [[ "${print_requirements}" == true ]]; then
  printf '%s' "${deps_lines}"
  exit 0
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

    Enum.each(Mix.Project.config()[:deps], fn {app, "== " <> expected} ->
      case Map.get(lock, app) do
        {:hex, _, version, _, _, _, _, _} ->
          unless version == expected,
            do: raise("expected #{app} #{expected}, resolved #{version}")

          IO.puts("#{app}: #{version}")

        other ->
          raise "expected #{app} #{expected}, resolved #{inspect(other)}"
      end
    end)
  '
  mix compile --warnings-as-errors
  mix run --no-start -e 'Enum.each([GenAgent, GenAgent.Backends.Claude, GenAgent.Backends.Codex, GenAgent.Backends.Anthropic, GenAgent.Backends.OpenAI, GenAgentEnsemble], fn module -> unless Code.ensure_loaded?(module), do: raise("missing #{inspect(module)}") end)'
)
