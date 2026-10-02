# Examples

Run these commands from the repository root after fetching each project's dependencies with `mix deps.get` in its directory.

- [gen_agent_app](gen_agent_app): A supervised application with a shared API for configured agents and a keyless Echo default. Run `cd examples/gen_agent_app && iex -S mix`.
- [primitives](primitives): Keyless, asserted scripts for requests, events, streaming, retries, and hooks. Run `cd examples/primitives && bash scripts/run_all.sh`.
- [chaos_lab](chaos_lab): Deterministic fault scenarios for lifecycle, recovery, and admission limits. Run `cd examples/chaos_lab && mix run scripts/chaos_lab.exs`.
- [log_triage](log_triage): Batches OTP error and crash reports into incident notes using a keyless deterministic backend. Run `cd examples/log_triage && mix run -e "LogTriage.Demo.run()"`.
- [claude_repo_review](claude_repo_review): A supervised Claude agent for read-only repository reviews. Run `cd examples/claude_repo_review && iex -S mix` with an authenticated Claude CLI, then follow its README. Tests run keyless against recorded Claude fixtures with `cd examples/claude_repo_review && mix test`.
