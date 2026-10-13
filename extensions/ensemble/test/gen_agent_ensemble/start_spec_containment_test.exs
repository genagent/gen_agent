defmodule GenAgentEnsemble.StartSpecContainmentTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GenAgent.Response
  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend}

  @secret "sk-start-spec-SECRET"

  defmodule RefusingAgent do
    use GenAgent

    @impl true
    def init_agent(_opts), do: {:error, :refused}

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}
  end

  defmodule Script do
    @moduledoc false

    # The operations for each request come from the caller's `:ops` option, so a
    # test states exactly what the strategy "returned" for that request.
    def init(opts) do
      {:ok, %{token: nil, observer: opts[:observer]}, Keyword.get(opts, :specs, [])}
    end

    def run(opts, token, state) do
      {:ok, Keyword.fetch!(opts, :ops).(token), %{state | token: token}}
    end

    def respond(response, %{token: token} = state) do
      {:ok, [{:reply, token, response}], state}
    end
  end

  # No handle_start_rejected/3: a failed start does not end the batch.
  defmodule Scripted do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(opts), do: Script.init(opts)

    @impl true
    def handle_tell(_prompt, opts, token, state), do: Script.run(opts, token, state)

    @impl true
    def handle_ask(_prompt, opts, token, state), do: Script.run(opts, token, state)

    @impl true
    def handle_response(_agent, response, state), do: Script.respond(response, state)
  end

  # Reports each rejected start to the test and closes the request's token.
  defmodule Reporting do
    @behaviour GenAgentEnsemble.Strategy

    @impl true
    def init(opts), do: Script.init(opts)

    @impl true
    def handle_tell(_prompt, opts, token, state), do: Script.run(opts, token, state)

    @impl true
    def handle_ask(_prompt, opts, token, state), do: Script.run(opts, token, state)

    @impl true
    def handle_response(_agent, response, state), do: Script.respond(response, state)

    @impl true
    def handle_start_rejected(agent, reason, state) do
      send(state.observer, {:start_rejected, agent, reason})
      {:ok, [{:reply_error, state.token, {:start_rejected, reason}}], state}
    end
  end

  @backend [backend: ControlledBackend]

  # {field reported in the rejection, spec}
  @invalid_specs [
    {:shape, :not_a_tuple},
    {:shape, {"w", ControlledAgent}},
    {:shape, {"w", ControlledAgent, @backend, :extra}},
    {:name, {:atom_name, ControlledAgent, @backend}},
    {:name, {%{private: @secret}, ControlledAgent, @backend}},
    {:module, {"w", "NotAModule", @backend}},
    {:module, {"w", nil, @backend}},
    {:options, {"w", ControlledAgent, %{backend: ControlledBackend, api_key: @secret}}},
    {:options, {"w", ControlledAgent, [{:backend, ControlledBackend} | {:api_key, @secret}]}},
    {:options, {"w", ControlledAgent, [:flag, backend: ControlledBackend]}},
    {:options, {"w", ControlledAgent, [{"api_key", @secret}]}},
    {:backend, {"w", ControlledAgent, [api_key: @secret]}},
    {:backend, {"w", ControlledAgent, []}},
    {:backend, {"w", ControlledAgent, [backend: nil, api_key: @secret]}},
    {:backend, {"w", ControlledAgent, [backend: "Backend", api_key: @secret]}},
    {:child_spec, {"w", ControlledAgent, @backend ++ [shutdown: -1, api_key: @secret]}},
    {:child_spec, {"w", ControlledAgent, @backend ++ [shutdown: :soon]}}
  ]

  setup do
    name = "start-spec-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case Registry.lookup(GenAgentEnsemble.Registry, name) do
        [{server, _}] ->
          try do
            GenServer.stop(server, :normal, 10_000)
          catch
            # The linked test owner may already have begun session shutdown.
            :exit, {{reason, {:sys, :terminate, _}}, {GenServer, :stop, _}}
            when reason in [:noproc, :normal, :shutdown] ->
              :ok

            :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
              :ok
          end

        [] ->
          :ok
      end
    end)

    {:ok, name: name}
  end

  defp live_spec do
    {"live", ControlledAgent, [backend: ControlledBackend, observer: self(), tag: "live"]}
  end

  defp start(name, strategy, extra \\ []) do
    Ensemble.start_link(
      name: name,
      strategy: strategy,
      opts: Keyword.merge([observer: self(), specs: [live_spec()]], extra)
    )
  end

  defp dynamic_spec(name, tag) do
    {name, ControlledAgent, [backend: ControlledBackend, observer: self(), tag: tag]}
  end

  defp ask_async(name, ops) do
    Task.async(fn -> Ensemble.ask(name, "go", ops: ops) end)
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition was not reached")

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defp assert_serves_live_agent(name) do
    task = ask_async(name, fn token -> [{:dispatch, "live", "still serving", token}] end)
    assert_receive {:controlled_prompt, "live", "still serving", worker}, 2_000
    send(worker, {:result, "LIVE"})
    assert {:ok, %{text: "LIVE"}} = Task.await(task)
  end

  test "malformed individual operations are skipped and a later reply completes the ask", %{
    name: name
  } do
    {:ok, server} = start(name, Scripted)

    ops = fn token ->
      [
        :bogus,
        {},
        {:unknown_op, @secret},
        {:stop, :live},
        {:stop, {:private, @secret}},
        {:forward, %{private: @secret}, :event},
        {:dispatch, %{private: @secret}, "never sent"},
        {:dispatch, :live, "never sent", token},
        {:dispatch, "live", {:private, @secret}, token},
        {:dispatch, "live", "never sent", %{private: @secret}},
        {:reply, token, %Response{text: "survived"}}
      ]
    end

    log =
      capture_log(fn ->
        assert {:ok, %{text: "survived"}} = Ensemble.ask(name, "go", ops: ops)
        Logger.flush()
      end)

    assert log =~ "invalid_operation"
    refute log =~ @secret
    refute log =~ "never sent"

    assert Process.alive?(server)
    refute_received {:controlled_prompt, _, _, _}
    assert {:ok, %{agents: ["live"], pending_tokens: [], in_flight: 0}} = Ensemble.status(name)
    assert_serves_live_agent(name)
  end

  test "a malformed scoped dispatch token is logged without leaking its value", %{name: name} do
    {:ok, server} = start(name, Scripted)

    log =
      capture_log(fn ->
        assert {:ok, %{text: "continued"}} =
                 Ensemble.ask(name, "go",
                   ops: fn token ->
                     [
                       {:dispatch, "live", "never sent", %{private: @secret}},
                       {:reply, token, %Response{text: "continued"}}
                     ]
                   end
                 )

        Logger.flush()
      end)

    assert log =~ "invalid_operation"
    refute log =~ @secret
    refute_received {:controlled_prompt, _, _, _}
    assert Process.alive?(server)
    assert_serves_live_agent(name)
  end

  test "malformed operations do not stop a tell, which a later reply completes", %{name: name} do
    {:ok, _} = start(name, Scripted)

    ops = fn token -> [{:halt}, 42, {:reply_error, token, :finished}] end

    capture_log(fn ->
      assert {:ok, token} = Ensemble.tell(name, "go", ops: ops)
      assert {:error, :finished} = Ensemble.poll(name, token)
    end)

    assert_serves_live_agent(name)
  end

  test "invalid start specs are logged and skipped without leaking their values", %{name: name} do
    {:ok, server} = start(name, Scripted)

    for {field, spec} <- @invalid_specs do
      ops = fn token -> [{:start, spec}, {:reply, token, %Response{text: "after"}}] end

      log =
        capture_log(fn ->
          assert {:ok, %{text: "after"}} = Ensemble.ask(name, "go", ops: ops),
                 "spec rejected as #{field} did not let the batch continue: #{inspect(spec)}"

          Logger.flush()
        end)

      assert log =~ "invalid_start_spec (#{field})",
             "missing #{field} in log for #{inspect(spec)}"

      refute log =~ @secret
      assert Process.alive?(server)
    end

    assert {:ok, %{agents: ["live"]}} = Ensemble.status(name)
    assert_serves_live_agent(name)
  end

  test "a valid dynamic start after an invalid one still starts and serves the dispatch", %{
    name: name
  } do
    {:ok, _} = start(name, Scripted)
    invalid = {"broken", ControlledAgent, [api_key: @secret]}
    # Built here: the ops function runs in the ensemble server, not this test.
    dynamic = dynamic_spec("dyn", "dyn")

    ops = fn token ->
      [{:start, invalid}, {:start, dynamic}, {:dispatch, "dyn", "hello", token}]
    end

    log =
      capture_log(fn ->
        task = ask_async(name, ops)
        assert_receive {:controlled_prompt, "dyn", "hello", worker}, 2_000
        assert {:ok, %{agents: agents}} = Ensemble.status(name)
        assert Enum.sort(agents) == ["dyn", "live"]
        send(worker, {:result, "DYN"})
        assert {:ok, %{text: "DYN"}} = Task.await(task)
        Logger.flush()
      end)

    assert log =~ "invalid_start_spec (backend)"
    refute log =~ @secret
    assert_serves_live_agent(name)
  end

  test "a rejected start with the callback reports the typed reason and ends the batch", %{
    name: name
  } do
    {:ok, server} = start(name, Reporting)
    invalid = {"broken", ControlledAgent, [api_key: @secret]}

    ops = fn token ->
      [{:start, invalid}, {:dispatch, "live", "must not run", token}]
    end

    log =
      capture_log(fn ->
        assert {:error, {:start_rejected, {:invalid_start_spec, :backend}}} =
                 Ensemble.ask(name, "go", ops: ops)

        Logger.flush()
      end)

    assert_received {:start_rejected, "broken", {:invalid_start_spec, :backend}}
    refute log =~ @secret
    refute_receive {:controlled_prompt, _, "must not run", _}, 100

    assert Process.alive?(server)
    assert {:ok, %{agents: ["live"], pending_tokens: [], in_flight: 0}} = Ensemble.status(name)
    assert_serves_live_agent(name)
  end

  test "a child_spec rejection reaches the callback and closes a tell token", %{name: name} do
    {:ok, _} = start(name, Reporting)
    invalid = {"slow", ControlledAgent, @backend ++ [shutdown: -1, api_key: @secret]}

    capture_log(fn ->
      assert {:ok, token} = Ensemble.tell(name, "go", ops: fn _ -> [{:start, invalid}] end)
      assert {:error, {:start_rejected, reason}} = Ensemble.poll(name, token)
      assert reason == {:invalid_start_spec, :child_spec}
      refute inspect(reason) =~ @secret
    end)

    assert_received {:start_rejected, "slow", {:invalid_start_spec, :child_spec}}
    assert {:ok, %{pending_tokens: []}} = Ensemble.status(name)
    assert_serves_live_agent(name)
  end

  test "an unidentifiable start is skipped even when the callback exists", %{name: name} do
    {:ok, _} = start(name, Reporting)

    ops = fn token ->
      [
        {:start, {}},
        {:start, {:atom_name, ControlledAgent, @backend}},
        {:start, :not_a_spec},
        {:reply, token, %Response{text: "continued"}}
      ]
    end

    capture_log(fn ->
      assert {:ok, %{text: "continued"}} = Ensemble.ask(name, "go", ops: ops)
    end)

    refute_received {:start_rejected, _, _}
    assert {:ok, %{agents: ["live"]}} = Ensemble.status(name)
  end

  test "named malformed start tuples invoke rejection and stop subsequent dispatch", %{name: name} do
    {:ok, server} = start(name, Reporting)

    for spec <- [
          {"broken"},
          {"broken", ControlledAgent},
          {"broken", ControlledAgent, @backend, :extra}
        ] do
      capture_log(fn ->
        assert {:error, {:start_rejected, {:invalid_start_spec, :shape}}} =
                 Ensemble.ask(name, "go",
                   timeout: 1_000,
                   ops: fn token ->
                     [{:start, spec}, {:dispatch, "live", "must not run", token}]
                   end
                 )
      end)

      assert_received {:start_rejected, "broken", {:invalid_start_spec, :shape}}
      assert {:ok, %{pending_tokens: [], in_flight: 0}} = Ensemble.status(name)
    end

    refute_received {:controlled_prompt, _, "must not run", _}
    assert Process.alive?(server)
    assert_serves_live_agent(name)
  end

  test "a child that refuses to start still reaches the callback with its own error", %{
    name: name
  } do
    {:ok, _} = start(name, Reporting)
    refusing = {"refuser", RefusingAgent, @backend}

    {result, _log} =
      with_log(fn -> Ensemble.ask(name, "go", ops: fn _ -> [{:start, refusing}] end) end)

    assert {:error, {:start_rejected, reason}} = result
    assert_received {:start_rejected, "refuser", ^reason}
    refute match?({:invalid_start_spec, _}, reason)
    refute match?({:start_exception, _}, reason)
    assert {:ok, %{agents: ["live"]}} = Ensemble.status(name)
  end

  test "a duplicate sub-agent keeps its existing rejection reason", %{name: name} do
    {:ok, _} = start(name, Reporting)
    duplicate = live_spec()

    capture_log(fn ->
      assert {:error, {:start_rejected, {:duplicate_sub_agent, "live"}}} =
               Ensemble.ask(name, "go", ops: fn _ -> [{:start, duplicate}] end)
    end)

    assert_received {:start_rejected, "live", {:duplicate_sub_agent, "live"}}
    assert_serves_live_agent(name)
  end

  describe "initialization" do
    test "an invalid spec fails start_link and stops the children already started", %{
      name: name
    } do
      Process.flag(:trap_exit, true)
      specs = [live_spec(), {"broken", ControlledAgent, [api_key: @secret]}]

      log =
        capture_log(fn ->
          assert {:error, {:invalid_start_spec, :backend}} = start(name, Scripted, specs: specs)
          Logger.flush()
        end)

      refute log =~ @secret

      eventually(fn -> GenAgent.whereis("#{name}/live") == nil end)
      eventually(fn -> Registry.lookup(GenAgentEnsemble.Registry, name) == [] end)
      eventually(fn -> Registry.lookup(GenAgentEnsemble.AgentTreeRegistry, name) == [] end)
      refute_received {:EXIT, _, _}

      # The same session name is free again and starts a clean tree.
      assert {:ok, _} = start(name, Scripted)
      assert {:ok, %{agents: ["live"]}} = Ensemble.status(name)
      assert_serves_live_agent(name)
    end

    test "a malformed spec shape fails start_link with a typed reason", %{name: name} do
      Process.flag(:trap_exit, true)

      # Distinct names: a failed session releases its registration asynchronously.
      assert {:error, {:invalid_start_spec, :shape}} =
               start("#{name}-shape", Scripted,
                 specs: [live_spec(), {"two-tuple", ControlledAgent}]
               )

      assert {:error, {:invalid_start_spec, :name}} =
               start("#{name}-name", Scripted, specs: [{:atom_name, ControlledAgent, @backend}])
    end
  end
end
