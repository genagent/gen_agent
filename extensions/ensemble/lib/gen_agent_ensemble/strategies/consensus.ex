defmodule GenAgentEnsemble.Strategies.Consensus do
  @moduledoc """
  N peer agents deliberate on a prompt until they converge on a
  structured verdict, or the round cap is reached.

  Each round fans the prompt out to every agent in parallel. Each
  agent's response is parsed by a user-supplied `:verdict_parser`
  into a categorical verdict atom plus rationale. If a threshold
  number of agents agree on the same verdict, the session
  converges. Otherwise, each agent is re-prompted with the *other*
  agents' responses as context and asked to revise or confirm its
  position.

  Unparseable responses become **abstains** -- they don't count
  toward the threshold but don't block convergence either. The
  abstaining agent still participates in subsequent rounds.

  Convergence requires a **unique leading verdict** whose count meets
  the threshold. If two verdicts tie for the highest count (possible
  with `{:at_least, n}` when `n <= N/2`), the round does not converge:
  the panel is re-prompted, or diverges at the round cap.

  Unlike `GenAgentEnsemble.Strategies.Debate`, Consensus's output
  is a *programmable decision*: the strategy holds a parsed verdict
  atom and the reply synthesizes it alongside per-agent rationales.
  This turns LLM deliberation into `:approve | :revise | :reject`
  that callers can branch on without re-parsing prose.

  ## Options

    * `:failure_reply` (optional) -- `:legacy` (default) preserves existing
      reasons. `:structured` returns `GenAgentEnsemble.Strategies.Failure`
      for handled terminal turn, dispatch and guarded callback failures,
      with completed text partials. Agent death, halt, cancellation, timeout,
      initialization and custom strategy failures keep their existing contracts.

    * `:agents` (required) -- list of `{name, module, opts}` specs,
      2 or more. Names must be distinct. Every entry must be a
      `{name, module, keyword_opts}` tuple; a malformed entry raises
      `ArgumentError` at init naming only its index.
    * `:verdict_parser` (required) -- `(String.t() -> {:ok, atom,
      String.t()} | :error)`. Called on each agent's response text.
      The atom is the verdict category (never `nil`); the string is the
      rationale with verdict markers stripped. `:error` abstains; any
      other return fails the token (see Failure semantics).
    * `:threshold` (optional) -- convergence rule. Defaults to
      `:majority`.
        * `:unanimous` -- all parseable verdicts agree AND no
          abstains.
        * `:majority` -- more than N/2 agents agree on the same
          verdict.
        * `{:at_least, n}` -- at least `n` agents agree on the same
          verdict.
    * `:rounds` (optional) -- hard cap on rounds; a positive integer.
      Defaults to 3.
      Exceeding the cap returns a divergence report.
    * `:reply` (optional) -- response shape:
        * `:synthesis` (default) -- converged case: verdict +
          each agent's rationale. Diverged case: divergence report
          with each agent's final position.
        * `{:synthesize, fun}` -- call `fun.(summary)` where
          summary is `%{status, verdict, rounds, threshold, responses}`.
          `responses` is `[{agent_name, verdict_or_nil, rationale,
          raw_text}, ...]` in agent order; `verdict` is nil when
          diverged.

  ## Concurrency

  One consensus at a time per ensemble. Additional `tell`/`ask`
  calls queue FIFO and run after the current one completes.

  ## Failure semantics

    * A turn error is tolerated while the threshold is still
      reachable. The failed agent is recorded as an abstain for the
      round (nil verdict, an explanatory rationale, empty raw text) and
      the round waits for the remaining agents. The panel size stays
      fixed, so the required vote count does not shrink.
    * If the largest current vote count plus the outstanding turns can
      no longer meet the threshold, the token fails with the first
      `{agent, reason}` of the round, any in-flight parallel responses
      are discarded, and the next queued prompt (if any) starts.
      `:unanimous` therefore fails on the first turn error.
    * Tolerated errors are tracked per round. Each re-prompted round
      starts clean, and a failed agent is dispatched again.
    * Agent process death halts the session -- the panel size is
      fixed; a missing agent invalidates the threshold.
    * A `:verdict_parser` that returns `:error` abstains. A parser that
      raises, throws or exits, or returns anything other than `:error` or
      `{:ok, verdict, rationale}` (a non-nil atom and a binary), fails the
      token; so does a `{:synthesize, fun}` reply function that fails or
      returns a non-binary. The caller receives
      `{:error, {:strategy_function_failed, label, kind, class}}` or
      `{:error, {:invalid_strategy_result, label}}`, where `label` is
      `:verdict_parser` or `:synthesizer_reply`, `kind` is `:error`,
      `:throw` or `:exit`, and `class` is the exception module or
      `:other`. Messages, stacktraces and returned values are never
      included. In-flight responses are discarded, the session keeps
      running and the next queued prompt starts.
  """

  @behaviour GenAgentEnsemble.Strategy

  alias GenAgent.Response
  alias GenAgentEnsemble.Queue
  alias GenAgentEnsemble.Strategies.{Failure, Guard}
  alias GenAgentEnsemble.Usage

  defstruct [
    :agents,
    :verdict_parser,
    :threshold,
    :rounds,
    :reply_kind,
    failure_reply: :legacy,
    partial: [],
    phase: :idle,
    errors: [],
    queue: nil,
    usage: Usage.new()
  ]

  @impl true
  def init(opts) do
    specs = Keyword.fetch!(opts, :agents)
    validate_specs!(specs)

    if length(specs) < 2 do
      raise ArgumentError,
            "Consensus requires at least 2 agents, got #{length(specs)}"
    end

    names = for {name, _, _} <- specs, do: name

    case names -- Enum.uniq(names) do
      [] -> :ok
      dupes -> raise ArgumentError, "Consensus duplicate agent names: #{inspect(dupes)}"
    end

    parser = Keyword.fetch!(opts, :verdict_parser)

    unless is_function(parser, 1) do
      raise ArgumentError, "Consensus :verdict_parser must be a 1-arity function"
    end

    threshold = Keyword.get(opts, :threshold, :majority)
    validate_threshold!(threshold, length(names))

    rounds = Keyword.get(opts, :rounds, 3)
    validate_rounds!(rounds)

    reply_kind = Keyword.get(opts, :reply, :synthesis)
    validate_reply!(reply_kind)

    state = %__MODULE__{
      agents: names,
      verdict_parser: parser,
      threshold: threshold,
      rounds: rounds,
      reply_kind: reply_kind,
      queue: Queue.new(),
      failure_reply: Failure.option!(opts)
    }

    {:ok, state, specs}
  end

  # Reports only the index: spec options may carry credentials.
  defp validate_specs!(specs) do
    unless is_list(specs) do
      raise ArgumentError, "Consensus :agents must be a list of {name, module, opts} specs"
    end

    Enum.each(Enum.with_index(specs), &validate_spec!/1)

    :ok
  end

  defp validate_spec!({{_name, module, spec_opts}, index})
       when is_atom(module) and is_list(spec_opts) do
    if Keyword.keyword?(spec_opts), do: :ok, else: bad_spec!(index)
  end

  defp validate_spec!({_spec, index}), do: bad_spec!(index)

  defp bad_spec!(index) do
    raise ArgumentError,
          "Consensus :agents entry #{index} must be {name, module, keyword_opts}"
  end

  defp validate_rounds!(rounds) do
    unless is_integer(rounds) and rounds > 0 do
      raise ArgumentError,
            "Consensus :rounds must be a positive integer, got: #{inspect(rounds)}"
    end
  end

  defp validate_reply!(reply_kind) do
    unless reply_kind == :synthesis or
             match?({:synthesize, f} when is_function(f, 1), reply_kind) do
      raise ArgumentError,
            "Consensus :reply must be :synthesis or {:synthesize, fun/1}, got: " <>
              inspect(reply_kind)
    end
  end

  defp validate_threshold!(:unanimous, _n), do: :ok
  defp validate_threshold!(:majority, _n), do: :ok

  defp validate_threshold!({:at_least, n}, total) when is_integer(n) and n > 0 and n <= total,
    do: :ok

  defp validate_threshold!(other, total) do
    raise ArgumentError,
          "Consensus invalid :threshold #{inspect(other)} for #{total} agents " <>
            "(expected :unanimous | :majority | {:at_least, n} where 1 <= n <= #{total})"
  end

  @impl true
  def handle_tell(prompt, _opts, token, state), do: start_or_queue(prompt, token, state)

  @impl true
  def handle_ask(prompt, _opts, token, state), do: start_or_queue(prompt, token, state)

  defp start_or_queue(prompt, token, %{phase: :idle} = state) do
    ops = for agent <- state.agents, do: {:dispatch, agent, prompt, token}

    {:ok, ops,
     %{
       state
       | partial: [],
         usage: Usage.new(),
         errors: [],
         phase: {:running, token, prompt, 1, %{}}
     }}
  end

  defp start_or_queue(prompt, token, state) do
    {:ok, [], %{state | queue: Queue.enqueue(state.queue, token, prompt)}}
  end

  @impl true
  def handle_response(agent, response, state) do
    case state.phase do
      {:running, token, original, round, pending} ->
        state = %{state | usage: Usage.add(state.usage, agent, response.usage)}
        state = Failure.record(state, agent, :turn, round, response.text)

        case parse_response(state.verdict_parser, response.text) do
          {:ok, parsed} -> record(agent, parsed, {token, original, round, pending}, state)
          {:error, reason} -> fail_round(token, reason, state, :verdict_parser, agent)
        end

      _ ->
        {:ok, [], state}
    end
  end

  defp record(agent, entry, {token, original, round, pending}, state) do
    pending = Map.put(pending, agent, entry)
    state = %{state | phase: {:running, token, original, round, pending}}

    cond do
      state.errors != [] and threshold_unreachable?(pending, state) ->
        {agent, _reason} = error = hd(state.errors)
        fail_round(token, error, state, :turn, agent)

      map_size(pending) == length(state.agents) ->
        complete_round(token, original, round, pending, %{state | errors: []})

      true ->
        {:ok, [], state}
    end
  end

  defp threshold_unreachable?(pending, state) do
    n_agents = length(state.agents)

    best =
      pending
      |> Enum.flat_map(fn {_agent, {v, _, _}} -> List.wrap(v) end)
      |> Enum.frequencies()
      |> Map.values()
      |> Enum.max(fn -> 0 end)

    best + (n_agents - map_size(pending)) < required_votes(state.threshold, n_agents)
  end

  defp required_votes(:unanimous, n_agents), do: n_agents
  defp required_votes(:majority, n_agents), do: div(n_agents, 2) + 1
  defp required_votes({:at_least, n}, _n_agents), do: n

  defp fail_round(token, error, state, phase, agent) do
    partial =
      Enum.sort_by(state.partial, fn entry ->
        {entry.index, Enum.find_index(state.agents, &(&1 == entry.agent))}
      end)

    error = Failure.wrap(state.failure_reply, __MODULE__, phase, agent, error, partial)
    state = %{state | phase: :idle, partial: [], errors: []}
    {ops, state} = maybe_start_next(state, [{:reply_error, token, error}])
    {:ok, ops, state}
  end

  # `:error` is the parser's explicit abstain; anything else that is not a
  # verdict atom (never nil, the internal abstain marker) with a binary
  # rationale is a malformed result that fails the token.
  defp parse_response(parser, text) do
    case Guard.call(:verdict_parser, parser, [text], &valid_parse?/1) do
      {:ok, :error} -> {:ok, {nil, text, text}}
      {:ok, {:ok, verdict, rationale}} -> {:ok, {verdict, rationale, text}}
      {:error, _} = error -> error
    end
  end

  defp valid_parse?(:error), do: true

  defp valid_parse?({:ok, verdict, rationale}),
    do: is_atom(verdict) and verdict != nil and is_binary(rationale)

  defp valid_parse?(_), do: false

  defp complete_round(token, original, round, pending, state) do
    case converged?(pending, state.threshold, length(state.agents)) do
      {:converged, verdict} ->
        finalize(token, :converged, verdict, round, pending, state)

      :not_converged when round >= state.rounds ->
        finalize(token, :diverged, nil, round, pending, state)

      :not_converged ->
        reprompt_ops = build_reprompt_ops(state.agents, original, pending, token)
        new_phase = {:running, token, original, round + 1, %{}}
        {:ok, reprompt_ops, %{state | phase: new_phase}}
    end
  end

  defp converged?(pending, threshold, n_agents) do
    verdicts =
      pending
      |> Enum.map(fn {_agent, {v, _, _}} -> v end)
      |> Enum.reject(&is_nil/1)

    counts = Enum.frequencies(verdicts)

    case threshold do
      :unanimous ->
        if length(verdicts) == n_agents and map_size(counts) == 1 do
          [{verdict, _}] = Enum.to_list(counts)
          {:converged, verdict}
        else
          :not_converged
        end

      :majority ->
        needed = div(n_agents, 2) + 1
        check_threshold(counts, needed)

      {:at_least, n} ->
        check_threshold(counts, n)
    end
  end

  defp check_threshold(counts, needed) do
    case Enum.sort_by(counts, fn {_v, c} -> -c end) do
      [{verdict, count}] when count >= needed ->
        {:converged, verdict}

      [{verdict, count}, {_, second} | _] when count >= needed and count > second ->
        {:converged, verdict}

      _ ->
        :not_converged
    end
  end

  defp build_reprompt_ops(agents, original, pending, token) do
    for agent <- agents do
      others =
        pending
        |> Enum.reject(fn {a, _} -> a == agent end)
        |> Enum.sort_by(fn {a, _} -> Enum.find_index(agents, &(&1 == a)) end)

      prompt = compose_reprompt(original, others)
      {:dispatch, agent, prompt, token}
    end
  end

  defp compose_reprompt(original, others) do
    others_block = Enum.map_join(others, "\n\n", &format_other_response/1)

    """
    The other panelists responded as follows to the original question:

    > #{String.replace(original, "\n", "\n> ")}

    #{others_block}

    Given these perspectives, revise or confirm your own position. Respond to specific points where you agree or disagree. End with your verdict in the same format as before.
    """
    |> String.trim()
  end

  defp format_verdict(atom), do: atom |> Atom.to_string() |> String.upcase()

  defp format_other_response({agent, {verdict, rationale, _raw}}) do
    label =
      case verdict do
        nil -> "#{agent} (abstained)"
        v -> "#{agent} (#{format_verdict(v)})"
      end

    "#{label}:\n#{rationale}"
  end

  defp finalize(token, status, verdict, rounds_used, pending, state) do
    responses = collect_responses(state.agents, pending)

    result =
      case state.reply_kind do
        :synthesis ->
          {:ok, render_synthesis(status, verdict, rounds_used, state.threshold, responses)}

        {:synthesize, fun} ->
          summary = %{
            status: status,
            verdict: verdict,
            rounds: rounds_used,
            threshold: state.threshold,
            responses: responses
          }

          Guard.call(:synthesizer_reply, fun, [summary], &is_binary/1)
      end

    case result do
      {:ok, text} ->
        response = %Response{text: text, usage: Usage.to_usage(state.usage)}
        state = %{state | phase: :idle, partial: [], errors: []}
        {ops, state} = maybe_start_next(state, [{:reply, token, response}])
        {:ok, ops, state}

      {:error, reason} ->
        fail_round(token, reason, state, :synthesizer_reply, nil)
    end
  end

  defp collect_responses(agents, pending) do
    for agent <- agents do
      case Map.fetch(pending, agent) do
        {:ok, {verdict, rationale, raw}} -> {agent, verdict, rationale, raw}
        :error -> {agent, nil, "", ""}
      end
    end
  end

  defp render_synthesis(:converged, verdict, rounds_used, threshold, responses) do
    agreeing = Enum.count(responses, fn {_, v, _, _} -> v == verdict end)

    header =
      "CONSENSUS: #{inspect(verdict)} (#{agreeing} of #{length(responses)} agreed via " <>
        "#{format_threshold(threshold)}, round #{rounds_used})"

    body = Enum.map_join(responses, "\n\n", &render_response_entry/1)

    header <> "\n\n" <> body
  end

  defp render_synthesis(:diverged, _verdict, rounds_used, threshold, responses) do
    header =
      "DIVERGED AFTER #{rounds_used} ROUND#{if rounds_used == 1, do: "", else: "S"} " <>
        "(#{format_threshold(threshold)} not reached)"

    body = Enum.map_join(responses, "\n\n", &render_response_entry/1)

    header <> "\n\n" <> body
  end

  defp render_response_entry({agent, verdict, rationale, _raw}) do
    label =
      case verdict do
        nil -> "#{agent} [abstain]"
        v -> "#{agent} [#{format_verdict(v)}]"
      end

    "#{label}:\n#{rationale}"
  end

  defp format_threshold(:unanimous), do: "unanimous"
  defp format_threshold(:majority), do: "majority"
  defp format_threshold({:at_least, n}), do: "at_least #{n}"

  defp maybe_start_next(%{phase: :idle} = state, ops_so_far) do
    case Queue.pop(state.queue) do
      {:ok, {token, prompt}, rest} ->
        dispatch_ops = for agent <- state.agents, do: {:dispatch, agent, prompt, token}

        state = %{
          state
          | partial: [],
            usage: Usage.new(),
            errors: [],
            phase: {:running, token, prompt, 1, %{}},
            queue: rest
        }

        {ops_so_far ++ dispatch_ops, state}

      :empty ->
        {ops_so_far, state}
    end
  end

  @impl true
  def handle_error(agent, reason, state) do
    case state.phase do
      {:running, token, original, round, pending} ->
        if Map.has_key?(pending, agent) do
          {:ok, [], state}
        else
          state = %{state | errors: state.errors ++ [{agent, reason}]}
          entry = {nil, "turn error: #{inspect(reason)}", ""}
          record(agent, entry, {token, original, round, pending}, state)
        end

      _ ->
        {:ok, [], state}
    end
  end

  @impl true
  def handle_cancel(token, state) do
    state = %{state | queue: Queue.delete(state.queue, token)}

    case state.phase do
      {:running, ^token, _, _, _} ->
        {ops, state} =
          maybe_start_next(
            %{state | phase: :idle, partial: [], errors: [], usage: Usage.new()},
            []
          )

        {:ok, ops, state}

      _ ->
        {:ok, [], state}
    end
  end

  @impl true
  def handle_dispatch_rejected(agent, token, reason, state) do
    case state.phase do
      {:running, ^token, _, _, _} when state.failure_reply == :structured ->
        fail_round(token, {agent, reason}, state, :dispatch, agent)

      {:running, ^token, _, _, _} ->
        handle_error(agent, reason, state)

      _ ->
        error =
          Failure.wrap(state.failure_reply, __MODULE__, :dispatch, agent, {agent, reason}, [])

        {:ok, [{:reply_error, token, error}], state}
    end
  end

  @impl true
  def handle_agent_down(_agent, reason, state) do
    {:ok, [{:halt, {:agent_down, reason}}], state}
  end

  @impl true
  def handle_notify(_event, state), do: {:ok, [], state}

  @impl true
  def handle_status(state) do
    phase =
      case state.phase do
        :idle ->
          :idle

        {:running, _token, _original, round, pending} ->
          %{
            round: round,
            responded: map_size(pending),
            expected: length(state.agents)
          }
      end

    %{
      agents: state.agents,
      threshold: state.threshold,
      rounds: state.rounds,
      phase: phase,
      queued: Queue.len(state.queue)
    }
  end
end
