# Contributing to GenAgent

## Setting up a source checkout

Clone the repository and set up dependencies:

```bash
git clone https://github.com/genagent/gen_agent.git
cd gen_agent
mix deps.get
```

This repository requires **Elixir 1.19 or later**. Check your version with `elixir --version`.

## Six-package layout

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

When publishing to Hex, set `GEN_AGENT_HEX=1` to switch dependencies to version constraints. This is handled automatically by the publishing workflow.

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

### Full checks (all six packages)

Before pushing, run the full validation across all packages:

```bash
scripts/quality.sh
```

This script:
- Verifies dependencies are up-to-date (`mix deps.unlock --check-unused`)
- Audits dependencies for vulnerabilities (`mix hex.audit`)
- Compiles with warnings treated as errors
- Runs formatting, linting, tests, docs, and type checking for each package

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

When squash-merging a PR, preserve its Conventional Commit title in the merge
commit message. [Release Please](https://github.com/googleapis/release-please)
uses commit messages to categorize changes and determine release notes and
version bumps. The release configuration uses changed paths to decide which
packages receive release PRs; the commit scope does not select a package.

## Releases

GenAgent packages are released independently using [Release Please](https://github.com/googleapis/release-please).

Each package gets its own release pull request when commits affect it. Merge the intended release PRs, and the publishing workflow publishes them to Hex and tags them on GitHub.

For details on version coordination, dependency constraints, and manual publishing, see [RELEASING.md](RELEASING.md).

## License

Contributions are made under the MIT license. See [LICENSE](LICENSE).
