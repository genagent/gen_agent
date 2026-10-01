# Changelog

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

## [0.1.0](https://github.com/genagent/gen_agent_ensemble/compare/v0.1.0...v0.1.0) (2026-04-18)


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

## Changelog
