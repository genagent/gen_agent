# Contributing to GenAgent

## Setting up a source checkout

Clone the repository and set up dependencies:

```bash
git clone https://github.com/genagent/gen_agent.git
cd gen_agent
mix deps.get
```

This repository requires **Elixir 1.19 or later**. Check your version with `elixir --version`.

## Package layout

GenAgent is a monorepo with six independently published Hex packages:

| Package | Directory | Purpose |
| --- | --- | --- |
| `gen_agent` (core) | `.` | Agent framework and behaviours |
| `gen_agent_claude` | `integrations/claude` | Claude backend |
| `gen_agent_codex` | `integrations/codex` | Codex backend |
| `gen_agent_anthropic` | `integrations/anthropic` | Anthropic API backend |
| `gen_agent_openai` | `integrations/openai` | OpenAI backend |
| `gen_agent_ensemble` | `extensions/ensemble` | Ensemble orchestration |

**Dependencies between packages.** By default, sibling packages use local path dependencies (e.g., `integrations/claude/mix.exs` depends on the root `gen_agent` at `path: "../.."`). This lets you develop across multiple packages.

For the six published packages, `GEN_AGENT_HEX=1` switches dependencies to version
constraints during publishing. The publishing workflow handles this automatically.

Two additional packages are source-only and are not included in that release pipeline:

| Source package | Directory and guide | Purpose |
| --- | --- | --- |
| `gen_agent_structured` | [integrations/structured](integrations/structured/README.md) | Structured IO contracts and profiles |
| `gen_agent_delegation` | [extensions/delegation](extensions/delegation/README.md) | Delegate manager, MCP tools and local plugin export |

Use local path dependencies as described in their guides. Delegate's local export
is available; Hex publication for these two packages has not been prepared.

## Running checks

### Quick checks (root package only)

For rapid iteration on the core package:

```bash
mix test
mix format --check-formatted
mix credo --strict
mix dialyzer
```

These four commands match the [Testing section](README.md#testing) in the README.

### Full checks (six published and two source packages)

Before pushing, run the full validation across all packages:

```bash
scripts/quality.sh
```

For the six published packages, the script retains dependency lock checks and
audits, warnings-as-errors compilation, formatting, Credo, tests, ExDoc and
Dialyzer. For the two source packages, it checks dependency locks, audits Hex
dependencies after `mix deps.get --check-locked` rejects lockfile drift,
compiles with warnings as errors, and runs formatting and
provider-free tests, then validates Structured's example profiles
or builds Delegate's production plugin export in a temporary directory. It does
not require development tools those packages do not declare, or attempt to build
Hex archives for them. Delegate export includes the native runtime and requires
the build toolchain and provisioned dependencies; no provider call is made.

To check just the source packages:

```bash
scripts/quality.sh integrations/structured extensions/delegation
```

PR CI runs these source gates on Elixir 1.19 / OTP 27 and Elixir 1.20 / OTP 29
in a separate matrix alongside the unchanged published-package gates.

## Pull requests

### PR title validation

PR titles follow [Conventional Commits](https://www.conventionalcommits.org/) syntax and are validated by the `.github/workflows/pr-title.yml` workflow on all pull requests to `main`:

```
type(optional-scope): description
```

Examples:
- `fix: correct timeout in agent shutdown`
- `feat(claude): add support for batch requests`
- `docs(releasing): clarify version constraints`
- `fix!: remove deprecated Agent.start_link/2` (breaking change)

The type is a word (e.g., `fix`, `feat`, `docs`, `chore`, `refactor`). The scope is optional; if present it should identify the affected package or subsystem. The description must be nonblank. The workflow validates this format and structure; as style guidance (not a checked requirement), descriptions often use imperative phrasing.

### Conventional commits and release notes

For source-first package delivery, preserve separate implementation, root docs
and CI/configuration commits with an allowed rebase merge as described in
[RELEASING.md](RELEASING.md); avoid attributing a mixed `feat:` commit to core.

When squash-merging other PRs, preserve the Conventional Commit title in the merge
commit message. [Release Please](https://github.com/googleapis/release-please)
uses commit messages to categorize changes and determine release notes and
version bumps. The release configuration uses changed paths to decide which
packages receive release PRs; the commit scope does not select a package.

## Releases

The six published GenAgent packages are released independently using [Release Please](https://github.com/googleapis/release-please).

Each published package gets its own release pull request when commits affect it. Merge the intended release PRs, and the publishing workflow publishes them to Hex and tags them on GitHub.

For details on version coordination, dependency constraints, and manual publishing, see [RELEASING.md](RELEASING.md).

## License

Contributions are made under the MIT license. See [LICENSE](LICENSE).
