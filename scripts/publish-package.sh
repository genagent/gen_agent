#!/usr/bin/env bash
set -euo pipefail

package="${1:?Pass a package path}"
phase="${2:?Pass prepare or publish}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${package}" in
  .|integrations/claude|integrations/codex|integrations/anthropic|integrations/openai|extensions/ensemble) ;;
  *) echo "Unknown package path: ${package}" >&2; exit 1 ;;
esac
case "${phase}" in
  prepare|publish) ;;
  *) echo "Unknown publishing phase: ${phase}" >&2; exit 1 ;;
esac

cd "${root}/${package}"
if [[ "${package}" != "." ]]; then export GEN_AGENT_HEX=1; fi
if [[ "${phase}" == "publish" ]]; then
  : "${HEX_API_KEY:?HEX_API_KEY is required to publish}"
  mix hex.publish --yes
  exit
fi

if [[ -n "${HEX_API_KEY:-}" ]]; then
  echo 'HEX_API_KEY must not be available during package preparation' >&2
  exit 1
fi

if [[ "${package}" != "." ]]; then
  # A release may follow a freshly published core version while the checked-in
  # integration lockfile still points to the previous one. Test against the
  # newest compatible core before publishing the integration.
  mix deps.update gen_agent
fi

app="$(sed -n 's/^[[:space:]]*app: :\([a-z_]*\),/\1/p' mix.exs | head -1)"
version="$(sed -n 's/^[[:space:]]*@version "\([0-9.]*\)"/\1/p' mix.exs | head -1)"
if [[ -z "${app}" || -z "${version}" ]]; then
  echo "Missing package identity for ${package}" >&2
  exit 1
fi

if curl --fail --silent --output /dev/null "https://hex.pm/api/packages/${app}/releases/${version}"; then
  echo "${app} ${version} is already on Hex"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo 'already_published=true' >> "${GITHUB_OUTPUT}"; fi
  exit 0
fi

mix deps.get
mix hex.audit
mix compile --warnings-as-errors
mix test
mix docs --warnings-as-errors
mix hex.build
if tar -xOf "${app}-${version}.tar" metadata.config | grep -q '<<"path">>'; then
  echo "Path dependency found in ${app}-${version}.tar" >&2
  exit 1
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo 'already_published=false' >> "${GITHUB_OUTPUT}"; fi
