#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

mkdir -p "${fixture}/scripts" "${fixture}/bin" "${fixture}/integrations/claude"
cp "${root}/scripts/publish-package.sh" "${fixture}/scripts/publish-package.sh"
printf '  app: :gen_agent,\n  @version "0.0.1"\n' > "${fixture}/mix.exs"
printf '  app: :gen_agent_claude,\n  @version "0.0.1"\n' > "${fixture}/integrations/claude/mix.exs"

cat > "${fixture}/bin/mix" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$*" "${HEX_API_KEY-unset}" >> "${TEST_LOG}"
if [[ "$*" == "${FAIL_MIX_COMMAND:-never}" ]]; then exit 17; fi
if [[ "$*" == "hex.build" && "${BUILD_ARCHIVE:-1}" == 1 ]]; then
  if [[ "$(pwd)" == */integrations/claude ]]; then
    touch gen_agent_claude-0.0.1.tar
  else
    touch gen_agent-0.0.1.tar
  fi
fi
SH
cat > "${fixture}/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ "${CURL_STATUS:-404}" == fail ]]; then exit 7; fi
printf '%s' "${CURL_STATUS:-404}"
SH
cat > "${fixture}/bin/tar" <<'SH'
#!/usr/bin/env bash
if [[ "${TAR_FAILURE:-0}" == 1 ]]; then exit 42; fi
if [[ "${TAR_PATH:-0}" == 1 ]]; then
  printf '%s\n' '<<"path">>'
else
  printf '%s\n' '<<"repository">>,<<"hexpm">>'
fi
SH
chmod +x "${fixture}/bin/"*

export PATH="${fixture}/bin:${PATH}"
export TEST_LOG="${fixture}/commands.log"
export GITHUB_OUTPUT="${fixture}/output.log"

# Dependency work, tests, and docs run in a separate step with no key.
env -u HEX_API_KEY bash "${fixture}/scripts/publish-package.sh" integrations/claude prepare
if grep -E 'fixture-publish-key|^hex\.publish' "${TEST_LOG}"; then
  echo 'Publishing key or command reached package preparation' >&2
  exit 1
fi
grep -Eq '^deps\.update gen_agent\|unset$' "${TEST_LOG}"
grep -Eq '^test\|unset$' "${TEST_LOG}"
grep -Eq '^docs --warnings-as-errors\|unset$' "${TEST_LOG}"
grep -Eq '^already_published=false$' "${GITHUB_OUTPUT}"

# The only command in the keyed step is the publish command.
: > "${TEST_LOG}"
HEX_API_KEY=fixture-publish-key bash "${fixture}/scripts/publish-package.sh" integrations/claude publish
grep -Eq '^hex\.publish --yes\|fixture-publish-key$' "${TEST_LOG}"
[[ "$(wc -l < "${TEST_LOG}")" -eq 1 ]]

# The early "already published" exit marks the publish step to be skipped.
: > "${TEST_LOG}"
CURL_STATUS=200 env -u HEX_API_KEY bash "${fixture}/scripts/publish-package.sh" . prepare
if [[ -s "${TEST_LOG}" ]]; then
  echo 'Already-published package ran a Mix command' >&2
  exit 1
fi
grep -Eq '^already_published=true$' "${GITHUB_OUTPUT}"

# A failed preparation step cannot invoke publish or inherit the key.
: > "${TEST_LOG}"
if FAIL_MIX_COMMAND=test env -u HEX_API_KEY bash "${fixture}/scripts/publish-package.sh" . prepare; then
  echo 'Expected the preparation failure to stop publishing' >&2
  exit 1
fi

# Reject an accidental workflow change that passes the key to preparation.
: > "${TEST_LOG}"
if HEX_API_KEY=fixture-publish-key bash "${fixture}/scripts/publish-package.sh" . prepare; then
  echo 'Preparation accepted the publishing key' >&2
  exit 1
fi
[[ ! -s "${TEST_LOG}" ]]
if grep -E 'fixture-publish-key|^hex\.publish' "${TEST_LOG}"; then
  echo 'Publishing key or command reached the failed preparation path' >&2
  exit 1
fi

# Hex outages and transport failures must not be mistaken for a missing release.
for status in 500 fail; do
  : > "${TEST_LOG}"
  if CURL_STATUS="${status}" env -u HEX_API_KEY bash "${fixture}/scripts/publish-package.sh" . prepare; then
    echo "Hex lookup ${status} unexpectedly allowed preparation" >&2
    exit 1
  fi
  [[ ! -s "${TEST_LOG}" ]]
done

# A missing archive or failed metadata extraction must stop preparation.
: > "${TEST_LOG}"
if BUILD_ARCHIVE=0 env -u HEX_API_KEY bash "${fixture}/scripts/publish-package.sh" . prepare; then
  echo 'Missing archive unexpectedly allowed preparation' >&2
  exit 1
fi

: > "${TEST_LOG}"
if TAR_FAILURE=1 env -u HEX_API_KEY bash "${fixture}/scripts/publish-package.sh" . prepare; then
  echo 'Failed metadata extraction unexpectedly allowed preparation' >&2
  exit 1
fi

: > "${TEST_LOG}"
if TAR_PATH=1 env -u HEX_API_KEY bash "${fixture}/scripts/publish-package.sh" . prepare; then
  echo 'Path dependency unexpectedly allowed preparation' >&2
  exit 1
fi
