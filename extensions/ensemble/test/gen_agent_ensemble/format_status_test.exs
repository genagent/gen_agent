defmodule GenAgentEnsemble.FormatStatusTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GenAgentEnsemble, as: Ensemble
  alias GenAgentEnsemble.{ControlledAgent, ControlledBackend, Server}

  @secret "sk-test-SECRET-123"
  @prompt "PROMPT-SENTINEL"

  defmodule Strategy do
    def init(opts) do
      {agent, _module, start_opts} = spec = Keyword.fetch!(opts, :agent)
      {:ok, %{agent: agent, start_opts: start_opts, last_prompt: nil}, [spec]}
    end

    def handle_tell(prompt, opts, token, state) do
      op =
        if Keyword.get(opts, :duplicate_start) do
          {:start, {state.agent, GenAgentEnsemble.ControlledAgent, state.start_opts}}
        else
          {:dispatch, state.agent, prompt, token}
        end

      {:ok, [op], %{state | last_prompt: prompt}}
    end

    def handle_response(_agent, _response, state), do: {:ok, [], state}

    def handle_status(state), do: %{start_opts: state.start_opts, last_prompt: state.last_prompt}
  end

  setup do
    name = "format-ensemble-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        if Registry.lookup(GenAgentEnsemble.Registry, name) != [], do: Ensemble.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    %{name: name}
  end

  defp start_session(name) do
    start_opts = [
      backend: ControlledBackend,
      observer: self(),
      tag: "worker",
      max_pending_prompts: 0,
      api_key: @secret
    ]

    Ensemble.start_link(
      name: name,
      strategy: Strategy,
      opts: [agent: {"worker", ControlledAgent, start_opts}]
    )
  end

  defp await_idle(name, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    case Ensemble.status(name) do
      {:ok, %{in_flight: 0}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          await_idle(name, deadline)
        else
          flunk("turn did not finish")
        end
    end
  end

  test ":sys.get_status redacts strategy state and pending prompts", %{name: name} do
    {:ok, pid} = start_session(name)
    assert {:ok, _token} = Ensemble.tell(name, @prompt)
    assert_receive {:controlled_prompt, "worker", @prompt, worker}

    assert pid == GenServer.whereis({:via, Registry, {GenAgentEnsemble.Registry, name}})
    status = :sys.get_status(pid) |> inspect(limit: :infinity)
    assert status =~ name
    refute status =~ @secret
    refute status =~ @prompt

    assert {:ok, public} = Ensemble.status(name)
    assert public.start_opts[:api_key] == @secret
    assert public.last_prompt == @prompt
    assert public.in_flight == 1

    send(worker, {:result, "done"})
  end

  test "runtime callback crash does not render request or strategy state", %{name: name} do
    {:ok, pid} = start_session(name)
    Process.unlink(pid)
    monitor = Process.monitor(pid)

    log =
      capture_log(fn ->
        catch_exit(GenServer.call(pid, {:unexpected, @prompt, [api_key: @secret]}))
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
        Logger.flush()
      end)

    assert log =~ "callback failed"
    refute log =~ @secret
    refute log =~ @prompt
  end

  test "initialization failure does not render start arguments" do
    log =
      capture_log(fn ->
        assert {:error, {:init_failed, :error, KeyError}} =
                 GenServer.start(Server, name: @prompt, api_key: @secret)

        Logger.flush()
      end)

    assert log =~ "initialization failed"
    refute log =~ @secret
    refute log =~ @prompt
  end

  test "failed dispatch log includes agent and token without prompt or start opts", %{name: name} do
    {:ok, _} = start_session(name)
    assert {:ok, _} = Ensemble.tell(name, "first")
    assert_receive {:controlled_prompt, "worker", "first", worker}

    log =
      capture_log(fn ->
        assert {:ok, token} = Ensemble.tell(name, @prompt)
        send(self(), {:rejected_token, token})
      end)

    assert_receive {:rejected_token, token}
    assert log =~ "failed"
    assert log =~ "worker"
    assert log =~ token
    refute log =~ @prompt
    refute log =~ @secret

    send(worker, {:result, "done"})
  end

  test "failed start log omits duplicate agent options", %{name: name} do
    {:ok, _} = start_session(name)

    log =
      capture_log(fn ->
        assert {:ok, _} = Ensemble.tell(name, @prompt, duplicate_start: true)
      end)

    assert log =~ "failed"
    assert log =~ "start"
    assert log =~ "worker"
    refute log =~ @prompt
    refute log =~ @secret
  end

  test "unhandled turn error log includes only the reason kind", %{name: name} do
    {:ok, _} = start_session(name)
    assert {:ok, _} = Ensemble.tell(name, @prompt)
    assert_receive {:controlled_prompt, "worker", @prompt, worker}

    log =
      capture_log(fn ->
        send(worker, {:error, {:backend_failed, "ERROR-BODY-SENTINEL"}})
        await_idle(name)
      end)

    assert log =~ "turn errored (unhandled)"
    assert log =~ "backend_or_strategy_error"
    assert log =~ "worker"
    refute log =~ @prompt
    refute log =~ "ERROR-BODY-SENTINEL"
  end

  test "format_status keeps keys and handles malformed values" do
    raw = %{
      state: %Server{
        session_name: "safe-session",
        strategy_state: %{api_key: @secret, prompt: @prompt},
        completed: %{one: @prompt},
        pending: %{one: @prompt},
        in_flight: %{one: @prompt},
        dispatch_contexts: %{one: @prompt},
        monitors: %{one: @prompt},
        stream_recipients: %{one: self()},
        token_contexts: %{one: @prompt}
      },
      message: {:tell, @prompt, [api_key: @secret]},
      log: [{:in, {:tell, @prompt, []}, @prompt}],
      reason: {:callback_failed, @prompt}
    }

    formatted = Server.format_status(raw)
    assert Map.keys(formatted) == Map.keys(raw)
    assert formatted.state.session_name == "safe-session"
    assert formatted.state.stream_recipients == :redacted
    assert formatted.message == {:tell, :redacted, [api_key: :redacted]}
    assert formatted.reason == :redacted
    refute inspect(formatted, limit: :infinity) =~ @secret
    refute inspect(formatted, limit: :infinity) =~ @prompt

    for status <- [%{message: @prompt}, %{state: %{api_key: @secret}}] do
      formatted = Server.format_status(status)
      assert Map.keys(formatted) == Map.keys(status)
      refute inspect(formatted) =~ @secret
      refute inspect(formatted) =~ @prompt
    end

    assert Server.format_status(:malformed) == %{}
    assert Server.format_status(%{reason: {:shutdown, :normal}}).reason == {:shutdown, :normal}
  end
end
