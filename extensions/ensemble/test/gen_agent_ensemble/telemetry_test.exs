defmodule GenAgentEnsemble.TelemetryTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}
  alias GenAgentEnsemble.Strategies.{Pipeline, Solo, Supervisor, Switchboard}
  alias GenAgentEnsemble.TestAgent

  defmodule HaltStrategy do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(_opts), do: {:ok, nil, []}

    @impl true
    def handle_ask(_prompt, _opts, _token, state), do: {:ok, [{:halt, :planned}], state}

    @impl true
    def handle_tell(_prompt, _opts, _token, state), do: {:ok, [{:halt, :planned}], state}

    @impl true
    def handle_response(_agent, _response, state), do: {:ok, [], state}
  end

  @events for scope <- [:session, :token, :dispatch],
              event <- [:start, :stop, :halt, :error, :rejected],
              do: [:gen_agent_ensemble, scope, event]

  setup do
    name = "telemetry-#{System.unique_integer([:positive])}"
    handler = "#{name}-handler"
    :ok = :telemetry.attach_many(handler, @events, &__MODULE__.forward/4, self())

    on_exit(fn ->
      :telemetry.detach(handler)

      try do
        GenAgentEnsemble.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    %{name: name, handler: handler}
  end

  def forward(event, measurements, metadata, target) do
    send(target, {:telemetry, event, measurements, metadata})
  end

  defp spec(name, script) do
    {name, TestAgent, [backend: Mock, scripts: [script]]}
  end

  defp echo(text), do: [Event.new(:result, %{text: text})]

  test "Solo emits session, token, and correlated dispatch lifecycle", %{name: name} do
    {:ok, _} =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Solo,
        opts: [agent: spec("solo", echo("done"))]
      )

    assert_event([:session, :start], %{session: name, strategy: Solo})

    assert {:ok, %{text: "done"}} = GenAgentEnsemble.ask(name, "private prompt")
    {_, %{token: token, kind: :ask}} = assert_event([:token, :start], %{session: name})

    {_, %{ref: ref, ordinal: 0}} =
      assert_event([:dispatch, :start], %{session: name, token: token, agent: "solo"})

    {dispatch_measurements, _} =
      assert_event([:dispatch, :stop], %{session: name, token: token, ref: ref})

    {token_measurements, _} = assert_event([:token, :stop], %{session: name, token: token})
    assert is_integer(dispatch_measurements.duration_ms)
    assert is_integer(token_measurements.duration_ms)
    assert dispatch_measurements.duration_ms >= 0
    assert token_measurements.duration_ms >= 0
    refute_received {:telemetry, _, _, %{prompt: _}}
    refute_received {:telemetry, _, _, %{response: _}}

    :ok = GenAgentEnsemble.stop(name)
    assert_event([:session, :stop], %{session: name, reason_kind: :normal})
  end

  test "Switchboard attributes the selected agent and reports errors", %{name: name} do
    {:ok, _} =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Switchboard,
        opts: [agents: [spec("alice", {:error, :backend_failed}), spec("bob", echo("unused"))]]
      )

    assert {:error, :backend_failed} = GenAgentEnsemble.ask(name, "private", agent: "alice")
    {_, %{token: token}} = assert_event([:token, :start], %{session: name})
    assert_event([:dispatch, :start], %{session: name, token: token, agent: "alice"})

    assert_event([:dispatch, :error], %{
      session: name,
      token: token,
      reason_kind: :backend_or_strategy_error
    })

    assert_event([:token, :error], %{
      session: name,
      token: token,
      reason_kind: :backend_or_strategy_error
    })
  end

  test "Pipeline gives each stage an ordinal under one token", %{name: name} do
    {:ok, _} =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Pipeline,
        opts: [stages: [spec("draft", echo("drafted")), spec("review", echo("reviewed"))]]
      )

    assert {:ok, %{text: "reviewed"}} = GenAgentEnsemble.ask(name, "private")
    {_, %{token: token}} = assert_event([:token, :start], %{session: name})
    assert_event([:dispatch, :start], %{session: name, token: token, agent: "draft", ordinal: 0})
    assert_event([:dispatch, :start], %{session: name, token: token, agent: "review", ordinal: 1})
    assert_event([:token, :stop], %{session: name, token: token})
  end

  test "Supervisor distinguishes coordinator and fan-out branches", %{name: name} do
    coordinator = spec("coordinator", echo("one\ntwo"))
    worker = spec("worker", echo("answered"))

    {:ok, _} =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Supervisor,
        opts: [
          coordinator: coordinator,
          worker_template: worker,
          decomposer: &String.split(&1, "\n", trim: true)
        ]
      )

    assert {:ok, %{text: "answered\n\nanswered"}} = GenAgentEnsemble.ask(name, "private")
    {_, %{token: token}} = assert_event([:token, :start], %{session: name})

    assert_event([:dispatch, :start], %{
      session: name,
      token: token,
      agent: "coordinator",
      ordinal: 0
    })

    assert_event([:dispatch, :start], %{
      session: name,
      token: token,
      agent: "worker-1",
      ordinal: 1
    })

    assert_event([:dispatch, :start], %{
      session: name,
      token: token,
      agent: "worker-2",
      ordinal: 2
    })

    assert_event([:token, :stop], %{session: name, token: token})
  end

  test "halt closes pending token and emits session events", %{name: name} do
    {:ok, _} = GenAgentEnsemble.start_link(name: name, strategy: HaltStrategy, opts: [])
    assert {:error, {:halted, :planned}} = GenAgentEnsemble.ask(name, "private")
    assert_event([:session, :halt], %{session: name, reason_kind: :strategy_halt})
    assert_event([:token, :error], %{session: name, reason_kind: :halted})
    assert_event([:session, :stop], %{session: name, reason_kind: :normal})
  end

  test "stopping a busy session marks unfinished work", %{name: name} do
    agent = {"busy", ControlledAgent, [backend: ControlledBackend, observer: self(), tag: "busy"]}
    {:ok, _} = GenAgentEnsemble.start_link(name: name, strategy: Solo, opts: [agent: agent])
    {:ok, token} = GenAgentEnsemble.tell(name, "private")
    assert_receive {:controlled_prompt, "busy", "private", _task}, 1_000

    :ok = GenAgentEnsemble.stop(name)

    assert_event([:dispatch, :error], %{
      session: name,
      token: token,
      reason_kind: :session_stopped
    })

    assert_event([:token, :error], %{session: name, token: token, reason_kind: :session_stopped})
    assert_event([:session, :stop], %{session: name, outcome: :ok})
  end

  test "a crashing observer cannot prevent result delivery", %{name: name, handler: handler} do
    :ok = :telemetry.detach(handler)

    :ok =
      :telemetry.attach_many(handler, @events, fn _, _, _, _ -> raise "observer failed" end, nil)

    {:ok, _} =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Solo,
        opts: [agent: spec("solo", echo("done"))]
      )

    assert {:ok, %{text: "done"}} = GenAgentEnsemble.ask(name, "private")
  end

  defp assert_event(suffix, expected_metadata) do
    event = [:gen_agent_ensemble | suffix]
    assert_receive {:telemetry, ^event, measurements, metadata}, 1_000
    assert Map.take(metadata, Map.keys(expected_metadata)) == expected_metadata
    {measurements, metadata}
  end
end
