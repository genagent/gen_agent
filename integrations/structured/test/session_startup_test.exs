defmodule GenAgent.Structured.StartupTest.Backend do
  @behaviour GenAgent.Backend

  def start_session(opts) do
    send(Keyword.fetch!(opts, :owner), {:backend_started, self(), opts})
    if opts[:fail_start], do: {:error, :start_failed}, else: {:ok, opts}
  end

  def prompt(_state, _prompt), do: {:error, :unexpected_prompt}
  def terminate_session(_state), do: :ok
end

defmodule GenAgent.Structured.StartupTest.Provider do
  @behaviour GenAgent.Structured.Provider
  def backend, do: GenAgent.Structured.StartupTest.Backend
  defdelegate prepare(schema, opts, directory), to: GenAgent.Structured.Providers.Codex
  defdelegate extract(response, schema), to: GenAgent.Structured.Providers.Codex
end

defmodule GenAgent.Structured.StartupTest.GatedProvider do
  @behaviour GenAgent.Structured.Provider
  def backend, do: GenAgent.Structured.StartupTest.Backend

  def prepare(schema, opts, directory) do
    send(Keyword.fetch!(opts, :owner), {:preparing, self(), directory})

    receive do
      :continue -> GenAgent.Structured.Providers.Codex.prepare(schema, opts, directory)
    end
  end

  defdelegate extract(response, schema), to: GenAgent.Structured.Providers.Codex
end

defmodule GenAgent.Structured.StartupTest do
  use ExUnit.Case, async: true
  alias GenAgent.Structured, as: S
  alias GenAgent.Structured.Error

  defp contract do
    {:ok, contract} = S.contract(instructions: "Answer", output_schema: %{"type" => "object"})
    contract
  end

  test "prepare failures return from open and run without killing an ordinary caller" do
    parent = self()
    contract = contract()

    {caller, monitor} =
      spawn_monitor(fn ->
        # No exit trapping: a startup link must not kill this caller.
        opts = [provider: :codex, backend_opts: [output_schema: "x"]]
        send(parent, {:open_failed, S.open(contract, opts)})
        send(parent, {:run_failed, S.run(contract, %{}, opts)})
      end)

    for operation <- [:open_failed, :run_failed] do
      assert_receive {^operation,
                      {:error,
                       %Error{stage: :provider, reason: {:schema_option_conflict, :output_schema}}}},
                     1000
    end

    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
  end

  test "failed child startup returns an error and removes the allocated schema" do
    parent = self()
    contract = contract()

    {caller, monitor} =
      spawn_monitor(fn ->
        result =
          S.open(contract,
            provider: GenAgent.Structured.StartupTest.Provider,
            backend_opts: [owner: parent, fail_start: true]
          )

        send(parent, {:failed_start, result})
      end)

    assert_receive {:failed_start, {:error, %Error{stage: :provider}}}, 1000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert_receive {:backend_started, agent, opts}
    refute Process.alive?(agent)
    refute File.exists?(Path.dirname(opts[:output_schema]))
  end

  test "failed preparation removes its allocated directory before returning" do
    parent = self()
    contract = contract()

    {caller, monitor} =
      spawn_monitor(fn ->
        result =
          S.open(contract,
            provider: GenAgent.Structured.StartupTest.GatedProvider,
            backend_opts: [owner: parent, output_schema: "conflict"]
          )

        send(parent, {:failed_prepare, result})
      end)

    assert_receive {:preparing, session, directory}
    assert File.dir?(directory)
    send(session, :continue)

    assert_receive {:failed_prepare,
                    {:error,
                     %Error{stage: :provider, reason: {:schema_option_conflict, :output_schema}}}},
                   1000

    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    refute File.exists?(directory)
  end

  test "idle sessions clean up when the opening owner exits normally or is killed" do
    parent = self()
    contract = contract()
    opts = [provider: GenAgent.Structured.StartupTest.Provider, backend_opts: [owner: parent]]

    for reason <- [:normal, :kill] do
      {owner, owner_monitor} =
        spawn_monitor(fn ->
          {:ok, session} = S.open(contract, opts)
          send(parent, {:opened, session})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:opened, session}
      assert_receive {:backend_started, agent, backend_opts}
      session_monitor = Process.monitor(session)
      agent_monitor = Process.monitor(agent)
      if reason == :normal, do: send(owner, :stop), else: Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, owner_reason}
      assert owner_reason == if(reason == :kill, do: :killed, else: :normal)
      assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}, 1000
      assert_receive {:DOWN, ^agent_monitor, :process, ^agent, _}, 1000
      refute File.exists?(Path.dirname(backend_opts[:output_schema]))
    end
  end

  test "owner death during preparation cannot leave a session after startup" do
    parent = self()
    contract = contract()

    opts = [
      provider: GenAgent.Structured.StartupTest.GatedProvider,
      backend_opts: [owner: parent]
    ]

    {owner, owner_monitor} = spawn_monitor(fn -> S.open(contract, opts) end)
    assert_receive {:preparing, session, directory}
    session_monitor = Process.monitor(session)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
    send(session, :continue)
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}, 1000
    assert_receive {:backend_started, agent, _}
    refute Process.alive?(agent)
    refute File.exists?(directory)
  end
end
