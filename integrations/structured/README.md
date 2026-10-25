# GenAgent Structured

Treat agent work as a request with a validated input and a validated response.
Conversation reuse is explicit machinery underneath that contract. This separate
Mix package changes **no core, wrapper, backend, server or MCP APIs**.

This is an unpublished, local source package (version `0.0.0`) extracted from
commit `630d484a8846ad90d068a1e58ba35bbd1003a10b`. From an application in this
checkout, add `{:gen_agent_structured, path: "integrations/structured"}` (adjust
the path relative to that application's `mix.exs`). The package uses the sibling
GenAgent source and optional Claude/Codex adapter packages. JSON encoding and
local schema validation add Jason and ExJsonSchema dependencies. Applications
using a built-in provider must also include its corresponding adapter dependency;
custom provider modules can implement `GenAgent.Structured.Provider`.

## One request, no conversation management

```elixir
alias GenAgent.Structured, as: Work

{:ok, contract} = Work.contract(
  instructions: "Add the supplied numbers. Do not use tools or modify files.",
  input_schema: %{
    "type" => "object",
    "properties" => %{
      "numbers" => %{"type" => "array", "items" => %{"type" => "integer"}}
    },
    "required" => ["numbers"],
    "additionalProperties" => false
  },
  output_schema: %{
    "type" => "object",
    "properties" => %{"sum" => %{"type" => "integer"}},
    "required" => ["sum"],
    "additionalProperties" => false
  }
)

{:ok, %Work.Result{output: %{"sum" => 42}, response: audit}} =
  Work.run(contract, %{"numbers" => [20, 22]},
    provider: :codex,
    backend_opts: [
      working_dir: File.cwd!(),
      sandbox: :read_only,
      approval_policy: :never
    ]
  )

# audit is the original GenAgent.Response: text, session ID, usage and terminal.
```

`run/3` checks the input before creating any backend, owns one fresh GenAgent
conversation, performs one request and closes it. The call returns a decoded
value, not prose pretending to be a data structure. Session persistence on the
provider side can still exist; one-shot means fresh context and automatic local
lifecycle, not deletion of CLI transcripts.

Both schemas are independently optional. Without an input schema, inputs must
still be valid JSON values. Without an output schema, `output` is final text.
Existing `GenAgent.ask/3` is unchanged for ordinary prompt-oriented work.

## Named request/response profiles

A profile is a named, immutable template: behavioral instructions or supplied
skill text plus optional input/output schemas. The caller registers profiles at
runtime into an explicit registry instance. Provider, model, timeout and access
options remain properties of an invocation, separate from the template.

```elixir
alias GenAgent.Structured.Profiles

{:ok, profiles} = Profiles.start_link(max_profiles: 100)

{:ok, registered} = Profiles.register(profiles, "sum",
  skill: "Add the supplied numbers. Do not use tools or modify files.",
  input_schema: contract.input_schema,
  output_schema: contract.output_schema
)

{:ok, result} = Work.run("sum", %{"numbers" => [20, 22]},
  profiles: profiles,
  provider: :codex,
  backend_opts: [working_dir: File.cwd!(), sandbox: :read_only, approval_policy: :never]
)

result.output  # %{"sum" => 42}
result.profile # %{name: "sum", revision: registered.revision}
```

`instructions`, `skill`, or both may supply the behavior; at least one must be
nonblank. `skill` is caller-supplied text, captured at registration, not a path
automatically opened or a skill magically installed in a CLI. An application can
read its own skill file and pass its contents. The combined text becomes the
contract instructions, followed by validated JSON data at request time. Schema
validation enforces data shape; prose remains behavioral guidance. A profile
does not grant tools, permissions or a security boundary.

Registries are isolated and in-memory, with no global default or persistence.
Supervise `{Profiles, max_profiles: 100}` in the owning application and retain its
PID (or explicitly supply a local registered name). Names are bounded strings;
registration never creates atoms. Capacity defaults to 100 entries, configurable
up to 1,000. Name conflicts fail rather than overwrite. `Profiles.replace/3`
explicitly replaces an existing entry and gives it a new opaque revision;
`fetch/2`, `list/1` and `unregister/2` support discovery and lifecycle.

Both `Work.run/3` and `Work.open/2` accept a name with `profiles: registry`, a
fetched `%GenAgent.Structured.Profile{}` snapshot, or the original contract.
Lookup happens once. A running session pins its instructions, schemas and
revision even if the profile is replaced, removed or its registry exits. A later
named invocation resolves the latest registration. Results and request errors
carry the selected name/revision when available. Unknown names and invalid input
fail before provider startup in `run`; they never fall back to a free-form prompt.

### Starter profiles

[examples/profiles.exs](examples/profiles.exs) supplies three ordinary profile
definitions and illustrative request/response pairs. They are opt-in examples;
requiring the file does not register anything or call a provider.

| Profile | Request | Response |
| --- | --- | --- |
| `researcher` | Question, context, source references, constraints | Summary, findings distinguished as observations/inferences, source references, unknowns |
| `elixir_developer` | Task, project context, acceptance criteria, constraints | Completion status, changes, verification commands/results, remaining work |
| `reviewer` | Diff, context, review focus | Verdict, findings with severity/location, limitations |

```elixir
Code.require_file("examples/profiles.exs")
alias GenAgent.Structured.{ExampleProfiles, Profiles}

{:ok, profiles} = Profiles.start_link()
definitions = ExampleProfiles.definitions()
{:ok, _} = Profiles.register(profiles, "reviewer", definitions["reviewer"])

# Fork a supplied template using exactly the same API as any caller-owned profile.
custom = Keyword.update!(definitions["elixir_developer"], :skill, fn skill ->
  skill <> "\nFollow our team's compatibility policy: retain Elixir 1.19 support."
end)
{:ok, _} = Profiles.register(profiles, "team_elixir_developer", custom)
```

Use `Work.run("reviewer", request, profiles: profiles, provider: :claude, ...)`
with the desired model, workspace, tools and access in invocation options.
Research and review normally need inspection access; development may need writes
and test execution. Those permissions are supplied by the caller and enforced by
the backend configuration, not by the profile name or prose.

The examples require all listed fields; empty strings/lists and nullable finding
locations represent absent context where permitted. Nothing inserts defaults.
Callers can customize the schemas as well as the skill. Each definition uses
closed objects and a small schema vocabulary as a starting point for native CLI
output schemas; provider acceptance is still checked when that provider runs.

The researcher is instructed to cite material actually inspected and separate
inference from observation. The developer must distinguish checks that passed,
failed or were not run. The reviewer must report incomplete review coverage.
Schemas check report shape and allowed status values, not the truth of citations,
code quality or test claims. Applications should retain external verification.
The included response samples are synthetic examples, not results of agent runs.

Run `mix run examples/check_profiles.exs` to register all three and verify their
sample I/O and malformed-data rejection locally. It makes no provider calls.

## Reuse only when wanted

```elixir
{:ok, session} = Work.open(contract,
  provider: :claude,
  backend_opts: [working_dir: File.cwd!()]
)

try do
  {:ok, first} = Work.request(session, %{"numbers" => [20, 22]})
  {:ok, second} = Work.request(session, %{"numbers" => [10, 32]})
  {first.output, second.output}
after
  Work.close(session)
end
```

The contract, provider and backend options stay fixed for the conversation.
Every request gets a distinct request ID. Requests to one session are serialized
by rejecting concurrent callers with `:busy`; independent sessions can run in
parallel. `open` creates the backend before any input is known; `request` validates
before dispatching a prompt. The default per-turn core watchdog is 120 seconds,
configurable with `timeout_ms` (1–3,600,000). It is not a whole-call startup or
shutdown deadline.

Use provider options to choose models, effort, tools and access. This extension
does not impose a universal permission profile. Existing-session selectors
(`resume`, `continue_session`, `fork_session`, `session_id`, `thread_id`) are
rejected: use the explicit owned session API for reuse. Attaching an external
conversation and changing an arbitrary existing agent's contract are out of scope.

## Contract boundaries

- **Input:** strict JSON values, byte/depth limits, then local schema validation.
  No conversion of atom-keyed maps or structs and no implicit default insertion.
- **Rendering:** fixed instructions followed by encoded input JSON. This default
  rendering is deliberately simple; input remains model-visible data, not an
  enforced prompt-injection boundary.
- **Provider:** Claude receives native `json_schema`; Codex receives a private
  schema file and final-message capture. No prompt-only JSON fallback.
- **Output:** Claude's native object or parsed Codex final JSON, then local
  schema validation and encoded-byte limits. Structured output is never truncated.
- **Return:** `{:ok, %Work.Result{request_id: id, output: value, response: raw}}`
  or `{:error, %Work.Error{stage: stage, reason: reason, ...}}`.

`Error.stage` distinguishes `:config`, `:schema`, `:input`, `:provider`, `:output`
and `:lifecycle`. Output errors retain the original response and request ID:
the provider has already run, and a reusable conversation has already advanced.
There is no automatic retry or repair. Exception messages exclude payload data;
the explicit response field remains an application-owned audit record.

Local validation uses [ExJsonSchema 0.11.5](https://hexdocs.pm/ex_json_schema/ExJsonSchema.Validator.html),
isolated to this extension. The package accepts draft-07 schema maps, including
nested objects/arrays, unions, combinators and conditionals. It explicitly rejects
references/identifiers, unknown keywords/formats, other dialects and content
encoding keywords. Nested boolean schemas are supported; root schemas are maps
or absent. Provider-native schema subsets may be narrower and can still reject a
locally valid schema. Input/output defaults are 64,000 encoded JSON bytes,
configurable up to 1 MiB; schema JSON is capped at 64,000 bytes and nesting at 64
containers. These are boundary checks, not streaming memory or token budgets.

Each session owns its core agent and prompt supervisors. An independent file
owner cleans schemas on forced session death; sessions also retain their own
directory so a file-owner crash can close the session and clean up safely. Closing
a session replies to pending requests with a lifecycle error. A session closes
when the process that opened it exits, including normal exits. A requester dying
mid-turn closes that session. Cleanup concerns owned BEAM workers and schema
files; it does not certify settlement of all external subprocess descendants.
Whole-VM death can leave temporary files. Restart recovery is outside this package.

## Optional extension versus core

This implementation belongs in an **optional extension** for now:

1. Core's existing tell/completion, watchdog, lifecycle and response capture are
   sufficient. Core keeps its small dependency set and prompt-oriented behaviour.
2. JSON encoding, schema dialect support, prompt rendering and native schema
   mapping are optional policy with additional dependencies.
3. `GenAgent.Structured.Provider` isolates provider mapping. Claude and Codex CLI
   implementations are included. Other backends require explicit adapters;
   Anthropic/OpenAI HTTP and MCP transport support are not claimed by this package.
4. Contracts can later drive tools, jobs or application request handlers without
   requiring clients to manage conversation IDs for ordinary work.

Before promoting it, decide schema dialect/provider capability reporting,
machine-readable validation paths, optional domain parsing/render callbacks,
explicit cancellation, telemetry, and integration into Server/MCP. These are
follow-ups, not hidden guarantees of this package. Native schema rejection and
provider failures remain visible rather than degrading to an unconstrained call.

## Provider-free verification

```sh
cd integrations/structured
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix run examples/check_profiles.exs
```

The tests use an in-memory backend and do not invoke Claude, Codex or live
providers. They cover input/schema rejection, optional schemas, native provider
mapping, output validation and response retention, private schema files, session
reuse, busy/close/death/watchdog behavior, and profile registry lifecycle and
snapshot pinning. The profile checker validates three synthetic example request
and response pairs and rejects malformed data without model calls.

Historical paid probes, run evidence and spike work logs are not included.
Native provider execution and external subprocess settlement require separate
integration validation.
