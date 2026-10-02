defmodule GenAgent.SessionCheckpointTest do
  use ExUnit.Case, async: false

  alias GenAgent.Event

  defmodule Backend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts) do
      {:ok,
       %{
         observer: Keyword.fetch!(opts, :observer),
         script: Keyword.fetch!(opts, :script),
         id: nil
       }}
    end

    @impl true
    def prompt(session, prompt), do: prompt(session, prompt, %{checkpoint: fn _ -> :ok end})

    @impl true
    def prompt(session, prompt, context) do
      send(session.observer, {:prompt_session, prompt, session.id})
      {:ok, session.script.(prompt, context), session}
    end

    @impl true
    def checkpoint_session(session, id), do: %{session | id: id}

    @impl true
    def terminate_session(_session), do: :ok
  end

  defmodule Agent do
    use GenAgent

    @impl true
    def init_agent(opts) do
      {:ok, Keyword.take(opts, [:observer, :script]),
       %{observer: Keyword.fetch!(opts, :observer)}}
    end

    @impl true
    def handle_response(_ref, _response, state), do: {:noreply, state}

    @impl true
    def handle_error(_ref, _reason, state), do: {:noreply, state}
  end

  defp start_agent(script, opts \\ []) do
    name = "checkpoint-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      GenAgent.start_agent(
        Agent,
        Keyword.merge([name: name, backend: Backend, observer: self(), script: script], opts)
      )

    on_exit(fn ->
      if GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    name
  end

  defp session(name), do: :gen_statem.call(GenAgent.whereis(name), :get_backend_session)
  defp result, do: Event.new(:result, %{text: "ok"})

  test "terminal error keeps the early ID for the next prompt in both capture modes" do
    for mode <- [:compact, :lossless] do
      script = fn
        "fail", %{checkpoint: checkpoint} ->
          Stream.map([:one], fn _ ->
            assert :ok = checkpoint.("cli-session")
            Event.new(:error, %{reason: :provider_failed})
          end)

        "next", _ ->
          [result()]
      end

      name = start_agent(script, event_retention: mode)
      assert {:error, :provider_failed} = GenAgent.ask(name, "fail")
      assert session(name).id == "cli-session"
      assert {:ok, _} = GenAgent.ask(name, "next")
      assert_receive {:prompt_session, "next", "cli-session"}
    end
  end

  test "acknowledged checkpoint survives interrupt and watchdog" do
    observer = self()

    script = fn
      "hold", %{checkpoint: checkpoint} ->
        Stream.map([:one, :wait], fn
          :one ->
            assert :ok = checkpoint.("early-id")
            send(observer, :checkpointed)
            Event.new(:text, %{text: "started"})

          :wait ->
            Process.sleep(30_000)
            result()
        end)

      "next", _ ->
        [result()]
    end

    interrupted = start_agent(script)
    assert {:ok, ref} = GenAgent.tell(interrupted, "hold")
    assert_receive :checkpointed
    assert {:ok, :accepted} = GenAgent.interrupt_request(interrupted, ref)
    assert {:error, :interrupted} = GenAgent.poll(interrupted, ref)
    assert session(interrupted).id == "early-id"
    assert {:ok, _} = GenAgent.ask(interrupted, "next")
    assert_receive {:prompt_session, "next", "early-id"}

    timed_out = start_agent(script, watchdog_ms: 100)
    assert {:ok, ref} = GenAgent.tell(timed_out, "hold")
    assert_receive :checkpointed
    assert_receive {:prompt_session, "hold", nil}
    assert {:error, :timeout} = await_poll(timed_out, ref)
    assert session(timed_out).id == "early-id"
    assert {:ok, _} = GenAgent.ask(timed_out, "next")
    assert_receive {:prompt_session, "next", "early-id"}
  end

  test "task crash keeps checkpoint and interruption before an ID keeps nil" do
    observer = self()

    script = fn
      "crash", %{checkpoint: checkpoint} ->
        Stream.map([:one], fn _ ->
          assert :ok = checkpoint.("before-crash")
          raise "fixture crash"
        end)

      "hold", _ ->
        Stream.map([:one], fn _ ->
          send(observer, :holding)
          Process.sleep(30_000)
          result()
        end)
    end

    crashed = start_agent(script)
    assert {:error, {:task_crashed, _}} = GenAgent.ask(crashed, "crash")
    assert session(crashed).id == "before-crash"

    interrupted = start_agent(script)
    assert {:ok, ref} = GenAgent.tell(interrupted, "hold")
    assert_receive :holding
    assert {:ok, :accepted} = GenAgent.interrupt_request(interrupted, ref)
    assert session(interrupted).id == nil
  end

  test "lossless capture overflow does not discard the checkpoint" do
    script = fn
      "overflow", %{checkpoint: checkpoint} ->
        Stream.map(1..3, fn n ->
          if n == 1, do: assert(:ok = checkpoint.("overflow-session"))
          Event.new(:text, %{text: Integer.to_string(n)})
        end)

      "next", _ ->
        [result()]
    end

    name = start_agent(script, event_retention: :lossless, max_events_per_turn: 2)
    assert {:error, {:event_capture_overflow, _}} = GenAgent.ask(name, "overflow")
    assert session(name).id == "overflow-session"
    assert {:ok, _} = GenAgent.ask(name, "next")
    assert_receive {:prompt_session, "next", "overflow-session"}
  end

  test "wrong caller and old request cannot checkpoint a successor" do
    observer = self()

    script = fn
      "first", %{checkpoint: checkpoint} ->
        send(observer, {:old_checkpoint, checkpoint})
        [result()]

      "second", %{checkpoint: checkpoint} ->
        Stream.map([:one], fn _ ->
          send(observer, {:active_checkpoint, checkpoint})

          receive do
            {:test_old_checkpoint, old} ->
              send(observer, {:old_result, old.("stale")})
          end

          assert :ok = checkpoint.("fresh")
          result()
        end)
    end

    name = start_agent(script)
    assert {:ok, _} = GenAgent.ask(name, "first")
    assert_receive {:old_checkpoint, old}
    assert {:error, :not_current} = old.("stale")

    caller = Task.async(fn -> GenAgent.ask(name, "second") end)
    assert_receive {:active_checkpoint, active}
    assert {:error, :not_current} = active.("wrong-pid")

    pid =
      :sys.get_state(GenAgent.whereis(name))
      |> elem(1)
      |> Map.fetch!(:current_request)
      |> Map.fetch!(:task_pid)

    send(pid, {:test_old_checkpoint, old})
    assert_receive {:old_result, {:error, :not_current}}
    assert {:ok, _} = Task.await(caller)
    assert session(name).id == "fresh"
  end

  test "duplicate IDs are harmless and conflicting or malformed IDs fail the turn" do
    script = fn
      "duplicate", %{checkpoint: checkpoint} ->
        Stream.map([:one], fn _ ->
          assert :ok = checkpoint.("first")
          assert :ok = checkpoint.("first")
          result()
        end)

      "conflict", %{checkpoint: checkpoint} ->
        Stream.map([:one], fn _ ->
          assert :ok = checkpoint.("first")
          assert {:error, :conflicting_session_id} = checkpoint.("second")
          result()
        end)

      "invalid", %{checkpoint: checkpoint} ->
        Stream.map([:one], fn _ ->
          assert {:error, :invalid_session_id} = checkpoint.("bad\nline")
          result()
        end)
    end

    name = start_agent(script)
    assert {:ok, response} = GenAgent.ask(name, "duplicate")
    assert response.event_coverage.observed_events == 1
    assert Enum.map(response.events, & &1.kind) == [:result]
    assert {:error, :conflicting_session_id} = GenAgent.ask(name, "conflict")
    assert session(name).id == "first"
    assert {:error, :invalid_session_id} = GenAgent.ask(name, "invalid")
    assert session(name).id == "first"
  end

  defp await_poll(name, ref, attempts \\ 30)
  defp await_poll(name, ref, 0), do: GenAgent.poll(name, ref)

  defp await_poll(name, ref, attempts) do
    case GenAgent.poll(name, ref) do
      {:ok, :pending} ->
        Process.sleep(10)
        await_poll(name, ref, attempts - 1)

      other ->
        other
    end
  end
end
