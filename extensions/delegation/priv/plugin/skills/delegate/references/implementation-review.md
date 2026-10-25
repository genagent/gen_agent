# Implementation and independent review

Read the repository's applicable instructions and preserve unrelated local changes.
Give the implementation worker a bounded outcome, edit scope, reproduction, and
mechanical acceptance criteria. Choose `workspace_write` only within authorized
scope. A profile or prompt cannot expand filesystem, tool, network, or approval
permissions.

Claude's write mode enables Read/Glob/Grep/Edit/Write, not Bash. It can implement
a change while the parent runs compilation, tests, formatting, or other external
checks. Do not treat inability to execute shell commands as proof that the user is
unauthenticated. Codex's sandbox and approvals remain CLI policy boundaries.

Keep design, implementation, and review sequential for risky changes; independent
read-only reviews of one fixed revision can run in parallel. Record the exact
revision the manager verified. After the patch exists, send an independent read-only reviewer the concrete diff, affected
contracts, and relevant test evidence. Ask for actionable defects with triggers
and file locations, not an approval inferred from passing tests.

For a local revision review, record the base/head IDs and have the controller
prepare one patch file in an authorized location. Supply its absolute path and
revision context in the reviewer input; `diff` can be an empty string when the
context explicitly directs the worker to the artifact. Claude reads it with Read;
Codex can use read-only commands. This is a control pattern, not a built-in revision
resolver. Keep the checkout at the reviewed revision or explain pending changes.
Do not paste the same large patch repeatedly or tell Codex it has no shell when
source inspection requires commands. State whether the review covers introduced
regressions or existing defects; verify cited locations before filing issues.

Gate progress on the profile outcome and inspected evidence as well as task
status. `completed` plus `needs_information` is a completed report with an
unfulfilled review, not approval. Inspect limitations even when verdict is
`approve`. Caller restrictions still apply after a runtime capability brief.

Inspect the returned source and execute necessary checks outside the model's
response. Distinguish verified commands from proposed commands. A schema validates
the shape of a result; it does not validate citations, tests, or correctness.

Usage is provider accounting, not a universal token total. Claude's input counter
excludes cache reads and cache creation; the adapter now retains those separately.
Keep provider identity alongside counters. Missing cost or reported model is
unknown; do not substitute a requested model or estimate a bill from another
provider's fields. `provider_metadata.cost_usd`, when present, is CLI-reported.

For launch/authentication failures, first use `check_environment` in the same host
context. Report unknown probe results honestly. Never dump environment values,
credential files, or provider authentication output to debug the integration.
