# Changelog

## [0.8.0](https://github.com/genagent/gen_agent/compare/v0.7.0...v0.8.0) (2026-10-11)


### Features

* **api:** halt an agent externally after its active turn ([#427](https://github.com/genagent/gen_agent/issues/427)) ([b43d121](https://github.com/genagent/gen_agent/commit/b43d12166a1f7797e49af12b83db24cf1bfe88ce))
* **backends:** bound and reset HTTP conversation context ([#430](https://github.com/genagent/gen_agent/issues/430)) ([37b52d0](https://github.com/genagent/gen_agent/commit/37b52d0e8f570824bbb808aa852319d21844647f))
* **backends:** expose CLI turn model in responses ([#422](https://github.com/genagent/gen_agent/issues/422)) ([22300ef](https://github.com/genagent/gen_agent/commit/22300ef2d1344bb99dee6c13a02314bc79bab073))
* **backends:** normalize provider failures with retry metadata ([#432](https://github.com/genagent/gen_agent/issues/432)) ([97c410e](https://github.com/genagent/gen_agent/commit/97c410e498714c5485c5c8df711aa8fd4ff5356b))
* **core:** deliver ordinary OTP messages to agent callbacks ([#417](https://github.com/genagent/gen_agent/issues/417)) ([430938e](https://github.com/genagent/gen_agent/commit/430938e7c8485e99ec3eec893ffd5d927461f773))
* **core:** drain agents after active turn ([#412](https://github.com/genagent/gen_agent/issues/412)) ([02e5b29](https://github.com/genagent/gen_agent/commit/02e5b298083a1d5a854a15d9968882a593be0fa0))
* **core:** expose current agent name in callbacks ([#413](https://github.com/genagent/gen_agent/issues/413)) ([1dd173d](https://github.com/genagent/gen_agent/commit/1dd173d6ca22367814ca8e3c81ebd6c09782fc99))
* **core:** include dispatched prompt in responses ([#414](https://github.com/genagent/gen_agent/issues/414)) ([b9f935e](https://github.com/genagent/gen_agent/commit/b9f935e01d501afa88166dca22b76365ac4d4d70))
* **core:** publish scripted mock backend ([#416](https://github.com/genagent/gen_agent/issues/416)) ([bcb801f](https://github.com/genagent/gen_agent/commit/bcb801ff9d929121c2c425c7d930770037b56607))
* **core:** support agent tuple child specs and static stops ([#434](https://github.com/genagent/gen_agent/issues/434)) ([7320c72](https://github.com/genagent/gen_agent/commit/7320c72a05742dad8af909894246ef13420e14ba))
* **openai:** support stateless responses with store option ([#435](https://github.com/genagent/gen_agent/issues/435)) ([cd26b49](https://github.com/genagent/gen_agent/commit/cd26b498ed09abdb5f49cbbb23cacd23cb091026))
* **telemetry:** report agent process termination ([#424](https://github.com/genagent/gen_agent/issues/424)) ([4f30218](https://github.com/genagent/gen_agent/commit/4f3021892945bda48568e34cfe9de0c8b5d136dc))


### Bug Fixes

* **ci:** gate releases on successful current-main CI ([#420](https://github.com/genagent/gen_agent/issues/420)) ([95f0191](https://github.com/genagent/gen_agent/commit/95f01916df490fa3c9d13c90202f57e5e8204613))
* **ci:** make quality and release checks more reliable ([#439](https://github.com/genagent/gen_agent/issues/439)) ([9cc7e34](https://github.com/genagent/gen_agent/commit/9cc7e34a10364f99653a608b2b383449c1d200dc))
* **ci:** publish packages from their release tags ([#419](https://github.com/genagent/gen_agent/issues/419)) ([3292b37](https://github.com/genagent/gen_agent/commit/3292b37a75830e397e066c3a329764685a958616))
* **core:** attribute callback failures to agent and module ([#410](https://github.com/genagent/gen_agent/issues/410)) ([1f0167b](https://github.com/genagent/gen_agent/commit/1f0167bee7f335483237ecf950d95d00a41a5e6c))
* **core:** bound tell result cache by bytes ([#411](https://github.com/genagent/gen_agent/issues/411)) ([824cf09](https://github.com/genagent/gen_agent/commit/824cf091ecc7a2ad930bca90cb96b00eb457f118))
* **core:** reject synchronous self-stop from agent callbacks ([#438](https://github.com/genagent/gen_agent/issues/438)) ([6081bcb](https://github.com/genagent/gen_agent/commit/6081bcbb1c5b20016e4fc8a7ebf1f3d79fd5e260))
* **ensemble:** correct production config and package metadata ([#475](https://github.com/genagent/gen_agent/issues/475)) ([4186000](https://github.com/genagent/gen_agent/commit/41860000a96e5315db36cf7fcee08a1fb9edbb91))
* **guides:** wait for pattern completion and roll back startup ([#452](https://github.com/genagent/gen_agent/issues/452)) ([ad14135](https://github.com/genagent/gen_agent/commit/ad141353802c605cfbc14bdb12efde65d777a58e))

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

## [0.2.0](https://github.com/genagent/gen_agent/releases/tag/v0.2.0) (2026-04-11)


### Features

* add lifecycle hooks (pre_run, pre_turn, post_turn, post_run) ([#2](https://github.com/genagent/gen_agent/issues/2)) ([d79577d](https://github.com/genagent/gen_agent/commit/d79577dfa2e0c7370c3540f4cd3633a4db98637e))


### Bug Fixes

* defer notify events during :processing to preserve state mutations ([b7b647d](https://github.com/genagent/gen_agent/commit/b7b647d8b90b66a8f912fe29063017f71eb859fd))

## Initial development (unpublished, 2026-04-10)

- GenAgent behaviour and supervision framework for long-running LLM
  agent processes modeled as OTP state machines.

The initial 0.1.x development versions were not published to Hex or tagged.
The first published release was 0.2.0; notify deferral appears once under
that release's Bug Fixes above.
