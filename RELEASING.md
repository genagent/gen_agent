# Releasing GenAgent packages

This repository builds six independently versioned Hex packages. The core
project is at the repository root; four backends live in `integrations/` and
Ensemble lives in `extensions/ensemble`. CLI wrappers have their own source
repositories and release workflows.

| Hex package | Directory | Tag format |
| --- | --- | --- |
| `gen_agent` | `.` | `vX.Y.Z` |
| `gen_agent_claude` | `integrations/claude` | `gen_agent_claude-vX.Y.Z` |
| `gen_agent_codex` | `integrations/codex` | `gen_agent_codex-vX.Y.Z` |
| `gen_agent_anthropic` | `integrations/anthropic` | `gen_agent_anthropic-vX.Y.Z` |
| `gen_agent_openai` | `integrations/openai` | `gen_agent_openai-vX.Y.Z` |
| `gen_agent_ensemble` | `extensions/ensemble` | `gen_agent_ensemble-vX.Y.Z` |

Release Please uses the path-based manifest in
`release-please-config.json` and `.release-please-manifest.json`. Each
component keeps its own version and release pull request. Core excludes the
subproject paths from its changelog. The initial manifest records the versions
last released from the separate repositories. Baseline component tags for the
five moved packages point to the consolidation commit; earlier tags and issues
remain in the original repositories.

Merge only the release pull requests intended for that release. When a core
change is required by an adapter or Ensemble change, publish core first and
then release the dependent component with a compatible minimum version. The
workflow publishes core, then any released integrations, then Ensemble. It
skips package versions already present on Hex so a failed publish run can be
retried.

Inside this repository, sibling packages use local path dependencies. Set
`GEN_AGENT_HEX=1` for each sibling's `mix hex.build` or `mix hex.publish` so
its archive contains ordinary Hex requirements. `scripts/package-check.sh`
builds all six archives in that mode and checks their dependency metadata for
path entries. `scripts/consumer-check.sh` compiles a fresh project against
the published Hex packages. Run the consumer check after publishing a new
combination of packages.

The publishing workflow needs a `HEX_API_KEY` that can publish all six
packages. `RELEASE_PLEASE_TOKEN`, when configured, lets release PRs trigger
their normal CI checks; without it, GitHub's workflow token creates the PRs
but GitHub suppresses those PR events. Review their diffs and verify main CI
before merging in that case.

For a manual publish of a tagged component, check out the tag and run
`scripts/publish-package.sh <directory>` with `HEX_API_KEY` set. The script
builds docs and tests, checks the Hex archive, and skips a version already
published.
