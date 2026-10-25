# GenAgent Delegation

Unpublished optional source package `:gen_agent_delegation`, locally versioned at
`0.0.12`. Add `{:gen_agent_delegation, path: "extensions/delegation"}` to a
consumer in this checkout (adjust the path relative to its `mix.exs`).
It owns the public `GenAgent.Delegation` manager, implementation modules under
`GenAgent.Delegation.*`, task storage, profiles, MCP surface, canonical plugin
skills/templates, and the local plugin exporter. Core and Ensemble do not depend
on this package. It composes the existing Claude/Codex adapters and structured IO.

## Library ownership

Adding the dependency starts an empty `GenAgent.Delegation.Supervisor`: no manager
is registered and no delegation state directory is created or locked. Explicitly
supervise a manager in your application, for example:

```elixir
{GenAgent.Delegation, name: MyApp.Delegate, state_dir: "/absolute/private/state"}
```

Pass that name as the manager argument to the public functions. Alternatively,
opt in to one package-supervised owner with application configuration:

```elixir
config :gen_agent_delegation, :manager_opts,
  state_dir: "/absolute/private/state",
  default_backend: "claude",
  max_running: 3
```

`GenAgent.Delegation.MCP.serve()` starts the application and explicitly starts its
manager. If application configuration already started that package-supervised
child, MCP deliberately uses that same owner. It never adopts a manager owned
by another supervisor. MCP uses the default `GenAgent.Delegation` registered name;
custom names are for direct library consumers.

For MCP, environment options retain their existing meanings:
`GEN_AGENT_DEFAULT_BACKEND` (Claude by default), an optional explicit
`GEN_AGENT_STATE_DIR`, and `GEN_AGENT_MAX_RUNNING` (1–32, default 3).
Without an explicit directory, a nonempty `GEN_AGENT_SESSION_ID` or
`CODEX_THREAD_ID` selects a stable hashed session directory beneath
`~/.local/state/gen-agent-delegate/sessions`. Hosts supplying neither get a fresh
private directory beneath `launches` on every startup. Check `check_environment`
for the actual directory; explicitly reuse it to recover that launch after exit.
Existing `default` data is retained but never automatically adopted. Library startup does not consult these
options unless a manager is explicitly requested by MCP.

Tool names, skill resource URIs, task/profile schemas, profile revision pinning,
state format, owner locks and interrupted-task recovery are preserved. No routing,
new tasks, permission expansion, automatic retry or failed-task replay is added.
Claude's restricted tools are not an OS filesystem sandbox. Codex retains its CLI
sandbox and approval settings. Cancellation still does not certify provider
subprocess cleanup.

## Export

With dependencies already provisioned, run from this extension:

```sh
MIX_ENV=prod mix gen_agent.plugin.build --output /absolute/new/plugin-dir
```

The destination must be new and absolute. The task compiles with warnings as
errors, includes ERTS, copies an explicit asset allowlist, materializes release
symlinks, checks packaged guidance against the compiled MCP resource text, and
emits a local Codex marketplace. It never fetches dependencies, starts providers,
installs a plugin or changes global host settings.

Canonical assets are in `priv/plugin`. Manifest templates omit the version;
exports generate it from this package's version, also used by MCP identity.
Resources compile from package-local `priv` files; exports locate assets through
`:code.priv_dir(:gen_agent_delegation)`. Runtime operation needs neither the build
checkout nor its working directory. Historical embedded plugins and spike helper
scripts are not included.

The exported layout remains `bin/gen-agent-delegate` plus
`runtime/bin/delegation_spike`. Retaining the release executable name preserves
the launcher layout; the launcher now evaluates `GenAgent.Delegation.MCP.serve()`.
The OTP application and BEAM namespace use the new package identity. Exports have
distribution disabled and use a non-secret local release cookie.

This is a local source package, not a standalone Hex release. In particular,
the local path structured IO dependency prevents clean standalone Hex publication;
published dependency constraints remain unverified. Releases target their build
OS/architecture, require installed/authenticated provider CLIs plus sh and
lockf/flock, and retain native build linkage constraints. BEAM debug metadata may
contain build source paths. Windows and cross-platform binaries are not promised.

## Local validation

The full moved suite includes fake-provider lifecycle, profiles, storage,
contracts, MCP discovery/resources, exporter and startup ownership regressions.
Run it from this package; no provider call is needed. Historical paid probes,
runs and control helpers are not included.

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
MIX_ENV=prod mix gen_agent.plugin.build --output /absolute/new/plugin-dir
```

A relocated export still needs parent acceptance for direct MCP discovery,
resource equality, state ownership and native launcher portability. Do not treat
local tests or an export as a clean Hex installation check.

Default `list_tasks` rows include only task identity, lifecycle, selected request
options, profile name/revision and bounded redacted error diagnostics. Retained
usage, provider metadata, provider session IDs and outputs require
`full_result: true` or `wait_tasks`. Codex tasks accept an existing absolute
non-Git `cwd` using `skip_git_repo_check`, while retaining the chosen sandbox,
`approval_policy: :never` and `ignore_user_config: true`.

For a provider-free exported CLI smoke, launch `bin/gen-agent-delegate` from an
unrelated directory with a fresh `GEN_AGENT_STATE_DIR`, initialize MCP, list the
ten tools and six resources, compare resource text with `skills/delegate`, and
call `list_tasks` expecting an empty list. Both launchers discard inherited OTP
release-selection and runtime paths,
then select this bundle with distribution disabled. Provider credentials, `PATH`,
`GEN_AGENT_*` state options and the explicit runtime-crypto setup are retained.
No provider task is required for this check.
