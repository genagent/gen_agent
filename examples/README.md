# Examples

Run these commands from the repository root after fetching each project's dependencies with `mix deps.get` in its directory.

- [gen_agent_app](gen_agent_app): A supervised application with a shared API for configured agents and a keyless Echo default. Run `cd examples/gen_agent_app && iex -S mix`.
- [primitives](primitives): Keyless, asserted scripts for requests, events, streaming, retries, and hooks. Run `cd examples/primitives && bash scripts/run_all.sh`.
- [chaos_lab](chaos_lab): Deterministic fault scenarios for lifecycle, recovery, and admission limits. Run `cd examples/chaos_lab && mix run scripts/chaos_lab.exs`.
