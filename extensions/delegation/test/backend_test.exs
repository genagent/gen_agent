defmodule GenAgent.Delegation.BackendTest.Provider do
  @behaviour GenAgent.Backend

  def start_session(opts) do
    send(opts[:owner], {:fresh, opts})

    if opts[:fail],
      do: {:error, :cannot_start},
      else: {:ok, %{owner: opts[:owner], id: nil, turns: 0}}
  end

  def resume_session(id, opts) do
    send(opts[:owner], {:resume, id, opts})

    if opts[:fail],
      do: {:error, :cannot_resume},
      else: {:ok, %{owner: opts[:owner], id: id, turns: 0}}
  end

  def prompt(_session, "fail"), do: {:error, :prompt_failed}

  def prompt(session, prompt) do
    send(session.owner, {:prompt_two, session.id, prompt})
    {:ok, [GenAgent.Event.new(:result, %{text: prompt})], %{session | turns: session.turns + 1}}
  end

  def prompt(session, prompt, context) do
    stream =
      Stream.map([:go], fn _ ->
        send(session.owner, {:consumed, session.id, prompt})

        case context.checkpoint.("early-id") do
          :ok -> GenAgent.Event.new(:result, %{text: prompt, session_id: "early-id"})
          {:error, reason} -> GenAgent.Event.new(:error, %{reason: reason})
        end
      end)

    {:ok, stream, %{session | turns: session.turns + 1}}
  end

  def update_session(session, %{session_id: id}), do: %{session | id: id}
  def checkpoint_session(session, id), do: %{session | id: id}

  def terminate_session(session) do
    send(session.owner, {:terminated, session.id})
    :ok
  end
end

defmodule GenAgent.Delegation.BackendTest.Minimal do
  @behaviour GenAgent.Backend
  def start_session(opts), do: {:ok, opts}
  def prompt(session, prompt), do: {:ok, [GenAgent.Event.new(:result, %{text: prompt})], session}
  def terminate_session(_), do: :ok
end

defmodule GenAgent.Delegation.BackendTest do
  use ExUnit.Case, async: true
  alias GenAgent.Delegation.Backend
  alias __MODULE__.{Minimal, Provider}

  defp options(extra \\ []),
    do:
      Keyword.merge(
        [backend: Provider, backend_opts: [owner: self()], manager: self(), name: "worker"],
        extra
      )

  test "fresh sessions and resumed sessions use distinct underlying callbacks" do
    {:ok, fresh} = Backend.start_session(options())
    assert_receive {:fresh, [owner: _]}
    refute_received {:resume, _, _}
    assert fresh.session.id == nil

    {:ok, resumed} = Backend.start_session(options(provider_session_id: "saved-id"))
    assert_receive {:resume, "saved-id", [owner: _]}
    assert resumed.session.id == "saved-id"
    refute_received {:fresh, _}
    assert {:ok, _, _} = Backend.prompt(resumed, "follow up")
    assert_receive {:prompt_two, "saved-id", "follow up"}
  end

  test "prompt delegates the original checkpoint and stream stays lazy" do
    {:ok, proxy} = Backend.start_session(options())
    owner = self()

    checkpoint = fn id ->
      send(owner, {:core_ack, id})
      :ok
    end

    {:ok, stream, next} = Backend.prompt(proxy, "hello", %{checkpoint: checkpoint})
    assert next.session.turns == 1
    refute_received {:consumed, _, _}
    refute_received {:delegation_checkpoint, _, _}
    assert [%GenAgent.Event{kind: :result}] = Enum.to_list(stream)
    assert_receive {:consumed, nil, "hello"}
    assert_receive {:core_ack, "early-id"}
    refute_received {:delegation_checkpoint, _, _}
  end

  test "core checkpoint notification survives cancellation before the worker receives its reply" do
    {:ok, proxy} = Backend.start_session(options())
    parent = self()

    core =
      spawn(fn ->
        receive do
          {:checkpoint, worker, id} ->
            updated = Backend.checkpoint_session(proxy, id)
            Process.exit(worker, :kill)
            send(parent, {:core_updated, updated.session.id})
        end
      end)

    on_exit(fn -> if Process.alive?(core), do: Process.exit(core, :kill) end)

    {worker, monitor} =
      spawn_monitor(fn ->
        checkpoint = fn id ->
          send(core, {:checkpoint, self(), id})

          receive do
            :ack -> :ok
          end
        end

        {:ok, stream, _} = Backend.prompt(proxy, "hello", %{checkpoint: checkpoint})
        Enum.to_list(stream)
      end)

    assert_receive {:delegation_checkpoint, "worker", "early-id"}
    assert_receive {:core_updated, "early-id"}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
  end

  test "rejected checkpoint is never reported to the manager as accepted" do
    {:ok, proxy} = Backend.start_session(options())

    {:ok, stream, _} =
      Backend.prompt(proxy, "hello", %{checkpoint: fn _ -> {:error, :not_current} end})

    assert [%GenAgent.Event{kind: :error, data: %{reason: :not_current}}] = Enum.to_list(stream)
    refute_received {:delegation_checkpoint, _, _}
  end

  test "session updates and termination retain wrapper identity and underlying state" do
    {:ok, proxy} = Backend.start_session(options())
    checkpointed = Backend.checkpoint_session(proxy, "checkpoint-id")
    assert checkpointed.session.id == "checkpoint-id"
    assert_receive {:delegation_checkpoint, "worker", "checkpoint-id"}
    updated = Backend.update_session(checkpointed, %{session_id: "terminal-id"})
    assert updated.session.id == "terminal-id"
    assert updated.name == "worker"
    assert updated.manager == self()
    assert :ok = Backend.terminate_session(updated)
    assert_receive {:terminated, "terminal-id"}
    refute_received {:delegation_checkpoint, _, _}
  end

  test "optional underlying callbacks are not required and resume never silently starts fresh" do
    {:ok, proxy} = Backend.start_session(options(backend: Minimal))

    assert {:ok, [%GenAgent.Event{kind: :result}], _} =
             Backend.prompt(proxy, "plain", %{
               checkpoint: fn _ -> flunk("must not checkpoint") end
             })

    assert Backend.checkpoint_session(proxy, "ignored") == proxy
    assert Backend.update_session(proxy, %{}) == proxy

    assert {:error, :resume_unsupported} =
             Backend.start_session(options(backend: Minimal, provider_session_id: "saved"))
  end

  test "startup resume and prompt failures propagate without fallback" do
    assert {:error, :cannot_start} =
             Backend.start_session(options(backend_opts: [owner: self(), fail: true]))

    assert_receive {:fresh, _}

    assert {:error, :cannot_resume} =
             Backend.start_session(
               options(backend_opts: [owner: self(), fail: true], provider_session_id: "saved")
             )

    assert_receive {:resume, "saved", _}
    refute_received {:fresh, _}
    {:ok, proxy} = Backend.start_session(options())
    assert {:error, :prompt_failed} = Backend.prompt(proxy, "fail")
  end

  test "invalid proxy configuration fails before starting an underlying backend" do
    for extra <- [
          [provider_session_id: ""],
          [provider_session_id: "bad\nvalue"],
          [provider_session_id: 1],
          [backend: Backend],
          [backend: Enum],
          [backend_opts: :wrong],
          [manager: :wrong],
          [surprise: true]
        ] do
      assert {:error, _} = Backend.start_session(options(extra))
    end

    assert {:error, _} = Backend.start_session(:wrong)
    refute_received {:fresh, _}
    refute_received {:resume, _, _}
  end
end
