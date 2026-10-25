defmodule GenAgent.StructuredTest.Backend do
  @behaviour GenAgent.Backend

  def start_session(opts) do
    owner = Keyword.fetch!(opts, :owner)
    send(owner, {:backend_started, self(), opts})
    {:ok, %{opts: opts, owner: owner, turn: 0}}
  end

  def prompt(state, prompt) do
    send(state.owner, {:prompt, self(), prompt})
    if Keyword.get(state.opts, :block), do: receive(do: (:finish -> :ok))

    if Keyword.get(state.opts, :fail) do
      {:error, :provider_failure}
    else
      output = Keyword.get(state.opts, :output, ~s({"answer":42}))
      events = [GenAgent.Event.new(:result, %{text: output, session_id: "fixture-session"})]
      {:ok, events, %{state | turn: state.turn + 1}}
    end
  end

  def terminate_session(state) do
    send(state.owner, :backend_stopped)
    :ok
  end
end

defmodule GenAgent.StructuredTest.Provider do
  @behaviour GenAgent.Structured.Provider
  def backend, do: GenAgent.StructuredTest.Backend
  defdelegate prepare(schema, opts, directory), to: GenAgent.Structured.Providers.Codex
  defdelegate extract(response, schema), to: GenAgent.Structured.Providers.Codex
end

