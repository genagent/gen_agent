import Config

# Ensembles declared here are started automatically when the
# `:gen_agent_ensemble` app boots, and are addressable by name via
# the public API (`GenAgentEnsemble.tell/2`, `ask/2`, `poll/2`,
# `inbox/1`, `status/1`, `stop/1`) from any iex session started
# with `iex -S mix`.
#
# Each entry is the same keyword list you would pass to
# `GenAgentEnsemble.start_link/1`: `:name`, `:strategy`, `:opts`.
#
# Secrets (API keys, tokens) do NOT belong here -- use
# `config/runtime.exs` for those, where `System.get_env/1` is
# available at runtime.
#
# The `echo` ensemble below is the only one enabled by default
# because it needs no API keys and no external processes. Every
# other template is commented out so a fresh clone doesn't
# auto-start ensembles that would fail 401 without credentials.
# Uncomment the ones you want, set the appropriate env vars, and
# restart iex.

config :gen_agent_ensemble,
  ensembles: [
    # Zero-setup demo. Every prompt is echoed back with an
    # "echo: " prefix via GenAgentEnsemble.Backends.Echo. No API
    # keys, no subprocess. Useful for trying the API and
    # prototyping before wiring a real backend.
    [
      name: "echo",
      strategy: GenAgentEnsemble.Strategies.Solo,
      opts: [
        agent:
          {"w", GenAgentEnsemble.Agents.Simple,
           backend: GenAgentEnsemble.Backends.Echo, delay_ms: 300}
      ]
    ]

    # -------------------------------------------------------------
    # Solo -- single agent, passthrough. Requires ANTHROPIC_API_KEY.
    # -------------------------------------------------------------
    # [
    #   name: "solo",
    #   strategy: GenAgentEnsemble.Strategies.Solo,
    #   opts: [
    #     agent:
    #       {"w", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        system: "You are a pragmatic Elixir reviewer.",
    #        model: "claude-sonnet-4-6"}
    #   ]
    # ],

    # -------------------------------------------------------------
    # Pool -- fixed-size worker pool. `tell` fans out across workers
    # in parallel; drain completed tokens with `inbox/1`. Requires
    # ANTHROPIC_API_KEY.
    # -------------------------------------------------------------
    # [
    #   name: "qa-pool",
    #   strategy: GenAgentEnsemble.Strategies.Pool,
    #   opts: [
    #     worker_count: 3,
    #     worker_template:
    #       {"qa", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        system: "Answer tersely. One paragraph max.",
    #        model: "claude-sonnet-4-6"}
    #   ]
    # ],

    # -------------------------------------------------------------
    # Switchboard -- named fleet, caller routes with `agent:` opt.
    # Requires ANTHROPIC_API_KEY.
    # -------------------------------------------------------------
    # [
    #   name: "reviewers",
    #   strategy: GenAgentEnsemble.Strategies.Switchboard,
    #   opts: [
    #     agents: [
    #       {"alice", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        system: "You review API design."},
    #       {"bob", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        system: "You review performance."}
    #     ]
    #   ]
    # ],

    # -------------------------------------------------------------
    # Pipeline -- linear N-stage chain. Each stage's response text
    # becomes the next stage's prompt. Requires ANTHROPIC_API_KEY.
    # -------------------------------------------------------------
    # [
    #   name: "brainstorm",
    #   strategy: GenAgentEnsemble.Strategies.Pipeline,
    #   opts: [
    #     stages: [
    #       {"ideator", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        system: "List 5 ideas for the given topic."},
    #       {"editor", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        system: "Pick the best idea from this list and explain why."},
    #       {"headliner", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        system: "Write a single punchy one-line headline."}
    #     ]
    #   ]
    # ],

    # -------------------------------------------------------------
    # Supervisor -- coordinator decomposes, N workers fan out in
    # parallel, synthesizer combines. Requires a user-defined
    # decomposer function, so this template assumes a module exists
    # at `MyApp.Research` with `decompose/1` and an optional
    # `synthesize/1`. Requires ANTHROPIC_API_KEY.
    # -------------------------------------------------------------
    # [
    #   name: "research",
    #   strategy: GenAgentEnsemble.Strategies.Supervisor,
    #   opts: [
    #     coordinator:
    #       {"lead", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        system: "Decompose the question into 3-5 focused sub-questions, one per line."},
    #     worker_template:
    #       {"researcher", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        system: "Answer the given sub-question concretely in 2-3 sentences."},
    #     decomposer: &MyApp.Research.decompose/1,
    #     synthesizer: &MyApp.Research.synthesize/1
    #   ]
    # ],

    # -------------------------------------------------------------
    # Debate -- two agents alternate until they converge or hit the
    # round cap. Cross-backend debate surfaces disagreements a
    # single model would have hidden. Requires ANTHROPIC_API_KEY
    # and OPENAI_API_KEY.
    # -------------------------------------------------------------
    # [
    #   name: "xmodel-debate",
    #   strategy: GenAgentEnsemble.Strategies.Debate,
    #   opts: [
    #     agents: [
    #       {"anthropic", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        model: "claude-sonnet-4-6",
    #        receive_timeout: 180_000,
    #        max_tokens: 2048,
    #        system:
    #          "You are a senior engineer arguing one side of an architecture decision. " <>
    #            "Be concrete, cite real tradeoffs, respond directly to the other side's " <>
    #            "points. 3-5 tight sentences. Concede explicitly when the other side is right."},
    #       {"openai", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.OpenAI,
    #        model: "gpt-5-mini",
    #        max_output_tokens: 2048,
    #        system:
    #          "You are a senior engineer arguing one side of an architecture decision. " <>
    #            "Be concrete, cite real tradeoffs, respond directly to the other side's " <>
    #            "points. 3-5 tight sentences. Concede explicitly when the other side is right."}
    #     ],
    #     rounds: 4,
    #     reply: :transcript
    #   ]
    # ],

    # -------------------------------------------------------------
    # Consensus -- N peer agents deliberate until they converge on
    # a structured verdict, or return a divergence report at the
    # round cap. Requires a user-defined verdict parser; this
    # template assumes `MyApp.DecisionParser.parse/1` returns
    # `{:ok, :approve | :revise | :reject, rationale} | :error`.
    # Requires ANTHROPIC_API_KEY.
    # -------------------------------------------------------------
    # [
    #   name: "arch-review",
    #   strategy: GenAgentEnsemble.Strategies.Consensus,
    #   opts: [
    #     agents: [
    #       {"sonnet", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        model: "claude-sonnet-4-6",
    #        receive_timeout: 180_000,
    #        system: "You review technical proposals. End every response with VERDICT: APPROVE | REVISE | REJECT."},
    #       {"haiku", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Anthropic,
    #        model: "claude-haiku-4-5-20251001",
    #        system: "You review technical proposals. End every response with VERDICT: APPROVE | REVISE | REJECT."},
    #       {"claude-cli", GenAgentEnsemble.Agents.Simple,
    #        backend: GenAgent.Backends.Claude,
    #        system_prompt: "You review technical proposals. End every response with VERDICT: APPROVE | REVISE | REJECT."}
    #     ],
    #     verdict_parser: &MyApp.DecisionParser.parse/1,
    #     threshold: :majority,
    #     rounds: 3,
    #     reply: :synthesis
    #   ]
    # ]
  ]

import_config "#{config_env()}.exs"
