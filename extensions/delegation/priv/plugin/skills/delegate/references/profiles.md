# Named profiles

A profile packages caller-supplied behavior text and optional input/output schemas.
It does not grant permissions or select a backend, model, effort, working directory,
access mode, or timeout. Supply those execution settings on each `spawn_task`.
Each worker turn receives a short backend-specific capability description:
Claude has Read/Glob/Grep (and Edit/Write in write mode), with no shell or MCP;
Codex can inspect files using shell commands inside its configured sandbox.
Avoid a provider-neutral "no shell" instruction when Codex needs to inspect source.
Capabilities do not override narrower caller restrictions or grant new access.

Use `list_profiles` to discover compact name/revision metadata, then `get_profile`
to inspect a full definition before choosing it. A new state directory includes
`researcher`, `elixir-developer`, and `reviewer`. These are editable examples, not
proof that a worker has researched, implemented, or reviewed anything successfully.
Validate source evidence and mechanical results independently.

`register_profile` accepts a name, `instructions` and/or `skill` text, optional
`input_schema`/`output_schema`, and `replace` (default false). At least one behavior
field must be nonblank. Skill text is supplied inline; the server does not read a
skill path. A duplicate name is an error unless `replace: true` explicitly replaces
an existing profile. A replacement gets a new revision. `delete_profile` removes
the current name from the catalog, and does not cancel or modify existing tasks.

For an ordinary task, omit `profile` or set it to null and supply `task`. Do not
supply `input`. For a profile task, supply its name and an explicit JSON `input`,
including null if permitted by the input schema. Do not supply `task` or override
`output_schema`: the selected profile supplies behavior and its output contract.

```json
{
  "profile": "my-reviewer",
  "input": {"diff": "...", "context": "..."},
  "cwd": "/absolute/project",
  "backend": "codex",
  "access": "read_only"
}
```

The input must match the profile's actual schema; inspect it with `get_profile`.
In new 0.0.5 catalogs, the reviewer accepts `diff` as inline text or a typed file
reference: `{"file": "/absolute/review.patch"}`. Prepare one patch outside the
worker, then pass the same absolute path to both providers. Claude reads it with
Read; Codex can read it using its sandboxed shell. Include the base/head revision
and what the patch covers in `context`; keep the file unchanged through review.
The server validates the reference's shape and absolute path, but does not read
the file, freeze it, execute git, or certify its contents. Missing or unreadable
evidence must produce `needs_information`. A git revision alone does not let
Claude run git with its restricted toolset. The parent can use, for example,
`git diff --no-ext-diff --no-textconv BASE HEAD -- > /absolute/review.patch`.

Existing catalogs and task snapshots are preserved across updates. Their reviewer
may still require a string. Inspect `get_profile` before using the file variant;
explicitly register/replace the definition if you want the new shape in that
catalog. Continuations retain their original schema even after replacement.

An invalid input is rejected before a provider starts. To continue the latest
successful profile task, supply `task_id` and new `input`; do not supply `message`.
An ordinary task instead requires `message` and rejects `input`. Continuations
retain the original behavior, schemas, and profile revision even after catalog
replacement, deletion, or server restart. Public task metadata identifies that
snapshot by profile name and revision.

Schemas are optional inline draft-07 JSON Schema objects with no references.
Output schemas must have an object root. Prefer simple closed objects with all
properties required for compatibility with both provider CLIs. Encoded profile input and schema-defined output are each limited to 64,000
bytes. Without an output schema, ordinary text output limits apply. Inspect `structured_result`
separately from prose `result`; schema validity establishes shape, not truth.
Task `status: completed` means a valid response arrived. A developer's structured
outcome can still be `blocked` or `partial`, and a reviewer can request changes.
Check both the lifecycle and domain outcome before advancing the work.
`wait_tasks` retains results and profile identity but omits the repeated output
schema. Fetch definitions with `get_profile`, or the task's pinned schema with
`list_tasks(full_result=true)`. A 55-second wait timeout is a snapshot; keep
waiting on unfinished IDs rather than starting duplicate work.

The catalog persists in the configured local state directory. That directory has
one live server owner; this is not a shared multi-server profile service. Stored
profile definitions and task snapshots contain behavior/schema text, so avoid
putting secrets in either. Registry replacement affects future tasks only.