defmodule GenAgent.StructuredTest do
  use ExUnit.Case, async: true
  alias GenAgent.Structured, as: S
  alias GenAgent.Structured.{Error, Profiles, Result}

  @input %{
    "type" => "object",
    "properties" => %{"question" => %{"type" => "string"}},
    "required" => ["question"],
    "additionalProperties" => false
  }
  @output %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  defp contract(extra \\ []) do
    {:ok, contract} =
      S.contract(
        Keyword.merge(
          [instructions: "Answer the question.", input_schema: @input, output_schema: @output],
          extra
        )
      )

    contract
  end

  defp options(extra \\ []),
    do: [provider: __MODULE__.Provider, backend_opts: Keyword.merge([owner: self()], extra)]

  defp input, do: %{"question" => "What is the answer?"}

  test "one-shot validates before any backend starts and closes after success" do
    assert {:error, %Error{stage: :input}} = S.run(contract(), %{"question" => 12}, options())
    refute_received {:backend_started, _, _}

    assert {:ok, %Result{output: %{"answer" => 42}, response: response, request_id: id}} =
             S.run(contract(), input(), options())

    assert is_binary(id)
    assert response.final_message == ~s({"answer":42})
    assert_receive {:backend_started, agent, backend_opts}
    assert_receive :backend_stopped
    refute Process.alive?(agent)
    refute File.exists?(backend_opts[:output_schema])
    refute File.dir?(Path.dirname(backend_opts[:output_schema]))
  end

  test "explicit reuse holds fixed schema, gives separate request IDs and closes files" do
    assert {:ok, session} = S.open(contract(), options())
    assert_receive {:backend_started, _, backend_opts}
    path = backend_opts[:output_schema]
    assert File.exists?(path)
    assert {:ok, first} = S.request(session, input())
    assert {:ok, second} = S.request(session, input())
    assert first.request_id != second.request_id
    refute_received {:backend_started, _, _}
    assert File.exists?(path)
    assert :ok = S.close(session)
    refute File.exists?(path)
    assert :ok = S.close(session)
  end

  test "schema is optional on either side and plain output remains text" do
    assert {:ok, %Result{output: "plain"}} =
             S.run(contract(output_schema: nil), input(), options(output: "plain"))

    assert_receive {:backend_started, _, backend_opts}
    refute Keyword.has_key?(backend_opts, :output_schema)

    assert {:ok, %Result{output: %{"answer" => 42}}} =
             S.run(contract(input_schema: nil), ["JSON", "array"], options())
  end

  test "output failures preserve original response and are never automatically retried" do
    for output <- ["not JSON", ~s({"answer":"wrong type"}), ~s({"answer":42,"extra":true})] do
      assert {:error, %Error{stage: :output, response: response, request_id: id}} =
               S.run(contract(), input(), options(output: output))

      assert is_binary(id)
      assert response.final_message == output
      assert_receive {:prompt, _, _}
      refute_received {:prompt, _, _}
    end
  end

  test "oversized structured output fails without truncating or dropping audit response" do
    assert {:error, %Error{stage: :output, response: response}} =
             S.run(contract(max_output_bytes: 2), input(), options())

    assert response.final_message == ~s({"answer":42})
  end

  test "provider failure remains distinct from output validation" do
    assert {:error, %Error{stage: :provider, response: nil}} =
             S.run(contract(), input(), options(fail: true))

    assert_receive :backend_stopped
  end

  test "invalid input in a reused session never dispatches a prompt" do
    {:ok, session} = S.open(contract(), options())
    assert {:error, %Error{stage: :input}} = S.request(session, %{})
    refute_received {:prompt, _, _}
    assert {:ok, _} = S.request(session, input())
    S.close(session)
  end

  test "a blocked request does not block close or admit a second request" do
    {:ok, session} = S.open(contract(), options(block: true))
    assert_receive {:backend_started, _, backend_opts}
    request = Task.async(fn -> S.request(session, input()) end)
    assert_receive {:prompt, worker, _}
    monitor = Process.monitor(worker)
    assert {:error, %Error{stage: :lifecycle, reason: :busy}} = S.request(session, input())
    assert :ok = S.close(session)
    assert {:error, %Error{stage: :lifecycle, reason: :closed}} = Task.await(request)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    refute File.exists?(backend_opts[:output_schema])
  end

  test "watchdog bounds a running request and returns a provider error" do
    opts = Keyword.put(options(block: true), :timeout_ms, 30)
    assert {:error, %Error{stage: :provider, reason: :timeout}} = S.run(contract(), input(), opts)
  end

  @tag capture_log: true
  test "forced session death cleans BEAM worker and owned schema directory" do
    {:ok, session} = S.open(contract(), options(block: true))
    assert_receive {:backend_started, agent, backend_opts}
    assert File.exists?(backend_opts[:output_schema])
    request = Task.async(fn -> S.request(session, input()) end)
    assert_receive {:prompt, worker, _}
    worker_monitor = Process.monitor(worker)
    agent_monitor = Process.monitor(agent)
    Process.exit(session, :kill)
    assert {:error, %Error{stage: :lifecycle}} = Task.await(request)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}
    assert_receive {:DOWN, ^agent_monitor, :process, ^agent, _}
    # Synchronize with the independent file owner after it processes DOWN.
    GenAgent.Structured.Files.release(session)
    refute File.exists?(backend_opts[:output_schema])
  end

  test "caller death closes its in-flight session" do
    {:ok, session} = S.open(contract(), options(block: true))
    assert_receive {:backend_started, _, backend_opts}
    caller = spawn(fn -> S.request(session, input()) end)
    assert_receive {:prompt, worker, _}
    monitor = Process.monitor(session)
    worker_monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}
    refute File.exists?(backend_opts[:output_schema])
  end

  test "configuration mistakes fail explicitly" do
    for opts <- [
          [],
          [provider: :unknown],
          [provider: __MODULE__.Provider, timeout_ms: 0],
          [provider: __MODULE__.Provider, surprise: true],
          [provider: __MODULE__.Provider, backend_opts: :bad]
        ] do
      assert {:error, %Error{stage: :config}} = S.open(contract(), opts)
    end

    refute_received {:backend_started, _, _}
  end

  test "external resume selectors cannot smuggle history into a fresh contract" do
    for selector <- [:resume, :continue_session, :fork_session, :session_id, :thread_id] do
      opts = options([{selector, "existing-session"}])

      assert {:error,
              %Error{stage: :config, reason: {:external_conversation_unsupported, ^selector}}} =
               S.run(contract(), input(), opts)
    end

    refute_received {:backend_started, _, _}
  end

  test "named profile validates data before startup and stamps successful results" do
    registry = start_supervised!(Profiles)

    {:ok, profile} =
      Profiles.register(registry, "answer",
        skill: "Answer exactly as specified.",
        input_schema: @input,
        output_schema: @output
      )

    metadata = %{name: profile.name, revision: profile.revision}
    opts = Keyword.put(options(), :profiles, registry)

    assert {:error, %Error{stage: :input, profile: ^metadata}} = S.run("answer", %{}, opts)
    refute_received {:backend_started, _, _}

    assert {:ok, %Result{output: %{"answer" => 42}, profile: ^metadata}} =
             S.run("answer", input(), opts)

    assert_receive {:prompt, _, prompt}
    assert prompt == "Answer exactly as specified.\n\nInput (JSON):\n" <> Jason.encode!(input())
  end

  test "live sessions pin behavior and both schemas across replacement and registry loss" do
    registry = start_supervised!(Profiles)

    {:ok, first} =
      Profiles.register(registry, "answer",
        instructions: "First behavior",
        input_schema: @input,
        output_schema: @output
      )

    metadata = %{name: first.name, revision: first.revision}
    opts = Keyword.put(options(), :profiles, registry)
    {:ok, session} = S.open("answer", opts)
    assert_receive {:backend_started, _, _}

    {:ok, second} =
      Profiles.replace(registry, "answer",
        instructions: "Replacement behavior",
        input_schema: %{"type" => "integer"},
        output_schema: %{"type" => "string"}
      )

    replacement_metadata = %{name: second.name, revision: second.revision}

    assert {:ok, %Result{output: %{"answer" => 42}, profile: ^metadata}} =
             S.request(session, input())

    assert_receive {:prompt, _, "First behavior\n\nInput (JSON):\n" <> _}
    assert {:error, %Error{stage: :input, profile: ^metadata}} = S.request(session, 1)

    assert {:error, %Error{stage: :output, profile: ^replacement_metadata, response: response}} =
             S.run("answer", 1, opts)

    assert response.final_message == ~s({"answer":42})
    assert_receive {:prompt, _, "Replacement behavior\n\nInput (JSON):\n1"}

    assert :ok = Profiles.unregister(registry, "answer")
    GenServer.stop(registry)
    assert {:ok, %Result{profile: ^metadata}} = S.request(session, input())
    assert_receive {:prompt, _, "First behavior\n\nInput (JSON):\n" <> _}
    assert :ok = S.close(session)
  end

  test "fetched profiles remain executable snapshots after unregistering" do
    registry = start_supervised!(Profiles)
    {:ok, profile} = Profiles.register(registry, "answer", instructions: "Only instructions")
    :ok = Profiles.unregister(registry, "answer")

    assert {:ok, %Result{output: "plain", profile: %{name: "answer"}}} =
             S.run(profile, %{}, options(output: "plain"))
  end

  test "unknown profiles and malformed selector options never start the backend" do
    registry = start_supervised!(Profiles)
    opts = Keyword.put(options(), :profiles, registry)

    assert {:error, %Error{reason: {:profile_not_found, "missing"}}} =
             S.run("missing", input(), opts)

    assert {:error, %Error{reason: :profile_registry_required}} =
             S.run("missing", input(), options())

    assert {:error, %Error{stage: :config}} = S.open("missing", :bad)
    assert {:error, %Error{stage: :config}} = S.open("missing", [profiles: registry] ++ opts)
    assert {:error, %Error{stage: :config}} = S.open(contract(), opts)

    for invalid <- [123, %{}, "not-a-server-ref"] do
      assert {:error, %Error{stage: :config}} =
               S.run("missing", input(), Keyword.put(options(), :profiles, invalid))
    end

    refute_received {:backend_started, _, _}
  end

  test "profile revision survives provider errors and plain contracts have no profile" do
    registry = start_supervised!(Profiles)
    {:ok, profile} = Profiles.register(registry, "answer", instructions: "Answer")
    metadata = %{name: profile.name, revision: profile.revision}

    assert {:error, %Error{stage: :config, profile: ^metadata}} =
             S.open(profile, provider: :unknown)

    refute_received {:backend_started, _, _}

    assert {:error, %Error{stage: :provider, profile: ^metadata}} =
             S.run(profile, %{}, options(fail: true))

    assert {:ok, %Result{profile: nil}} = S.run(contract(), input(), options())
  end
end

defmodule GenAgent.StructuredFileOwnerFailureTest do
  use ExUnit.Case, async: false
  alias GenAgent.Structured, as: S

  @tag capture_log: true
  test "file owner crash closes sessions without leaking their schema files" do
    {:ok, contract} = S.contract(instructions: "fixture", output_schema: %{"type" => "object"})

    {:ok, session} =
      S.open(contract, provider: GenAgent.StructuredTest.Provider, backend_opts: [owner: self()])

    assert_receive {:backend_started, _, opts}
    path = opts[:output_schema]
    assert File.exists?(path)
    session_monitor = Process.monitor(session)
    Process.exit(Process.whereis(GenAgent.Structured.Files), :kill)
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}
    refute File.exists?(path)
    refute File.dir?(Path.dirname(path))
  end
end
