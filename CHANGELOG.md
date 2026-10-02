# Changelog

## [0.6.0](https://github.com/genagent/gen_agent/compare/v0.5.0...v0.6.0) (2026-10-02)


### Features

* **core:** checkpoint CLI sessions during active turns ([52f2919](https://github.com/genagent/gen_agent/commit/52f2919f2e677a14b428b05f1ad6dd1628741cd0))


### Bug Fixes

* **core:** compact retained events without losing turns ([#282](https://github.com/genagent/gen_agent/issues/282)) ([f9c9375](https://github.com/genagent/gen_agent/commit/f9c9375adbc4ef446f2bc52e336ac0006da5399c))
* **ensemble:** complete dispatches when members halt ([#284](https://github.com/genagent/gen_agent/issues/284)) ([a6bac3d](https://github.com/genagent/gen_agent/commit/a6bac3d855bf188081d6693f9180ecc682f27336))
* ignore dead registered agents in whereis ([#274](https://github.com/genagent/gen_agent/issues/274)) ([f5127d9](https://github.com/genagent/gen_agent/commit/f5127d93432141dea46caf143f268c476de00c28))
* redact sensitive agent state from diagnostics ([#280](https://github.com/genagent/gen_agent/issues/280)) ([3038766](https://github.com/genagent/gen_agent/commit/3038766b00c1854a2db31ca74bba5a48da13c9ad))

## [0.5.0](https://github.com/genagent/gen_agent/compare/v0.4.0...v0.5.0) (2026-10-01)


### Features

* **core:** cancel queued tells and drop orphaned asks ([#161](https://github.com/genagent/gen_agent/issues/161)) ([3438bc9](https://github.com/genagent/gen_agent/commit/3438bc97c9d67e8fcaa2acd1246feaf9549111d0))


### Bug Fixes

* **codex:** distinguish unsupported options from resume limitations ([#162](https://github.com/genagent/gen_agent/issues/162)) ([6be8ef9](https://github.com/genagent/gen_agent/commit/6be8ef9f053069f9a4a71d158d877cb815eda627))

## [0.4.0](https://github.com/genagent/gen_agent/compare/v0.3.1...v0.4.0) (2026-10-01)


### Features

* add metric-safe turn telemetry ([#79](https://github.com/genagent/gen_agent/issues/79)) ([ef064e0](https://github.com/genagent/gen_agent/commit/ef064e042d33e95095317c43c2e69f76d137cf09))

## [0.3.1](https://github.com/genagent/gen_agent/compare/v0.3.0...v0.3.1) (2026-10-01)


### Bug Fixes

* preserve boundaries between Codex agent messages ([#74](https://github.com/genagent/gen_agent/issues/74)) ([e03b4f6](https://github.com/genagent/gen_agent/commit/e03b4f629787d91013a02854b4d875c40b8005fa))

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
