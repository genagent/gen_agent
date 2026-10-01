# Changelog

## [0.2.2](https://github.com/genagent/gen_agent/compare/v0.2.1...v0.2.2) (2026-10-01)


### Bug Fixes

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
