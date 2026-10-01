# Changelog

## [0.3.0](https://github.com/genagent/gen_agent/compare/v0.2.2...v0.3.0) (2026-10-01)


### Features

* bound pending runtime inputs ([#41](https://github.com/genagent/gen_agent/issues/41)) ([3a00c02](https://github.com/genagent/gen_agent/commit/3a00c02d15f85d3ccd2ac9216bc49c12db6760f6))
* deliver request-scoped completion messages ([#42](https://github.com/genagent/gen_agent/issues/42)) ([882b10d](https://github.com/genagent/gen_agent/commit/882b10dff5ca8ae930bf774e10baf173ef3d4ca7))

## [0.2.2](https://github.com/genagent/gen_agent/compare/v0.2.1...v0.2.2) (2026-10-01)

### Features

* support caller-owned agent and prompt-task supervision ([#31](https://github.com/genagent/gen_agent/pull/31))
* expose bounded runtime snapshots with pending-input counts ([#34](https://github.com/genagent/gen_agent/pull/34))

### Bug Fixes

* preserve callback state on terminal errors and stream EOF ([#32](https://github.com/genagent/gen_agent/pull/32))
* acknowledge interruption only for the current request ref ([#33](https://github.com/genagent/gen_agent/pull/33))
* bound retained stream events and report typed overflow ([#35](https://github.com/genagent/gen_agent/pull/35))
* clarify CLI backend and wrapper boundaries ([#38](https://github.com/genagent/gen_agent/issues/38)) ([70f7a0f](https://github.com/genagent/gen_agent/commit/70f7a0f49cf228b7f2d592b1ff38f2e4dcb06ab4))

## [0.2.1](https://github.com/genagent/gen_agent/compare/v0.2.0...v0.2.1) (2026-09-30)


### Bug Fixes

* refresh core task lifecycle and maintenance ([#28](https://github.com/genagent/gen_agent/issues/28)) ([de84bfc](https://github.com/genagent/gen_agent/commit/de84bfcf9daf4b21ce1ea9465fe4d7933040c2c7))

## [0.2.0](https://github.com/genagent/gen_agent/compare/v0.1.0...v0.2.0) (2026-04-11)


### Features

* add lifecycle hooks (pre_run, pre_turn, post_turn, post_run) ([#2](https://github.com/genagent/gen_agent/issues/2)) ([d79577d](https://github.com/genagent/gen_agent/commit/d79577dfa2e0c7370c3540f4cd3633a4db98637e))


### Bug Fixes

* defer notify events during :processing to preserve state mutations ([b7b647d](https://github.com/genagent/gen_agent/commit/b7b647d8b90b66a8f912fe29063017f71eb859fd))
* defer notify events during :processing to preserve state mutations ([07d1d90](https://github.com/genagent/gen_agent/commit/07d1d90f992c570cbb455bca81caa646147fd835))

## 0.1.0 (2026-04-10)

- Initial release.
- GenAgent behaviour and supervision framework for long-running LLM
  agent processes modeled as OTP state machines.
- Fix: defer notify events that arrive during `:processing` so
  `handle_event/2` state mutations are not overwritten by the
  in-flight task's result (PR #1).
