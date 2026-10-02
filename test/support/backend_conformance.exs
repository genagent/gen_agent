Code.require_file("down_assertions.exs", __DIR__)

defmodule GenAgent.Test.BackendConformance do
  @moduledoc """
  Shared backend contract, loaded by integration test helpers.

  Consumers define conformance_setup/1 returning the backend, agent_opts,
  first_prompt, second_prompt, error_prompt, assert_error/1 and
  assert_threaded/2 functions. CLI consumers also supply hold_prompt and
  enable lifecycle: true. Transport setup and assertions stay in the package.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      {observer, backend_opts} = Keyword.pop!(opts, :observer)
      {:ok, backend_opts, %{observer: observer, responses: [], errors: []}}
    end

    @impl true
    def handle_stream_event(event, state) do
      send(state.observer, {:stream_event, event.kind, self()})
      state
    end

    @impl true
    def handle_response(ref, response, state) do
      send(state.observer, {:completed, ref})
      {:noreply, %{state | responses: [response | state.responses]}}
    end

    @impl true
    def handle_error(ref, reason, state) do
      send(state.observer, {:failed, ref, reason})
      {:noreply, %{state | errors: [reason | state.errors]}}
    end
  end

  def start_agent(config, opts \\ []) do
    name = "conformance-#{System.unique_integer([:positive])}"

    agent_opts =
      Keyword.merge(config.agent_opts, opts) ++
        [name: name, backend: config.backend, observer: self()]

    assert {:ok, _pid} = GenAgent.start_agent(Agent, agent_opts)

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    name
  end

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, async: unquote(Keyword.get(opts, :async, false))

      @moduletag capture_log: true

      test "backend contract: successful turn has text and one terminal result", context do
        config = conformance_setup(context)
        name = GenAgent.Test.BackendConformance.start_agent(config)
        assert {:ok, response} = GenAgent.ask(name, config.first_prompt)
        assert is_binary(response.text) and response.text != ""
        assert %GenAgent.Event{kind: :result} = List.last(response.events)
        assert Enum.count(response.events, &GenAgent.Event.terminal?/1) == 1
        assert response.terminal == List.last(response.events)
        assert length(GenAgent.status(name).agent_state.responses) == 1
      end

      test "backend contract: session is threaded across two turns", context do
        config = conformance_setup(context)
        name = GenAgent.Test.BackendConformance.start_agent(config)
        assert {:ok, first} = GenAgent.ask(name, config.first_prompt)
        assert {:ok, second} = GenAgent.ask(name, config.second_prompt)
        assert is_binary(first.session_id) and first.session_id != ""
        assert second.session_id == first.session_id
        config.assert_threaded.(first, second)
      end

      test "backend contract: errors reach the caller and agent", context do
        config = conformance_setup(context)
        name = GenAgent.Test.BackendConformance.start_agent(config)
        assert {:error, reason} = GenAgent.ask(name, config.error_prompt)
        config.assert_error.(reason)
        assert GenAgent.status(name).agent_state.errors == [reason]
      end

      if unquote(Keyword.get(opts, :lifecycle, false)) do
        for action <- [:interrupt, :watchdog, :stop, :kill] do
          @tag action: action
          test "#{action} stops the BEAM task on the executable streaming path", context do
            config = conformance_setup(context)
            action = context.action
            watchdog_ms = if action == :watchdog, do: 500, else: 5_000
            name = GenAgent.Test.BackendConformance.start_agent(config, watchdog_ms: watchdog_ms)
            assert {:ok, ref} = GenAgent.tell(name, config.hold_prompt)
            assert_receive {:stream_event, :text, task_pid}, 1_000
            task_monitor = Process.monitor(task_pid)

            case action do
              :interrupt ->
                assert :ok = GenAgent.interrupt(name)
                assert_receive {:failed, ^ref, :interrupted}, 1_000
                assert {:error, :interrupted} = GenAgent.poll(name, ref)

              :watchdog ->
                assert_receive {:failed, ^ref, :timeout}, 1_000
                assert {:error, :timeout} = GenAgent.poll(name, ref)

              :stop ->
                assert :ok = GenAgent.stop(name)

              :kill ->
                Process.exit(GenAgent.whereis(name), :kill)
            end

            GenAgent.TestDownAssertions.assert_killed_or_gone(task_monitor, task_pid, 1_000)
          end
        end
      end
    end
  end
end
