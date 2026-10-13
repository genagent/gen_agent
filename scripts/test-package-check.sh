#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

mkdir -p "${fixture}/scripts" "${fixture}/bin"
cp "${root}/scripts/package-check.sh" "${fixture}/scripts/package-check.sh"

for package in . integrations/claude integrations/codex integrations/anthropic integrations/openai extensions/ensemble; do
  mkdir -p "${fixture}/${package}"
  if [[ "${package}" == "." ]]; then app=gen_agent; else app="gen_agent_${package##*/}"; fi
  printf '  app: :%s,\n  @version "0.0.1"\n' "${app}" > "${fixture}/${package}/mix.exs"
done

cat > "${fixture}/bin/mix" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == "hex.build" ]]; then
  relative="${PWD#"${TEST_FIXTURE_ROOT}"/}"
  if [[ "${relative}" != "${SKIP_ARCHIVE_DIR:-none}" ]]; then
    if [[ "${PWD}" == "${TEST_FIXTURE_ROOT}" ]]; then app=gen_agent; else app="gen_agent_${PWD##*/}"; fi
    touch "${app}-0.0.1.tar"
  fi
fi
SH
cat > "${fixture}/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '404'
SH
cat > "${fixture}/bin/tar" <<'SH'
#!/usr/bin/env bash
relative="${PWD#"${TEST_FIXTURE_ROOT}"/}"
if [[ "${relative}" == "${TAR_FAILURE_DIR:-none}" ]]; then exit 42; fi
if [[ "${relative}" == "${TAR_PATH_DIR:-none}" ]]; then
  printf '%s\n' '<<"path">>'
else
  printf '%s\n' '<<"repository">>,<<"hexpm">>'
fi
SH
chmod +x "${fixture}/bin/"*

export PATH="${fixture}/bin:${PATH}"
export TEST_FIXTURE_ROOT="${fixture}"

output="$(bash "${fixture}/scripts/package-check.sh" 2>&1)"
[[ "${output}" == *'Checking Hex archive: extensions/ensemble'* ]]

rm -f "${fixture}/integrations/claude/gen_agent_claude-0.0.1.tar"
if output="$(SKIP_ARCHIVE_DIR=integrations/claude bash "${fixture}/scripts/package-check.sh" 2>&1)"; then
  echo 'Missing archive unexpectedly passed' >&2
  exit 1
fi
[[ "${output}" == *'Missing archive or package identity for integrations/claude'* ]]

if output="$(TAR_FAILURE_DIR=integrations/claude bash "${fixture}/scripts/package-check.sh" 2>&1)"; then
  echo 'Failed metadata extraction unexpectedly passed' >&2
  exit 1
fi
[[ "${output}" == *'Unable to read metadata from gen_agent_claude-0.0.1.tar'* ]]

if output="$(TAR_PATH_DIR=integrations/claude bash "${fixture}/scripts/package-check.sh" 2>&1)"; then
  echo 'Path dependency unexpectedly passed' >&2
  exit 1
fi
[[ "${output}" == *'Path dependency found in gen_agent_claude-0.0.1.tar'* ]]
