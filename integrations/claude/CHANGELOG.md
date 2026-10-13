# Changelog

## [0.2.7](https://github.com/genagent/gen_agent/compare/gen_agent_claude-v0.2.6...gen_agent_claude-v0.2.7) (2026-10-05)


### Bug Fixes

* **claude:** preserve parent attribution across interleaved events ([#399](https://github.com/genagent/gen_agent/issues/399)) ([8631d7b](https://github.com/genagent/gen_agent/commit/8631d7b6bde8351ab0a55686b2adc1aca5f11cf7))

## [0.2.6](https://github.com/genagent/gen_agent/compare/gen_agent_claude-v0.2.5...gen_agent_claude-v0.2.6) (2026-10-05)


### Bug Fixes

* **backends:** align CLI adapter wrapper constraints ([#396](https://github.com/genagent/gen_agent/issues/396)) ([#397](https://github.com/genagent/gen_agent/issues/397)) ([ecbbec4](https://github.com/genagent/gen_agent/commit/ecbbec479745689685a78ec0aa1b7c2e8aaad4c2))

## [0.2.5](https://github.com/genagent/gen_agent/compare/gen_agent_claude-v0.2.4...gen_agent_claude-v0.2.5) (2026-10-03)


### Bug Fixes

* **backends:** validate options and align shared names ([#389](https://github.com/genagent/gen_agent/issues/389)) ([68abf7c](https://github.com/genagent/gen_agent/commit/68abf7cde4ca185980ac3f8375d94390f98bf3d4))

## [0.2.4](https://github.com/genagent/gen_agent/compare/gen_agent_claude-v0.2.3...gen_agent_claude-v0.2.4) (2026-10-02)


### Bug Fixes

* **claude:** preserve CLI result text and errors ([#375](https://github.com/genagent/gen_agent/issues/375)) ([0ea224b](https://github.com/genagent/gen_agent/commit/0ea224bc69fb394625388474ede02676d5b59a5c))

## [0.2.3](https://github.com/genagent/gen_agent/compare/gen_agent_claude-v0.2.2...gen_agent_claude-v0.2.3) (2026-10-02)


### Bug Fixes

* **claude:** validate backend options before session start ([#373](https://github.com/genagent/gen_agent/issues/373)) ([158765c](https://github.com/genagent/gen_agent/commit/158765c71d3dd844053c54286606897d35b4708f))

## [0.2.2](https://github.com/genagent/gen_agent/compare/gen_agent_claude-v0.2.1...gen_agent_claude-v0.2.2) (2026-10-02)


### Bug Fixes

* **deps:** allow core 0.7 in CLI adapters and Ensemble ([#327](https://github.com/genagent/gen_agent/issues/327)) ([f9d3a21](https://github.com/genagent/gen_agent/commit/f9d3a218b5e7beb82217f829c4b267c2f7504829))

## [0.2.1](https://github.com/genagent/gen_agent/compare/gen_agent_claude-v0.2.0...gen_agent_claude-v0.2.1) (2026-10-02)


### Bug Fixes

* **backends:** require compatible core for CLI adapters ([#308](https://github.com/genagent/gen_agent/issues/308)) ([286f578](https://github.com/genagent/gen_agent/commit/286f578461e75de6e32a43a277b2b5150a2b0e44))

## [0.2.0](https://github.com/genagent/gen_agent/compare/gen_agent_claude-v0.1.5...gen_agent_claude-v0.2.0) (2026-10-02)


### Features

* **core:** checkpoint CLI sessions during active turns ([52f2919](https://github.com/genagent/gen_agent/commit/52f2919f2e677a14b428b05f1ad6dd1628741cd0))


### Bug Fixes

* **core:** compact retained events without losing turns ([#282](https://github.com/genagent/gen_agent/issues/282)) ([f9c9375](https://github.com/genagent/gen_agent/commit/f9c9375adbc4ef446f2bc52e336ac0006da5399c))

## [0.1.5](https://github.com/genagent/gen_agent/compare/gen_agent_claude-v0.1.4...gen_agent_claude-v0.1.5) (2026-10-01)


### Bug Fixes

* accept gen_agent 0.5 in component packages ([#167](https://github.com/genagent/gen_agent/issues/167)) ([43272dd](https://github.com/genagent/gen_agent/commit/43272dd2a699927d8d1bdc42390e795f853b6c84))
* **claude:** avoid conflicting resume options ([#154](https://github.com/genagent/gen_agent/issues/154)) ([f2de272](https://github.com/genagent/gen_agent/commit/f2de27263b9190d572f8a7ee47da3013733ec4bf))
* **claude:** require escaped CLI binary paths ([#166](https://github.com/genagent/gen_agent/issues/166)) ([151dbfd](https://github.com/genagent/gen_agent/commit/151dbfdf8859097214c5512870602507979d066b))

## [0.1.4](https://github.com/genagent/gen_agent/compare/gen_agent_claude-v0.1.3...gen_agent_claude-v0.1.4) (2026-10-01)


### Bug Fixes

* allow adapters to use gen_agent 0.4 ([#81](https://github.com/genagent/gen_agent/issues/81)) ([b78fada](https://github.com/genagent/gen_agent/commit/b78fadacf1221c8270239470637d8d88802f6a8d))

## [0.1.3](https://github.com/genagent/gen_agent/compare/gen_agent_claude-v0.1.2...gen_agent_claude-v0.1.3) (2026-10-01)


### Bug Fixes

* repoint adapter source links after consolidation ([#55](https://github.com/genagent/gen_agent/issues/55)) ([6b81a75](https://github.com/genagent/gen_agent/commit/6b81a75beb4d9517c13d56a16b23176d86a60c67))

## [0.1.2](https://github.com/genagent/gen_agent_claude/compare/v0.1.1...v0.1.2) (2026-10-01)


### Bug Fixes

* support GenAgent 0.3.0 ([#24](https://github.com/genagent/gen_agent_claude/issues/24)) ([228e03e](https://github.com/genagent/gen_agent_claude/commit/228e03ebfefdd8cdbee3608c2d40cff1b1b3eeec))

## [0.1.1](https://github.com/genagent/gen_agent_claude/compare/v0.1.0...v0.1.1) (2026-09-30)


### Bug Fixes

* refresh Claude backend stream translation ([#18](https://github.com/genagent/gen_agent_claude/issues/18)) ([1300db2](https://github.com/genagent/gen_agent_claude/commit/1300db2c1a3dd23e5e25d7b1a886f9af3fcb07b1))

## [0.1.0](https://github.com/genagent/gen_agent_claude/releases/tag/v0.1.0) (2026-04-11)


### Features

* initial release ([1470189](https://github.com/genagent/gen_agent_claude/commit/1470189ad4c86282123c2c0cefa485ee5501a629))
