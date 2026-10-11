# Changelog

## [0.7.0](https://github.com/genagent/gen_agent/compare/gen_agent_ensemble-v0.6.1...gen_agent_ensemble-v0.7.0) (2026-10-11)


### Features

* **core:** publish scripted mock backend ([#416](https://github.com/genagent/gen_agent/issues/416)) ([bcb801f](https://github.com/genagent/gen_agent/commit/bcb801ff9d929121c2c425c7d930770037b56607))


### Bug Fixes

* **core:** attribute startup failures to the right component ([#366](https://github.com/genagent/gen_agent/issues/366)) ([1ffbe5c](https://github.com/genagent/gen_agent/commit/1ffbe5ce12b1793bd2d75f2ded1e051db877e95f))
* **core:** return not_found for missing agent calls ([#379](https://github.com/genagent/gen_agent/issues/379)) ([c78c718](https://github.com/genagent/gen_agent/commit/c78c718385f23eddce8d23c3fa903160af074ca9))
* **deps:** test HTTP adapters with published core 0.7 ([#406](https://github.com/genagent/gen_agent/issues/406)) ([ce57268](https://github.com/genagent/gen_agent/commit/ce57268f57d6893b10d5bdf501e022953a85a8d6))
* **ensemble:** bound retained tell results ([#484](https://github.com/genagent/gen_agent/issues/484)) ([d009810](https://github.com/genagent/gen_agent/commit/d00981066e2890f052c0c22bec0814e8cbb7bdc1))
* **ensemble:** close tokens without optional failure callbacks ([#457](https://github.com/genagent/gen_agent/issues/457)) ([2627459](https://github.com/genagent/gen_agent/commit/262745984d7e774ac04333592e21f45d3bce9521))
* **ensemble:** configure and document ask timeouts ([#485](https://github.com/genagent/gen_agent/issues/485)) ([75ab38e](https://github.com/genagent/gen_agent/commit/75ab38e099e0bd987b4385dd7e4f7bff4136d373))
* **ensemble:** contain built-in user function failures ([#460](https://github.com/genagent/gen_agent/issues/460)) ([1f82da7](https://github.com/genagent/gen_agent/commit/1f82da7766b3f846da8b69aa9521bdbd1fab2e75))
* **ensemble:** correct production config and package metadata ([#475](https://github.com/genagent/gen_agent/issues/475)) ([4186000](https://github.com/genagent/gen_agent/commit/41860000a96e5315db36cf7fcee08a1fb9edbb91))
* **ensemble:** expose caller-supervised child specifications ([#483](https://github.com/genagent/gen_agent/issues/483)) ([b139f51](https://github.com/genagent/gen_agent/commit/b139f510f57add50d72a6518cd4a2835292ea8f4))
* **ensemble:** expose typed Consensus decisions ([#477](https://github.com/genagent/gen_agent/issues/477)) ([b07d2bd](https://github.com/genagent/gen_agent/commit/b07d2bd89eaddbddec80b712995b793955ac5e29))
* **ensemble:** finish owned tree shutdown before session exit ([#456](https://github.com/genagent/gen_agent/issues/456)) ([a26f279](https://github.com/genagent/gen_agent/commit/a26f279b52064107e64efe9637692068d94a907e))
* **ensemble:** keep configured sessions stopped after normal exits ([#459](https://github.com/genagent/gen_agent/issues/459)) ([90a02ff](https://github.com/genagent/gen_agent/commit/90a02ff0236e058cf72e0faf422a1a2052801d13))
* **ensemble:** link owner before session initialization ([#444](https://github.com/genagent/gen_agent/issues/444)) ([d28e57b](https://github.com/genagent/gen_agent/commit/d28e57be27a84a054cca6e698ebeac34afbc29f5))
* **ensemble:** preserve completed Supervisor workers and reply before cleanup ([#458](https://github.com/genagent/gen_agent/issues/458)) ([d56ff98](https://github.com/genagent/gen_agent/commit/d56ff9812f3190b161b14e1ea85bee7a1f3c9a45))
* **ensemble:** reject invalid Supervisor worker options during startup ([#474](https://github.com/genagent/gen_agent/issues/474)) ([88b0398](https://github.com/genagent/gen_agent/commit/88b03982ea85d3e3a27eb421ac4415773f53628e))
* **ensemble:** retain partial outputs in optional failure replies ([#468](https://github.com/genagent/gen_agent/issues/468)) ([f703261](https://github.com/genagent/gen_agent/commit/f70326192808b9128039001c73d734a121119d89))
* **ensemble:** validate strategy startup options ([#455](https://github.com/genagent/gen_agent/issues/455)) ([f852c0e](https://github.com/genagent/gen_agent/commit/f852c0ec522a6c52af7563a4aa2b83b296dbb99e))

## [0.6.1](https://github.com/genagent/gen_agent/compare/gen_agent_ensemble-v0.6.0...gen_agent_ensemble-v0.6.1) (2026-10-02)


### Bug Fixes

* **ensemble:** bound Supervisor fan-out ([#358](https://github.com/genagent/gen_agent/issues/358)) ([cd32dbc](https://github.com/genagent/gen_agent/commit/cd32dbc5bf3b7bc42f0b25534813358227898906))
* **ensemble:** keep original topic in debate turns ([#364](https://github.com/genagent/gen_agent/issues/364)) ([4d84f1c](https://github.com/genagent/gen_agent/commit/4d84f1c5da42dc0ff0be34e116f03f02797dc7fd))
* **ensemble:** require unique consensus and tolerate reachable errors ([#365](https://github.com/genagent/gen_agent/issues/365)) ([c5b689a](https://github.com/genagent/gen_agent/commit/c5b689a8219ae3eb827042e90bf48af564528cbb))

## [0.6.0](https://github.com/genagent/gen_agent/compare/gen_agent_ensemble-v0.5.0...gen_agent_ensemble-v0.6.0) (2026-10-02)


### Features

* **ensemble:** cancel tokens without stopping the session ([#339](https://github.com/genagent/gen_agent/issues/339)) ([e5cf390](https://github.com/genagent/gen_agent/commit/e5cf39039c246c10ae8b550c31f96cbd8c90fa68))
* **ensemble:** notify token completion and await without polling ([#337](https://github.com/genagent/gen_agent/issues/337)) ([521f62d](https://github.com/genagent/gen_agent/commit/521f62d9ff619fcb01c20d35a8fc5bf2ec02563f))

## [0.5.0](https://github.com/genagent/gen_agent/compare/gen_agent_ensemble-v0.4.0...gen_agent_ensemble-v0.5.0) (2026-10-02)


### Features

* **ensemble:** include subtasks in Supervisor synthesis ([#323](https://github.com/genagent/gen_agent/issues/323)) ([47864f4](https://github.com/genagent/gen_agent/commit/47864f4bd3e6a9cea058f5ad89597673b5a2e061))


### Bug Fixes

* **deps:** allow core 0.7 in CLI adapters and Ensemble ([#327](https://github.com/genagent/gen_agent/issues/327)) ([f9d3a21](https://github.com/genagent/gen_agent/commit/f9d3a218b5e7beb82217f829c4b267c2f7504829))

## [0.4.0](https://github.com/genagent/gen_agent/compare/gen_agent_ensemble-v0.3.0...gen_agent_ensemble-v0.4.0) (2026-10-02)


### Features

* **ensemble:** aggregate usage across multi-agent strategies ([#319](https://github.com/genagent/gen_agent/issues/319)) ([89fa88b](https://github.com/genagent/gen_agent/commit/89fa88b6fa876caf844c14e949d81606fcd4c563))

## [0.3.0](https://github.com/genagent/gen_agent/compare/gen_agent_ensemble-v0.2.1...gen_agent_ensemble-v0.3.0) (2026-10-02)


### Features

* **core:** checkpoint CLI sessions during active turns ([52f2919](https://github.com/genagent/gen_agent/commit/52f2919f2e677a14b428b05f1ad6dd1628741cd0))


### Bug Fixes

* **ensemble:** complete dispatches when members halt ([#284](https://github.com/genagent/gen_agent/issues/284)) ([a6bac3d](https://github.com/genagent/gen_agent/commit/a6bac3d855bf188081d6693f9180ecc682f27336))
* **ensemble:** preserve Supervisor subtask output order ([#275](https://github.com/genagent/gen_agent/issues/275)) ([bd7d1f0](https://github.com/genagent/gen_agent/commit/bd7d1f0cd9802a91da308f59064472dfc5fbb3bc))
* **ensemble:** reject dispatch when sub-agent is unavailable ([#271](https://github.com/genagent/gen_agent/issues/271)) ([14dc36d](https://github.com/genagent/gen_agent/commit/14dc36dd8c5ffd3104162704d784c611777089f3))
* **ensemble:** require core 0.6 for completion-aware dispatch ([d5d0d39](https://github.com/genagent/gen_agent/commit/d5d0d3926698858625b4127cc4bd7d94ecbec6bc))
* **ensemble:** rotate Pool workers and replace dead workers ([#279](https://github.com/genagent/gen_agent/issues/279)) ([d317639](https://github.com/genagent/gen_agent/commit/d317639c654bd5826576a047853d34b692a4f12e))
* redact sensitive agent state from diagnostics ([#280](https://github.com/genagent/gen_agent/issues/280)) ([3038766](https://github.com/genagent/gen_agent/commit/3038766b00c1854a2db31ca74bba5a48da13c9ad))

## [0.2.1](https://github.com/genagent/gen_agent/compare/gen_agent_ensemble-v0.2.0...gen_agent_ensemble-v0.2.1) (2026-10-01)


### Bug Fixes

* accept gen_agent 0.5 in component packages ([#167](https://github.com/genagent/gen_agent/issues/167)) ([43272dd](https://github.com/genagent/gen_agent/commit/43272dd2a699927d8d1bdc42390e795f853b6c84))

## [0.2.0](https://github.com/genagent/gen_agent/compare/gen_agent_ensemble-v0.1.4...gen_agent_ensemble-v0.2.0) (2026-10-01)


### Features

* emit observational Ensemble lifecycle telemetry ([#86](https://github.com/genagent/gen_agent/issues/86)) ([cd78875](https://github.com/genagent/gen_agent/commit/cd7887542bcfeee2804c2840f2b66b8a8424386c))

## [0.1.4](https://github.com/genagent/gen_agent/compare/gen_agent_ensemble-v0.1.3...gen_agent_ensemble-v0.1.4) (2026-10-01)


### Bug Fixes

* **ensemble:** finish tokens when dispatch is rejected ([#65](https://github.com/genagent/gen_agent/issues/65)) ([b4d42a9](https://github.com/genagent/gen_agent/commit/b4d42a9d336d223e4856dd77b88da8b6477bd1f8))

## [0.1.3](https://github.com/genagent/gen_agent/compare/gen_agent_ensemble-v0.1.2...gen_agent_ensemble-v0.1.3) (2026-10-01)


### Bug Fixes

* **ensemble:** own agents for session lifetime ([#62](https://github.com/genagent/gen_agent/issues/62)) ([e574683](https://github.com/genagent/gen_agent/commit/e574683574f94d5b07219bbd6c10770bc3cf657e))

## [0.1.2](https://github.com/genagent/gen_agent/compare/gen_agent_ensemble-v0.1.1...gen_agent_ensemble-v0.1.2) (2026-10-01)


### Bug Fixes

* **ensemble:** publish GenAgent 0.3 compatibility ([#51](https://github.com/genagent/gen_agent/issues/51)) ([89b7a23](https://github.com/genagent/gen_agent/commit/89b7a233fad9ce658bb5493ccd3595d38d86dfdc))

## [0.1.1](https://github.com/genagent/gen_agent_ensemble/compare/v0.1.0...v0.1.1) (2026-10-01)


### Bug Fixes

* fail supervisor runs when a worker dies ([#20](https://github.com/genagent/gen_agent_ensemble/issues/20)) ([71171ae](https://github.com/genagent/gen_agent_ensemble/commit/71171ae2350f1ed2d667684028e116faed328a77))
* fence ensemble responses by run token ([#18](https://github.com/genagent/gen_agent_ensemble/issues/18)) ([43bf5ea](https://github.com/genagent/gen_agent_ensemble/commit/43bf5eae3185a7166f09d60726445e009cfa8e08))

## [0.1.0](https://github.com/genagent/gen_agent_ensemble/releases/tag/v0.1.0) (2026-04-18)


### ⚠ BREAKING CHANGES

* GenAgentEnsemble.ask/3 no longer accepts a bare integer timeout. Pass `timeout: ms` in opts instead.
* GenAgentEnsemble.chat/1 is removed.

### Features

* add Echo backend for zero-setup iex dogfooding ([9f76a2b](https://github.com/genagent/gen_agent_ensemble/commit/9f76a2bd48f51c901d40abb4a569f3f7eb0f9631))
* add GenAgentEnsemble.IEx module with REPL helpers ([f2c0727](https://github.com/genagent/gen_agent_ensemble/commit/f2c0727146b4fd9e0e185b197559bd9a76e1ccbc))
* ask/3 takes opts keyword list instead of integer timeout ([55ea3e4](https://github.com/genagent/gen_agent_ensemble/commit/55ea3e47f894a0520449dd757d67cc16ec7940bd))
* Consensus strategy for N-agent structured verdict voting ([e7ec318](https://github.com/genagent/gen_agent_ensemble/commit/e7ec31842ee847a90f24d0d6fa3a748848f7933b))
* Debate strategy for two-agent cross-argument ([6ee531f](https://github.com/genagent/gen_agent_ensemble/commit/6ee531fe1e4bf4c585afaa3fb2533291282421de))
* initial release ([8bbf88c](https://github.com/genagent/gen_agent_ensemble/commit/8bbf88c4d46c74af75baee827df729a1ac2b2613))
* line-oriented chat REPL over a running ensemble ([881b59f](https://github.com/genagent/gen_agent_ensemble/commit/881b59ffbd8de4c841d2d18ce56c0a89df74d0b3))
* Switchboard strategy for caller-routed named fleets ([e9db390](https://github.com/genagent/gen_agent_ensemble/commit/e9db39066d215ba418c95163bd873c7cf0b85e49))


### Bug Fixes

* namespace sub-agent names by session to prevent cross-ensemble collision ([913ba39](https://github.com/genagent/gen_agent_ensemble/commit/913ba39b45802c93906c905d6b1a482313d2583d))
* unwrap {:ok, map} in /status command output ([de1321d](https://github.com/genagent/gen_agent_ensemble/commit/de1321d5fe8397d8646a93825867047204864826))


### Miscellaneous Chores

* set up release-please workflow for hex publishing ([#7](https://github.com/genagent/gen_agent_ensemble/issues/7)) ([5dc455a](https://github.com/genagent/gen_agent_ensemble/commit/5dc455a06626ad18acba4b7ef3f5d00f866312fc)), closes [#3](https://github.com/genagent/gen_agent_ensemble/issues/3)


### Code Refactoring

* drop in-iex chat REPL, lean on native iex with .iex.exs ([77aa4a6](https://github.com/genagent/gen_agent_ensemble/commit/77aa4a6d73cb57a3f911e54fe54c674b74263c7e))
