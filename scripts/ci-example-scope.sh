#!/usr/bin/env bash
set -euo pipefail

# Keep required CI checks present. Only example jobs can skip on a PR that
# changes documentation alone; a failed diff or unknown path runs them.
if [[ "${1:-}" == "--classify-paths" ]]; then
  changed_paths="$(cat)"
elif [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" ||
        -z "${PR_BASE_SHA:-}" || -z "${PR_HEAD_SHA:-}" ]]; then
  changed_paths="*"
elif ! changed_paths="$(git diff --name-only "${PR_BASE_SHA}" "${PR_HEAD_SHA}" --)"; then
  changed_paths="*"
fi

run_examples=false
if [[ -z "${changed_paths}" ]]; then
  run_examples=true
else
  while IFS= read -r path; do
    case "${path}" in
      README.md|CHANGELOG.md|RELEASING.md|MIGRATION.md|LICENSE|design/*|guides/*|docs/*|integrations/*/README.md|integrations/*/CHANGELOG.md|extensions/*/README.md|extensions/*/CHANGELOG.md) ;;
      *) run_examples=true; break ;;
    esac
  done <<< "${changed_paths}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "run_examples=${run_examples}" >> "${GITHUB_OUTPUT}"
else
  echo "run_examples=${run_examples}"
fi
