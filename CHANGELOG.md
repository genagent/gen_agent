# Changelog

## [0.7.0](https://github.com/genagent/gen_agent/compare/v0.6.2...v0.7.0) (2026-10-06)


### Features

* add response metadata field ([#359](https://github.com/genagent/gen_agent/issues/359)) ([02e6e01](https://github.com/genagent/gen_agent/commit/02e6e0134d87098e6e87f5fd09883ea69e674097))
* **core:** deliver ref-tagged stream events to a recipient ([#341](https://github.com/genagent/gen_agent/issues/341)) ([df6d873](https://github.com/genagent/gen_agent/commit/df6d8735482fcd5b804677e2ab2229922c9ffd68))
* **examples:** bounded Consensus review loop example (part of [#269](https://github.com/genagent/gen_agent/issues/269)) ([#334](https://github.com/genagent/gen_agent/issues/334)) ([3f174f5](https://github.com/genagent/gen_agent/commit/3f174f5969526ad1e63d4902c89ff388cc5a33b0))
* **examples:** chaos lab for the supervision contract (part of [#146](https://github.com/genagent/gen_agent/issues/146)) ([#306](https://github.com/genagent/gen_agent/issues/306)) ([35f1515](https://github.com/genagent/gen_agent/commit/35f151538b9b6a115e139d6eea13da0940277580))
* **examples:** keyless primitive examples 01 to 03 with a runner and CI job (part of [#145](https://github.com/genagent/gen_agent/issues/145)) ([#300](https://github.com/genagent/gen_agent/issues/300)) ([3f541ea](https://github.com/genagent/gen_agent/commit/3f541ea332dd845f955304f9e3788b08de940f66))
* **examples:** log triage example batching node crash reports into agent turns (part of [#147](https://github.com/genagent/gen_agent/issues/147)) ([#311](https://github.com/genagent/gen_agent/issues/311)) ([ee435d5](https://github.com/genagent/gen_agent/commit/ee435d5b4ddd14ff3f3f6334ef59a7164a479d8a))
* **examples:** primitive examples 04 to 06, an examples index, and HTTP testing recipes ([#317](https://github.com/genagent/gen_agent/issues/317)) ([6eb6691](https://github.com/genagent/gen_agent/commit/6eb6691129eea348d49de7c7abe29dcb76255426))
* **examples:** read-only repository review example on the Claude backend (part of [#144](https://github.com/genagent/gen_agent/issues/144)) ([#325](https://github.com/genagent/gen_agent/issues/325)) ([9529427](https://github.com/genagent/gen_agent/commit/952942792d144ec3e13ce17d6c1cb21142c6470e))
* list registered agents ([#354](https://github.com/genagent/gen_agent/issues/354)) ([ff8c3c2](https://github.com/genagent/gen_agent/commit/ff8c3c204e6faf0d17bc911c31133ef42ac47cf4))


### Bug Fixes

* **core:** allow bounded callbacks to finish on shutdown ([#405](https://github.com/genagent/gen_agent/issues/405)) ([70a1488](https://github.com/genagent/gen_agent/commit/70a14884908f6dd37fee1cbc95e618df5d35ee42))
* **core:** attribute startup failures to the right component ([#366](https://github.com/genagent/gen_agent/issues/366)) ([1ffbe5c](https://github.com/genagent/gen_agent/commit/1ffbe5ce12b1793bd2d75f2ded1e051db877e95f))
* **core:** contain malformed callbacks and report generated prompt failures ([#402](https://github.com/genagent/gen_agent/issues/402)) ([8b4d429](https://github.com/genagent/gen_agent/commit/8b4d4298b4af793131bb2820a872890810b19fce))
* **core:** drain notifications before halt completion hooks ([#401](https://github.com/genagent/gen_agent/issues/401)) ([4c5c8c8](https://github.com/genagent/gen_agent/commit/4c5c8c8e1d0a871f57c2792e91ece7c7bfd3f3f5))
* **core:** return not_found for missing agent calls ([#379](https://github.com/genagent/gen_agent/issues/379)) ([c78c718](https://github.com/genagent/gen_agent/commit/c78c718385f23eddce8d23c3fa903160af074ca9))
* **core:** stop agents after Registry registration loss ([#382](https://github.com/genagent/gen_agent/issues/382)) ([9d9fa0f](https://github.com/genagent/gen_agent/commit/9d9fa0fecc28bb994c54669aba8bea0f681b7f42))
* **core:** validate watchdog and tell result limits at startup ([#370](https://github.com/genagent/gen_agent/issues/370)) ([b3173fe](https://github.com/genagent/gen_agent/commit/b3173fe1bd27651d913fc98ad94337ce3bfab7cb))
* **deps:** allow core 0.7 in CLI adapters and Ensemble ([#327](https://github.com/genagent/gen_agent/issues/327)) ([f9d3a21](https://github.com/genagent/gen_agent/commit/f9d3a218b5e7beb82217f829c4b267c2f7504829))
* **server:** fail requests when task supervisor is unavailable ([#314](https://github.com/genagent/gen_agent/issues/314)) ([9681515](https://github.com/genagent/gen_agent/commit/9681515e62a0eedaa0238d6359e3e8b0ce21d7b9))
* **server:** reply to asks on graceful stop ([#393](https://github.com/genagent/gen_agent/issues/393)) ([7ce6250](https://github.com/genagent/gen_agent/commit/7ce6250650224bab8fffacd2641b3e4f1ce6147c))

## [0.6.2](https://github.com/genagent/gen_agent/compare/v0.6.1...v0.6.2) (2026-10-02)


### Bug Fixes

* **backends:** require compatible core for CLI adapters ([#308](https://github.com/genagent/gen_agent/issues/308)) ([286f578](https://github.com/genagent/gen_agent/commit/286f578461e75de6e32a43a277b2b5150a2b0e44))

## [0.6.1](https://github.com/genagent/gen_agent/compare/v0.6.0...v0.6.1) (2026-10-02)


### Bug Fixes

* **core:** retain final assistant message for presentation ([7580728](https://github.com/genagent/gen_agent/commit/758072863902aa7101cc3d3fa429863c544c88bb))
* **ensemble:** require core 0.6 for completion-aware dispatch ([d5d0d39](https://github.com/genagent/gen_agent/commit/d5d0d3926698858625b4127cc4bd7d94ecbec6bc))

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
