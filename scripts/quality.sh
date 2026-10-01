#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages=(. integrations/claude integrations/codex integrations/anthropic integrations/openai extensions/ensemble)

for package in "${packages[@]}"; do
  echo "Checking ${package}"
  (
    cd "${root}/${package}"
    unset GEN_AGENT_HEX
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
