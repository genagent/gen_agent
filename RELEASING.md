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

Two optional packages are available only as local source and have no independent
release component in this six-package process:

| Source package | Directory and guide |
| --- | --- |
| `gen_agent_structured` | [integrations/structured](integrations/structured/README.md) |
| `gen_agent_delegation` | [extensions/delegation](extensions/delegation/README.md) |

Delegate supports local plugin export with a bundled runtime. Neither source
package has been prepared for Hex publication: their local path dependencies do
not become Hex requirements through `GEN_AGENT_HEX=1`. Their quality/PR checks
validate local compilation, tests and source-package delivery separately; they
are not inputs to the archive, published-consumer or release jobs below.

Release Please uses the path-based manifest in
`release-please-config.json` and `.release-please-manifest.json`. Each
component keeps its own version and release pull request. Core excludes the
five published sibling paths, both optional source-package paths, and root
`CONTRIBUTING.md` and `RELEASING.md` through `exclude-paths`. Core's `README.md`
remains included so genuine core README changes remain visible. A commit confined
to an excluded source directory is not attributed to core; a mixed `feat:` commit
that also touches an included root file can still trigger a core release.

For source-first delivery, preserve separate commits with an allowed rebase merge:
keep each source implementation commit confined to its excluded directory, put
root documentation changes (including README and CONTRIBUTING) in a `docs:`
commit, and put root CI/configuration changes in a `chore:` commit. Do not squash
these into a mixed `feat:` commit. Review the resulting commit paths and types
before merging.

The initial manifest records the versions last released from the separate
repositories. Baseline component tags for the five moved packages point to the
consolidation commit; earlier tags and issues
remain in the original repositories.

Merge only the release pull requests intended for that release. When existing
consumers can support a new core while retaining their published lower bounds,
widen their requirements and test against the core release candidate. Publishing
those adapters, then Ensemble, before core remains a useful release order.

Core can publish first while the latest published siblings still share an older
compatible core, as with core 0.9 and all five siblings resolving core 0.8.
Before publishing any sibling version that requires the new core, publish every
sibling compatibility range needed to admit it, or coordinate their releases so
no CI-gated intermediate published set is incoherent.
The default published-consumer gate pins the
latest stable release of each of the five siblings and lets Hex select the newest
core compatible with that set. It may therefore still resolve an earlier core
while compatibility patches are being released. It never substitutes older
siblings or skips a package; an incoherent published set fails resolution.
Within one release workflow, publication runs core, then released integrations,
then Ensemble. It skips versions already present on Hex so a failed publish run
can be retried.

After publishing core, refresh each dependent package's Hex-mode lock before
testing or building it against the new core. From the dependent directory run
`GEN_AGENT_HEX=1 mix deps.update gen_agent` (for example,
`cd integrations/claude && GEN_AGENT_HEX=1 mix deps.update gen_agent`). Repeat
for each integration or extension being released, and check that its `mix.lock`
resolves the intended published core version. Local path mode does not refresh
these Hex lock entries. The CI and manual `scripts/publish-package.sh
<directory> prepare` paths already perform this update before testing and
building; run it explicitly when preparing a package outside that script.

Ensemble also refreshes its test-only adapter dependencies with core during
preparation. Their ranges must admit the widened adapter releases, or the
resolver may remain on an older core. `package-check.sh` verifies that each
consumer's declared range admits the candidate root version even when that
version is not yet on Hex; this metadata gate does not replace candidate
runtime tests or the post-publication exact-version consumer check.

Inside this repository, sibling packages use local path dependencies. For the
five published siblings, set
`GEN_AGENT_HEX=1` for each sibling's `mix hex.build` or `mix hex.publish` so
its archive contains ordinary Hex requirements. `scripts/package-check.sh`
builds all six archives in that mode and checks their dependency metadata for
path entries. These are two separate CI gates: `package-check.sh` also compiles
and tests current sibling sources against the exact current core when that core
is published on Hex. This protects source compatibility even when the published
consumer still resolves an earlier core. `scripts/consumer-check.sh` compiles a
fresh project with exact latest stable sibling versions and a flexible core
requirement. It verifies and prints the actually locked core and all five exact
sibling versions. This default mode checks the published ecosystem while
compatibility patch releases land independently. After publishing a new
combination of packages, run
`scripts/consumer-check.sh --manifest` to verify and compile the exact versions
in `.release-please-manifest.json`, including an exact core pin. This post-publish
check confirms the intended complete release combination. Both modes use `jq`;
the default mode also queries the Hex API with `curl`.

The CI, release, and publication recovery workflows set `FORCOLA_BUILD=1`
to build Forcola locally with Cargo instead of using its precompiled
downloads, which have failed with
`{:header_too_long, {:max, 10240}}`. CI explicitly installs stable Rust before
dependency commands in both package matrices (including Claude quality and
publish-toolchain checks), minimum-core checks, the Claude repository review
and app examples, archive packaging, and the published-package consumer check.
The workflow-level setting also reaches the temporary projects and Hex-mode
builds launched by those checks. The release integration matrix and publication
recovery workflow also install stable Rust before package preparation, which
runs tests and compiles Claude's test-only Forcola dependency. This workaround
is limited to build workflows; published packages are unchanged, and package
users still use Forcola's precompiled downloader.

The publishing workflow needs a `HEX_API_KEY` that can publish all six
packages. `RELEASE_PLEASE_TOKEN`, when configured, lets release PRs trigger
their normal CI checks; without it, GitHub's workflow token creates the PRs
but GitHub suppresses those PR events. Review their diffs and verify main CI
before merging in that case.

For a manual publish of a tagged component, check out the tag and run
`scripts/publish-package.sh <directory>` with `HEX_API_KEY` set. The script
builds docs and tests, checks the Hex archive, and skips a version already
published.
