# Model and effort

Honor user-selected backend/model/effort. Otherwise omit values when provider CLI
defaults are appropriate. Backend defaults to the server's `GEN_AGENT_DEFAULT_BACKEND`
(Claude unless configured otherwise). No setting is inherited from the parent chat.

Claude accepts low, medium, high, xhigh, and max effort; Codex additionally accepts
none, minimal, and ultra. Actual support depends on the installed CLI and chosen
model. Do not automatically choose the largest effort, invent a model catalogue,
or silently substitute a different provider after a failure.

Explicit user and provider constraints come first. For a small, well-scoped
mechanical change, use an available efficient model when the caller has authorized
that choice. Uncertain diagnosis or high-impact review can justify higher effort.
Do not hardcode a model or effort per role, or assume any universal model tier.
Keep the task bounded regardless of model size.

Treat requested, selected, and reported settings as separate evidence. Requested
values describe the caller; selected values describe what was sent to the CLI;
reported values require provider evidence. A model alias may resolve differently,
and omitted CLI defaults can remain unknown. Do not infer the model or effort from
token usage, cost, or the parent's settings.

Usage fields are optional provider evidence. Missing means unknown, not zero.
Claude's `input_tokens` represents uncached input; optional cache-read/creation
counters and `provider_metadata.cost_usd` provide additional evidence. Codex may
report cached/reasoning tokens without a cost or model. Do not compare uncached
Claude input directly with Codex's total input, or estimate a missing cost as zero.
Model, task scope, context, caches and effort affect cost and latency; observe
actual runs rather than making a fixed provider routing rule. One peer review
trial took roughly 3.5–4 minutes on Claude and 17–75 seconds on Codex, but different
coverage and model provenance prevent treating that as a general benchmark.

Continuations retain the original settings and schema. To intentionally change
those, start a new bounded task with the relevant context and record the change.
