#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages=(. integrations/claude integrations/codex integrations/anthropic integrations/openai extensions/ensemble)

for package in "${packages[@]}"; do
  echo "Checking Hex archive: ${package}"
  (
    cd "${root}/${package}"
    export GEN_AGENT_HEX=1
    mix deps.get
    mix hex.build

    app="$(sed -n 's/^[[:space:]]*app: :\([a-z_]*\),/\1/p' mix.exs | head -1)"
    version="$(sed -n 's/^[[:space:]]*@version "\([0-9.]*\)"/\1/p' mix.exs | head -1)"
    archive="${app}-${version}.tar"
    metadata="$(tar -xOf "${archive}" metadata.config)"

    if [[ -z "${app}" || -z "${version}" || ! -f "${archive}" ]]; then
      echo "Missing archive or package identity for ${package}" >&2
      exit 1
    fi

    if [[ "${metadata}" == *'<<"path">>'* ]]; then
      echo "Path dependency found in ${archive}" >&2
      exit 1
    fi
  )
done
