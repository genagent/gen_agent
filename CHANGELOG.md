# Changelog

## 0.1.0 (2026-04-10)

- Initial release.
- GenAgent behaviour and supervision framework for long-running LLM
  agent processes modeled as OTP state machines.
- Fix: defer notify events that arrive during `:processing` so
  `handle_event/2` state mutations are not overwritten by the
  in-flight task's result (PR #1).
