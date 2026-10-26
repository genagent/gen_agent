defmodule GenAgentEnsemble.MemberSessionsTest do
  use ExUnit.Case, async: false

  alias GenAgentEnsemble.Strategies.{Debate, Pool, Solo, Supervisor, Switchboard}

  defmodule Agent do
    @moduledoc false
    use GenAgent

    @impl true
    def init_agent(opts), do: {:ok, Keyword.take(opts, [:observer, :tag]), %{}}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  # Reports how many earlier prompts each turn's backend session carries.
  defmodule HistoryBackend do
    @moduledoc false
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts) do
      {:ok,
       %{observer: Keyword.fetch!(opts, :observer), tag: Keyword.fetch!(opts, :tag), seen: 0}}
    end

    @impl true
    def prompt(session, _prompt) do
      send(session.observer, {:turn, session.tag, session.seen})
      event = GenAgent.Event.new(:result, %{text: "#{session.tag}: ok"})
      {:ok, [event], %{session | seen: session.seen + 1}}
    end

    @impl true
    def reset_session(session) do
      send(session.observer, {:reset, session.tag})
      {:ok, %{session | seen: 0}}
    end

    @impl true
    def terminate_session(_session), do: :ok
  end

  defmodule NoResetBackend do
    @moduledoc false
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts), do: HistoryBackend.start_session(opts)

    @impl true
    defdelegate prompt(session, prompt), to: HistoryBackend

    @impl true
    def terminate_session(_session), do: :ok
  end

  setup do
    %{name: "member-sessions-#{System.unique_integer([:positive])}"}
  end

  defp start_ensemble(name, strategy, strategy_opts, opts) do
    start_supervised!(%{
      id: name,
      start:
        {GenAgentEnsemble, :start_link,
         [Keyword.merge([name: name, strategy: strategy, opts: strategy_opts], opts)]},
      restart: :temporary
    })

    name
  end

  defp pool(name, backend, opts) do
    worker = {"w", Agent, [backend: backend, observer: self(), tag: "w"]}
    start_ensemble(name, Pool, [worker_count: 1, worker_template: worker], opts)
  end

  test "shared sessions keep one conversation per member across runs", %{name: name} do
    pool(name, HistoryBackend, [])

    assert {:ok, _} = GenAgentEnsemble.ask(name, "one")
    assert {:ok, _} = GenAgentEnsemble.ask(name, "two")
    assert_receive {:turn, "w", 0}
    assert_receive {:turn, "w", 1}
    refute_received {:reset, _}
  end

  test "per-run sessions reset a reused member before its next run", %{name: name} do
    pool(name, HistoryBackend, member_sessions: :per_run)

    assert {:ok, _} = GenAgentEnsemble.ask(name, "one")
    assert_receive {:turn, "w", 0}
    refute_received {:reset, _}

    assert {:ok, _} = GenAgentEnsemble.ask(name, "two")
    assert_receive {:reset, "w"}
    assert_receive {:turn, "w", 0}
  end

  test "per-run sessions keep context across rounds within one run", %{name: name} do
    agents =
      for tag <- ["alice", "bob"],
          do: {tag, Agent, [backend: HistoryBackend, observer: self(), tag: tag]}

    start_ensemble(name, Debate, [agents: agents, rounds: 4], member_sessions: :per_run)

    assert {:ok, _} = GenAgentEnsemble.ask(name, "first")
    assert_receive {:turn, "alice", 0}
    assert_receive {:turn, "bob", 0}
    assert_receive {:turn, "alice", 1}
    assert_receive {:turn, "bob", 1}
    refute_received {:reset, _}

    assert {:ok, _} = GenAgentEnsemble.ask(name, "second")
    assert_receive {:reset, "alice"}
    assert_receive {:turn, "alice", 0}
    assert_receive {:reset, "bob"}
    assert_receive {:turn, "bob", 0}
  end

  test "a backend without reset support rejects the next run's dispatch", %{name: name} do
    pool(name, NoResetBackend, member_sessions: :per_run)

    assert {:ok, _} = GenAgentEnsemble.ask(name, "one")
    assert_receive {:turn, "w", 0}

    assert {:error, reason} = GenAgentEnsemble.ask(name, "two")
    assert inspect(reason) =~ "session_reset_failed"
    assert inspect(reason) =~ "unsupported"
    refute_received {:turn, "w", _}
  end

  test "strategies whose members can be busy at run start reject per-run sessions", %{
    name: name
  } do
    for strategy <- [Solo, Switchboard, Supervisor] do
      assert {:error, {:unsupported_option, :member_sessions, :per_run}} =
               GenAgentEnsemble.start_link(
                 name: name,
                 strategy: strategy,
                 opts: [],
                 member_sessions: :per_run
               )

      assert Registry.lookup(GenAgentEnsemble.Registry, name) == []
    end
  end

  test "invalid values are rejected before startup", %{name: name} do
    for value <- [:fresh, true, nil, "per_run"] do
      assert {:error, {:invalid_option, :member_sessions, ^value}} =
               GenAgentEnsemble.start_link(
                 name: name,
                 strategy: Pool,
                 opts: [worker_count: 1, worker_template: {"w", Agent, []}],
                 member_sessions: value
               )
    end
  end
end
