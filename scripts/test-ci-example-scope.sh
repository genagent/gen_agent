#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
classifier="${root}/scripts/ci-example-scope.sh"

[[ "$(printf 'README.md\nguides/patterns/research.md\nintegrations/openai/CHANGELOG.md\n' | bash "${classifier}" --classify-paths)" == 'run_examples=false' ]]
[[ "$(printf 'README.md\nlib/gen_agent.ex\n' | bash "${classifier}" --classify-paths)" == 'run_examples=true' ]]
[[ "$(printf '.github/workflows/ci.yml\n' | bash "${classifier}" --classify-paths)" == 'run_examples=true' ]]
[[ "$(printf '' | bash "${classifier}" --classify-paths)" == 'run_examples=true' ]]
