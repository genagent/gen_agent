# Changelog

## [0.4.2](https://github.com/genagent/gen_agent/compare/gen_agent_anthropic-v0.4.1...gen_agent_anthropic-v0.4.2) (2026-10-06)


### Bug Fixes

* **deps:** test HTTP adapters with published core 0.7 ([#406](https://github.com/genagent/gen_agent/issues/406)) ([ce57268](https://github.com/genagent/gen_agent/commit/ce57268f57d6893b10d5bdf501e022953a85a8d6))

## [0.4.1](https://github.com/genagent/gen_agent/compare/gen_agent_anthropic-v0.4.0...gen_agent_anthropic-v0.4.1) (2026-10-03)


### Bug Fixes

* **backends:** validate options and align shared names ([#389](https://github.com/genagent/gen_agent/issues/389)) ([68abf7c](https://github.com/genagent/gen_agent/commit/68abf7cde4ca185980ac3f8375d94390f98bf3d4))

## [0.4.0](https://github.com/genagent/gen_agent/compare/gen_agent_anthropic-v0.3.0...gen_agent_anthropic-v0.4.0) (2026-10-03)


### Features

* **examples:** primitive examples 04 to 06, an examples index, and HTTP testing recipes ([#317](https://github.com/genagent/gen_agent/issues/317)) ([6eb6691](https://github.com/genagent/gen_agent/commit/6eb6691129eea348d49de7c7abe29dcb76255426))


### Bug Fixes

* **anthropic:** reject incomplete and refused stops ([#381](https://github.com/genagent/gen_agent/issues/381)) ([b26cec6](https://github.com/genagent/gen_agent/commit/b26cec69ec774374421acd37aeb7329889858600))
* **backends:** reject HTTP redirects from provider endpoints ([#378](https://github.com/genagent/gen_agent/issues/378)) ([49f719c](https://github.com/genagent/gen_agent/commit/49f719cd2ed15367cc7a94a9a7d7b28169e2e57f))

## [0.3.0](https://github.com/genagent/gen_agent/compare/gen_agent_anthropic-v0.2.5...gen_agent_anthropic-v0.3.0) (2026-10-02)


### Features

* **core:** checkpoint CLI sessions during active turns ([52f2919](https://github.com/genagent/gen_agent/commit/52f2919f2e677a14b428b05f1ad6dd1628741cd0))


### Bug Fixes

* **anthropic:** skip whitespace-only assistant history ([b3e1cb2](https://github.com/genagent/gen_agent/commit/b3e1cb296a85e961b0da4edc56f4c11938bc7df6))
* **backends:** fail to start HTTP backends without credentials ([3a10e03](https://github.com/genagent/gen_agent/commit/3a10e034176e49a1c138fde95c2d64bcfb9244ad))

## [0.2.5](https://github.com/genagent/gen_agent/compare/gen_agent_anthropic-v0.2.4...gen_agent_anthropic-v0.2.5) (2026-10-02)


### Bug Fixes

* redact sensitive agent state from diagnostics ([#280](https://github.com/genagent/gen_agent/issues/280)) ([3038766](https://github.com/genagent/gen_agent/commit/3038766b00c1854a2db31ca74bba5a48da13c9ad))

## [0.2.4](https://github.com/genagent/gen_agent/compare/gen_agent_anthropic-v0.2.3...gen_agent_anthropic-v0.2.4) (2026-10-01)


### Bug Fixes

* accept gen_agent 0.5 in component packages ([#167](https://github.com/genagent/gen_agent/issues/167)) ([43272dd](https://github.com/genagent/gen_agent/commit/43272dd2a699927d8d1bdc42390e795f853b6c84))
* **anthropic:** discard unanswered turns after empty responses ([#153](https://github.com/genagent/gen_agent/issues/153)) ([990ac79](https://github.com/genagent/gen_agent/commit/990ac79acb1b13dfba07fba3542a9f2817e7edbb))

## [0.2.3](https://github.com/genagent/gen_agent/compare/gen_agent_anthropic-v0.2.2...gen_agent_anthropic-v0.2.3) (2026-10-01)


### Bug Fixes

* allow adapters to use gen_agent 0.4 ([#81](https://github.com/genagent/gen_agent/issues/81)) ([b78fada](https://github.com/genagent/gen_agent/commit/b78fadacf1221c8270239470637d8d88802f6a8d))

## [0.2.2](https://github.com/genagent/gen_agent/compare/gen_agent_anthropic-v0.2.1...gen_agent_anthropic-v0.2.2) (2026-10-01)


### Bug Fixes

* repoint adapter source links after consolidation ([#55](https://github.com/genagent/gen_agent/issues/55)) ([6b81a75](https://github.com/genagent/gen_agent/commit/6b81a75beb4d9517c13d56a16b23176d86a60c67))

## [0.2.1](https://github.com/genagent/gen_agent_anthropic/compare/v0.2.0...v0.2.1) (2026-10-01)


### Bug Fixes

* support GenAgent 0.3.0 ([#16](https://github.com/genagent/gen_agent_anthropic/issues/16)) ([880e02d](https://github.com/genagent/gen_agent_anthropic/commit/880e02dc884a800b3274d015f3a9d4534ca9e075))

## [0.2.0](https://github.com/genagent/gen_agent_anthropic/compare/v0.1.0...v0.2.0) (2026-04-18)


### Features

* accept :receive_timeout and :connect_timeout backend opts ([#3](https://github.com/genagent/gen_agent_anthropic/issues/3)) ([2d7225c](https://github.com/genagent/gen_agent_anthropic/commit/2d7225ce6f9177da4085e86eb0c0979b9125006f))

## [0.1.0](https://github.com/genagent/gen_agent_anthropic/releases/tag/v0.1.0) (2026-04-11)


### Features

* initial release ([c7f5e2f](https://github.com/genagent/gen_agent_anthropic/commit/c7f5e2f772366700d593fef2df80f96ddffef1cd))
