#!/usr/bin/env bash
set -euo pipefail

package="${1:?usage: scripts/minimum-core-check.sh claude|codex}"
case "${package}" in
  claude|codex) ;;
  *) echo "Unsupported package: ${package}" >&2; exit 1 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
minimum="0.6.0"
package_dir="${root}/integrations/${package}"

# Keep the release metadata honest, then force an exact lower-bound resolution
# in a copy so the test does not alter the checkout's lockfile.
grep -Fq "{:gen_agent, \"~> ${minimum} or ~> 0.7.0\"}" "${package_dir}/mix.exs"
check_dir="$(mktemp -d)"
trap 'rm -rf "${check_dir}"' EXIT
mkdir -p "${check_dir}/integrations" "${check_dir}/test"
cp -R "${package_dir}" "${check_dir}/integrations/${package}"
cp -R "${root}/test/support" "${check_dir}/test/support"

CORE_MINIMUM="${minimum}" perl -pi -e '
  s/\{:gen_agent, "~> \Q$ENV{CORE_MINIMUM}\E or ~> 0\.7\.0"\}/\{:gen_agent, "== $ENV{CORE_MINIMUM}"\}/
' "${check_dir}/integrations/${package}/mix.exs"

(
  cd "${check_dir}/integrations/${package}"
  export GEN_AGENT_HEX=1
  mix deps.get
  mix run --no-start --no-compile -e '
    expected = "0.6.0"

    case Map.get(Mix.Dep.Lock.read(), :gen_agent) do
      {:hex, :gen_agent, ^expected, _, _, _, "hexpm", _} -> :ok
      other -> raise "expected Hex gen_agent #{expected}, resolved #{inspect(other)}"
    end
  '
  mix test
)
