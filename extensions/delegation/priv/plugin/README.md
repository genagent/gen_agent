# GenAgent Delegate (local exported package)

Unreleased candidate. This bundle exposes ten stdio MCP tools for bounded
Claude/Codex tasks, retained results, continuation, cancellation, environment
diagnostics and named profiles. The operating skill and five references are also
served as byte-identical MCP resources. The caller owns scope, provider
selection, sequencing and acceptance.

The bundle contains `bin/gen-agent-delegate` and a native Erlang/Elixir release in
`runtime`. The release executable keeps its historical name `delegation_spike`;
the application is `:gen_agent_delegation` and the entrypoint is
`GenAgent.Delegation.MCP.serve()`. Startup does not compile, fetch or require the
build checkout. Both entrypoints discard parent OTP release-selection and runtime
paths before starting this bundle with distribution disabled. They retain provider
credentials, `PATH`, `GEN_AGENT_*` options and runtime-crypto setup.
Claude/Codex CLIs and authentication are host prerequisites.

## Build versus install

**Build** happens once, on a machine with provisioned dependencies:

```sh
cd extensions/delegation
MIX_ENV=prod mix gen_agent.plugin.build --output /absolute/new/plugin-dir
```

The destination must be new and its parent directories must contain no symlinks.
On macOS use `/private/tmp`, not the symlink `/tmp`. Nothing is installed or
configured globally; credentials are never copied.

**Install** happens on the target and needs only the extracted bundle.

The raw export includes ERTS but retains its build machine's native library
linkage. It targets that build OS and architecture; cross-platform portability
is not guaranteed. The supplied `check-install` preflight is specific to Darwin
arm64 with macOS 27 or newer. No portable packaging helper or vendored OpenSSL
libraries are included in this source package. Check runtime compatibility on
the destination before installation. The launcher needs `sh` and `lockf` or
`flock`.

The entrypoints support bundled OpenSSL modules when present, then restore the
caller's `OPENSSL_MODULES` before launching Claude/Codex workers. A raw export
does not itself supply those libraries or modules.

## Transfer

Archive the complete export, including hidden manifests (`.claude-plugin`,
`.mcp.json`, `.agents`), preserving modes:

```sh
cd /absolute/new
tar -czf gen-agent-delegate.tar.gz plugin-dir
shasum -a 256 gen-agent-delegate.tar.gz > gen-agent-delegate.tar.gz.sha256
```

Send the archive through your approved channel and communicate the expected
SHA-256 through a *separate* channel. On the target, in a new empty directory:

```sh
shasum -a 256 gen-agent-delegate.tar.gz   # compare with the separately supplied value
tar -xzpf gen-agent-delegate.tar.gz       # -p keeps modes; extract everything
```

Do not copy files out of the archive selectively: executable bits and hidden
files are required. A missing runtime means re-extracting the complete bundle.
Keep the extracted folder in a stable location; hosts record its path, so moving
or deleting it breaks the installation.

## Preflight

```sh
/absolute/extracted/plugin-dir/bin/check-install
```

Read-only: it requires Darwin arm64 and macOS 27+, an executable release and
`lockf`/`flock`; then starts `crypto`, hashes a test vector with the bundled
runtime (this exposes missing-dylib failures), and runs
`GenAgent.Delegation.Diagnostics.check(%{})` with `RELEASE_DISTRIBUTION=none`.
It prints one JSON document (package/OTP/crypto versions, provider executables,
versions and authentication status). It makes no model call, login, or
configuration change and uses no state directory or task-manager lock.

| Exit | Meaning |
| ---- | ------- |
| 0 | Ready: runtime works and both providers are authenticated |
| 1 | Platform, release, lock tool or native runtime unavailable |
| 2 | Runtime works, but a provider CLI is missing, unrecognized or not authenticated |

Exit 2 can be acceptable if you only need one provider; read `diagnostics.providers`.
An `unknown` authentication result is not proof credentials are missing: the
host's Keychain access or environment may differ from your terminal's.

## Install in a host

Codex, via the bundle's local marketplace:

```sh
codex plugin marketplace add /absolute/extracted/plugin-dir
codex plugin add gen-agent-delegate@genagent-local
```

Claude, via the bundle's Claude marketplace:

```sh
claude plugin marketplace add /absolute/extracted/plugin-dir
claude plugin install gen-agent-delegate@genagent-local
```

Or test it in one Claude session without installing:

```sh
claude --plugin-dir /absolute/extracted/plugin-dir
```

Hosts may cache older packages; reload through their supported flow.

## First use and smoke checks

After loading, in order:

1. `check_environment`: confirm runtime version, launch path, state directory
   and capacity.
2. Discover the **ten tools** and **six resources**; read the `delegate` skill.
3. Paid smoke 1 (read-only): one bounded task, e.g. "Read README.md and list its
   section headings. Do not edit anything." Wait for the retained result.
4. Paid smoke 2 (read-only, other provider): the same kind of task with the
   other backend.
5. Continuation: continue one finished task with a small follow-up, still with no
   source edits.

These are real provider calls and are billed to you. Passing them proves only
those tasks; it does not establish general work-machine compatibility.

## Runtime behavior

MCP explicitly starts one manager. `GEN_AGENT_DEFAULT_BACKEND` defaults to Claude;
`GEN_AGENT_MAX_RUNNING` accepts 1–32 (default 3), so at most three tasks run at
once unless raised.

State is isolated per launch. An explicit `GEN_AGENT_STATE_DIR` always wins.
Otherwise a nonempty `GEN_AGENT_SESSION_ID` (or `CODEX_THREAD_ID` when the host
supplies it) selects a stable hashed directory under
`~/.local/state/gen-agent-delegate/sessions`. With neither, each launch gets a
fresh private directory under `launches`, so separate chats never share tasks or
profiles. A session ID is a namespace, not authentication: never give
simultaneous hosts the same ID or directory.

Recovery: after an anonymous launch exits, set `GEN_AGENT_STATE_DIR` to its
directory (reported by `check_environment`) before reconnecting. Running records
become interrupted after a restart and are never replayed automatically. Use a
local filesystem; kernel owner locks prevent concurrent ownership. stdout is
reserved for MCP; diagnostics go to stderr.

Access differs by host. Default is read-only. Claude's restricted tools are not
an OS filesystem sandbox; write mode adds editing tools but never a shell. Codex
uses its CLI sandbox. Cancellation does not certify cleanup of provider
descendants. Profiles package behavior and schemas, not permissions or provider
defaults.

The source package still uses a local structured IO path dependency. Manifest
versions are generated from the extension version.
