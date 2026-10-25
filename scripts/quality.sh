#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages=(. integrations/claude integrations/codex integrations/anthropic integrations/openai extensions/ensemble integrations/structured extensions/delegation)

if [[ "$#" -gt 0 ]]; then
  packages=("$@")
  for package in "${packages[@]}"; do
    case "${package}" in
      .|integrations/claude|integrations/codex|integrations/anthropic|integrations/openai|extensions/ensemble|integrations/structured|extensions/delegation) ;;
      *) echo "Unknown package path: ${package}" >&2; exit 1 ;;
    esac
  done
fi

for package in "${packages[@]}"; do
  echo "Checking ${package}"
  (
    cd "${root}/${package}"
    unset GEN_AGENT_HEX
    case "${package}" in
      integrations/structured|extensions/delegation)
        mix deps.get --check-locked
        # Source-only packages do not declare Credo, ExDoc or Dialyxir.
        # Their package contracts are local validation/export, not Hex archives.
        mix deps.unlock --check-unused
        mix hex.audit
        mix compile --warnings-as-errors
        mix format --check-formatted
        mix test
        if [[ "${package}" == "integrations/structured" ]]; then
          mix run examples/check_profiles.exs
        else
          # Resolve the temporary parent physically: exporter rejects symlinks.
          temp_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
          export_root="$(mktemp -d "${temp_parent}/gen-agent-delegate-quality.XXXXXX")"
          trap 'rm -rf -- "${export_root}"' EXIT
          MIX_ENV=prod mix gen_agent.plugin.build --output "${export_root}/plugin"
        fi
        exit 0
        ;;
    esac
    mix deps.get
    mix deps.unlock --check-unused
    mix hex.audit
    mix compile --warnings-as-errors
    mix format --check-formatted
    mix credo --strict
    mix test
    mix docs --warnings-as-errors
    mix dialyzer
  )
done
