#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages=(. integrations/claude integrations/codex integrations/anthropic integrations/openai extensions/ensemble)

core_version="$(sed -n 's/^[[:space:]]*@version "\([^"]*\)"/\1/p' "${root}/mix.exs" | head -1)"
if [[ -z "${core_version}" ]]; then
  echo "Missing root core version" >&2
  exit 1
fi

# Only gate siblings against the current core once it is available on Hex.
# Bound the lookup and distinguish an unpublished version from a Hex outage.
core_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --connect-timeout 10 --max-time 30 \
  "https://hex.pm/api/packages/gen_agent/releases/${core_version}")"
case "${core_status}" in
  200) echo "Checking siblings against published Hex core ${core_version}" ;;
  404) echo "Skipping Hex-core compile/test gate: gen_agent ${core_version} is not published on Hex; archive checks still run" ;;
  *) echo "Unable to check Hex core ${core_version}: HTTP ${core_status}" >&2; exit 1 ;;
esac

for package in "${packages[@]}"; do
  echo "Checking Hex archive: ${package}"
  (
    cd "${root}/${package}"
    export GEN_AGENT_HEX=1
    # Ensemble's backend dependencies are test-only. Exercise the sibling
    # adapters against the published core without requiring their next Hex
    # releases to have already been published.
    if [[ "${package}" == "extensions/ensemble" ]]; then
      export GEN_AGENT_BACKENDS_PATH=1
    fi
    mix deps.get
    if [[ "${package}" != "." && "${core_status}" == "200" ]]; then
      echo "Compiling and testing ${package} with Hex core ${core_version}"
      mix deps.update gen_agent
      GEN_AGENT_ROOT_VERSION="${core_version}" mix run --no-start --no-compile -e '
        expected = System.fetch_env!("GEN_AGENT_ROOT_VERSION")

        case Map.get(Mix.Dep.Lock.read(), :gen_agent) do
          {:hex, :gen_agent, ^expected, _, _, _, "hexpm", _} -> :ok
          other -> raise "expected Hex gen_agent #{expected}, resolved #{inspect(other)}"
        end
      '
      mix compile --warnings-as-errors
      mix test
    fi
    unset GEN_AGENT_BACKENDS_PATH
    mix hex.build

    app="$(sed -n 's/^[[:space:]]*app: :\([a-z_]*\),/\1/p' mix.exs | head -1)"
    version="$(sed -n 's/^[[:space:]]*@version "\([0-9.]*\)"/\1/p' mix.exs | head -1)"
    archive="${app}-${version}.tar"
    if [[ -z "${app}" || -z "${version}" || ! -f "${archive}" ]]; then
      echo "Missing archive or package identity for ${package}" >&2
      exit 1
    fi
    if ! metadata="$(tar -xOf "${archive}" metadata.config)"; then
      echo "Unable to read metadata from ${archive}" >&2
      exit 1
    fi

    if [[ "${metadata}" == *'<<"path">>'* ]]; then
      echo "Path dependency found in ${archive}" >&2
      exit 1
    fi
  )
done
