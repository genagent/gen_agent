import Config

# Tests start ensembles imperatively via `GenAgentEnsemble.start_link/1`.
# No auto-started ensembles in the test env.
config :gen_agent_ensemble, ensembles: []
