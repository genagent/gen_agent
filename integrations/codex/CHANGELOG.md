# Changelog

## [0.5.0](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.4.8...gen_agent_codex-v0.5.0) (2026-10-05)


### Features

* **codex:** optionally return only the final agent message ([#394](https://github.com/genagent/gen_agent/issues/394)) ([b251a13](https://github.com/genagent/gen_agent/commit/b251a1321242edea1c895f76e0a16d38c357dc53))


### Bug Fixes

* **backends:** align CLI adapter wrapper constraints ([#396](https://github.com/genagent/gen_agent/issues/396)) ([#397](https://github.com/genagent/gen_agent/issues/397)) ([ecbbec4](https://github.com/genagent/gen_agent/commit/ecbbec479745689685a78ec0aa1b7c2e8aaad4c2))

## [0.4.8](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.4.7...gen_agent_codex-v0.4.8) (2026-10-03)


### Bug Fixes

* **backends:** validate options and align shared names ([#389](https://github.com/genagent/gen_agent/issues/389)) ([68abf7c](https://github.com/genagent/gen_agent/commit/68abf7cde4ca185980ac3f8375d94390f98bf3d4))

## [0.4.7](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.4.6...gen_agent_codex-v0.4.7) (2026-10-03)


### Bug Fixes

* **codex:** require wrapper oversized-line errors ([#388](https://github.com/genagent/gen_agent/issues/388)) ([19561f7](https://github.com/genagent/gen_agent/commit/19561f7efdacce476ca4ec39d75b191f93a609b9))
* **codex:** translate current item types without duplicate payloads ([#386](https://github.com/genagent/gen_agent/issues/386)) ([c4baa01](https://github.com/genagent/gen_agent/commit/c4baa01ff07070b73b19055a62968025d60c4b46)), closes [#184](https://github.com/genagent/gen_agent/issues/184)

## [0.4.6](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.4.5...gen_agent_codex-v0.4.6) (2026-10-03)


### Bug Fixes

* **codex:** report CLI stream timeouts to GenAgent ([#383](https://github.com/genagent/gen_agent/issues/383)) ([c0ca936](https://github.com/genagent/gen_agent/commit/c0ca936ab415ea562bc0851f08f50128aeabe0d6))
* **codex:** require buffered timeout drain fix ([#384](https://github.com/genagent/gen_agent/issues/384)) ([172b24c](https://github.com/genagent/gen_agent/commit/172b24c20aff847f5aaaabb4db085d3bc8c12741))
* **codex:** validate session sandbox and working directory ([#377](https://github.com/genagent/gen_agent/issues/377)) ([255ce70](https://github.com/genagent/gen_agent/commit/255ce7032ec6757f7f4fa5b56c27184c5e8a0465))

## [0.4.5](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.4.4...gen_agent_codex-v0.4.5) (2026-10-02)


### Bug Fixes

* **codex:** report completed-turn usage deltas ([#371](https://github.com/genagent/gen_agent/issues/371)) ([9d89ff3](https://github.com/genagent/gen_agent/commit/9d89ff3569b4bee3d1056f968c8bc1246416b4fa))

## [0.4.4](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.4.3...gen_agent_codex-v0.4.4) (2026-10-02)


### Bug Fixes

* **codex:** reject ephemeral and verbose session options ([#368](https://github.com/genagent/gen_agent/issues/368)) ([4935fc3](https://github.com/genagent/gen_agent/commit/4935fc3e3c0fb72f9025398d8748250c658e572a))

## [0.4.3](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.4.2...gen_agent_codex-v0.4.3) (2026-10-02)


### Bug Fixes

* **codex:** require wrapper with Forcola 0.4 support ([#362](https://github.com/genagent/gen_agent/issues/362)) ([378ff10](https://github.com/genagent/gen_agent/commit/378ff10e5d931704b7df6c3f5fac40f2924cdcf0))

## [0.4.2](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.4.1...gen_agent_codex-v0.4.2) (2026-10-02)


### Bug Fixes

* **deps:** allow core 0.7 in CLI adapters and Ensemble ([#327](https://github.com/genagent/gen_agent/issues/327)) ([f9d3a21](https://github.com/genagent/gen_agent/commit/f9d3a218b5e7beb82217f829c4b267c2f7504829))

## [0.4.1](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.4.0...gen_agent_codex-v0.4.1) (2026-10-02)


### Bug Fixes

* **backends:** require compatible core for CLI adapters ([#308](https://github.com/genagent/gen_agent/issues/308)) ([286f578](https://github.com/genagent/gen_agent/commit/286f578461e75de6e32a43a277b2b5150a2b0e44))

## [0.4.0](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.3.0...gen_agent_codex-v0.4.0) (2026-10-02)


### Features

* **core:** checkpoint CLI sessions during active turns ([52f2919](https://github.com/genagent/gen_agent/commit/52f2919f2e677a14b428b05f1ad6dd1628741cd0))

## [0.3.0](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.2.5...gen_agent_codex-v0.3.0) (2026-10-02)


### Features

* **codex:** forward config isolation and profile options ([#277](https://github.com/genagent/gen_agent/issues/277)) ([bd75f86](https://github.com/genagent/gen_agent/commit/bd75f86d6c17a5233e75597fb0f212a01bedcf59))

## [0.2.5](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.2.4...gen_agent_codex-v0.2.5) (2026-10-01)


### Bug Fixes

* accept gen_agent 0.5 in component packages ([#167](https://github.com/genagent/gen_agent/issues/167)) ([43272dd](https://github.com/genagent/gen_agent/commit/43272dd2a699927d8d1bdc42390e795f853b6c84))
* **codex:** distinguish unsupported options from resume limitations ([#162](https://github.com/genagent/gen_agent/issues/162)) ([6be8ef9](https://github.com/genagent/gen_agent/commit/6be8ef9f053069f9a4a71d158d877cb815eda627))
* **codex:** keep retry notifications nonterminal ([#155](https://github.com/genagent/gen_agent/issues/155)) ([0ad56d1](https://github.com/genagent/gen_agent/commit/0ad56d1f34acc9126e211264a204b9b3e7f29351))

## [0.2.4](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.2.3...gen_agent_codex-v0.2.4) (2026-10-01)


### Bug Fixes

* allow adapters to use gen_agent 0.4 ([#81](https://github.com/genagent/gen_agent/issues/81)) ([b78fada](https://github.com/genagent/gen_agent/commit/b78fadacf1221c8270239470637d8d88802f6a8d))

## [0.2.3](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.2.2...gen_agent_codex-v0.2.3) (2026-10-01)


### Bug Fixes

* preserve boundaries between Codex agent messages ([#74](https://github.com/genagent/gen_agent/issues/74)) ([e03b4f6](https://github.com/genagent/gen_agent/commit/e03b4f629787d91013a02854b4d875c40b8005fa))

## [0.2.2](https://github.com/genagent/gen_agent/compare/gen_agent_codex-v0.2.1...gen_agent_codex-v0.2.2) (2026-10-01)


### Bug Fixes

* repoint adapter source links after consolidation ([#55](https://github.com/genagent/gen_agent/issues/55)) ([6b81a75](https://github.com/genagent/gen_agent/commit/6b81a75beb4d9517c13d56a16b23176d86a60c67))

## [0.2.1](https://github.com/genagent/gen_agent_codex/compare/v0.2.0...v0.2.1) (2026-10-01)


### Bug Fixes

* support GenAgent 0.3.0 ([#21](https://github.com/genagent/gen_agent_codex/issues/21)) ([60ad407](https://github.com/genagent/gen_agent_codex/commit/60ad407847714c5bea3ecaad86ee4e180fecc004))

## [0.2.0](https://github.com/genagent/gen_agent_codex/compare/v0.1.2...v0.2.0) (2026-10-01)


### Features

* preserve output schema across Codex turns ([#19](https://github.com/genagent/gen_agent_codex/issues/19)) ([c84417d](https://github.com/genagent/gen_agent_codex/commit/c84417dc13bcfae2643fbdabd5412eab4539e26a))

## [0.1.2](https://github.com/genagent/gen_agent_codex/compare/v0.1.1...v0.1.2) (2026-09-30)


### Bug Fixes

* stream Codex turns and preserve resume options ([#13](https://github.com/genagent/gen_agent_codex/issues/13)) ([42a7553](https://github.com/genagent/gen_agent_codex/commit/42a75533d07f7b0682cad94b434d5013e7cc6bdb))

## [0.1.1](https://github.com/genagent/gen_agent_codex/compare/v0.1.0...v0.1.1) (2026-04-11)


### Bug Fixes

* update codex_wrapper_ex link to genagent org ([#2](https://github.com/genagent/gen_agent_codex/issues/2)) ([6c2da0d](https://github.com/genagent/gen_agent_codex/commit/6c2da0d0116ff575acf89abe359045470da82540))

## [0.1.0](https://github.com/genagent/gen_agent_codex/releases/tag/v0.1.0) (2026-04-11)


### Features

* initial release ([495faf9](https://github.com/genagent/gen_agent_codex/commit/495faf971607c6eb7200be15300f752b4b441a21))
