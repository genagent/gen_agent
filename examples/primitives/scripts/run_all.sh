#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
output=$(mktemp)
trap 'rm -f "$output"' EXIT

for script in scripts/*.exs; do
  mix run "$script" | tee "$output"
  expected="$(basename "$script" .exs): ok"
  if [[ "$(tail -n 1 "$output")" != "$expected" ]]; then
    echo "Missing final line: $expected" >&2
    exit 1
  fi
done
