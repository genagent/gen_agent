defmodule GenAgent.Delegation.ContractBackend do
  @behaviour GenAgent.Backend
  def start_session(opts), do: {:ok, %{opts: opts, id: "fixture-session"}}

  def resume_session(id, opts) do
    send(opts[:owner], {:resumed, id, opts})
    {:ok, %{opts: opts, id: id}}
  end

  def prompt(session, message), do: run(session, message)

  def prompt(session, message, %{checkpoint: checkpoint}) do
    :ok = checkpoint.(session.id)
    run(session, message)
  end

  def checkpoint_session(session, id), do: %{session | id: id}
  def update_session(session, _), do: session
  def terminate_session(_), do: :ok

  defp run(session, message) do
    send(session.opts[:owner], {:execution_brief, message})
    request = message |> String.split("--- Delegated request ---\n", parts: 2) |> List.last()
    run_request(session, request)
  end

  defp run_request(session, "block") do
    send(session.opts[:owner], {:blocked, self()})

    receive do
      :done -> result(session, %{"answer" => "done"})
    end
  end

  defp run_request(_session, "failure"),
    do:
      {:error,
       GenAgent.Backend.Error.new(:claude, :rate_limited, %{secret: "raw secret"},
         retryable?: true,
         message: "Bearer abcdefghijklmnopqrstuvwxyz " <> String.duplicate("x", 4000)
       )}

  defp run_request(_session, "unicode failure"),
    do:
      {:error,
       GenAgent.Backend.Error.new(:codex, :server_error, %{},
         retryable?: false,
         message: String.duplicate("é", 600) <> " Bearer abcdefghijklmnopqrstuvwxyz"
       )}

  defp run_request(_session, "turn budget"),
    do:
      {:error,
       GenAgent.Backend.Error.normalize(:claude, %{
         subtype: "error_max_turns",
         message: "Turn budget reached",
         session_id: "budget-session",
         num_turns: 7,
         cost_usd: 0.25,
         usage: %{input_tokens: 100, output_tokens: 20}
       })}

  defp run_request(session, "large") do
    big = String.duplicate("m", 100_000)

    {:ok,
     [
       GenAgent.Event.new(:usage, %{input_tokens: 1, detail: big}),
       GenAgent.Event.new(:result, %{
         text: "large ok",
         session_id: session.id,
         model: "fixture-reported",
         model_source: :reported,
         cost_usd: big,
         duration_ms: 1,
         num_turns: 1
       })
     ], session}
  end

  defp run_request(session, "invalid"), do: result(session, %{"answer" => 42})
  defp run_request(session, message), do: result(session, %{"answer" => message})

  defp result(session, value) do
    opts = session.opts

    if opts[:output_schema],
      do:
        send(opts[:owner], {:schema_file, opts[:output_schema], File.read!(opts[:output_schema])})

    if opts[:json_schema], do: send(opts[:owner], {:schema_json, opts[:json_schema]})

    {:ok,
     [
       GenAgent.Event.new(:result, %{
         text: Jason.encode!(value),
         session_id: session.id,
         model: "fixture-reported",
         model_source: :reported,
         raw: %{"structured_output" => value}
       })
     ], session}
  end
end

defmodule GenAgent.Delegation.ContractsTest do
  use ExUnit.Case, async: true
  alias GenAgent.Delegation, as: D

  @schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "string"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  defp opts(extra) do
    Keyword.merge(
      [
        name: nil,
        default_backend: "claude",
        backends: %{
          "claude" => GenAgent.Delegation.ContractBackend,
          "codex" => GenAgent.Delegation.ContractBackend
        },
        backend_options: %{"claude" => [owner: self()], "codex" => [owner: self()]},
        state_dir: nil
      ],
      extra
    )
  end

  defp manager(extra \\ []),
    do: start_supervised!({D, opts(extra)}, id: make_ref(), restart: :temporary)

  defp spawn_task(manager, task, extra \\ %{}),
    do: D.spawn_task(Map.merge(%{"task" => task, "cwd" => File.cwd!()}, extra), manager)

  defp result(manager, task) do
    {:ok, %{"tasks" => [result]}} =
      D.wait_tasks(%{"task_ids" => [task["task_id"]], "timeout_ms" => 2000}, manager)

    result
  end

  defp directory do
    path = Path.join(System.tmp_dir!(), "delegate-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  test "native schemas validate Claude/Codex output and survive follow-ups" do
    manager = manager()

    for backend <- ["claude", "codex"] do
      {:ok, task} =
        spawn_task(manager, "first", %{
          "backend" => backend,
          "model" => "requested",
          "output_schema" => @schema
        })

      completed = result(manager, task)
      assert_receive {:execution_brief, brief}
      assert brief =~ "Execution capabilities supplied by GenAgent Delegate"

      if backend == "codex",
        do: assert(brief =~ "inspect local files using shell commands"),
        else: assert(brief =~ "Claude tools: Read, Glob, Grep.")

      assert completed["status"] == "completed"
      assert completed["structured_result"] == %{"answer" => "first"}
      assert completed["selection"]["requested"]["model"] == "requested"
      assert completed["selection"]["reported"]["model"] == "fixture-reported"

      if backend == "codex" do
        assert_receive {:schema_file, path, json}
        assert Jason.decode!(json) == @schema
        assert File.exists?(path)
      else
        assert_receive {:schema_json, json}
        assert Jason.decode!(json) == @schema
      end

      {:ok, next} =
        D.continue_task(%{"task_id" => task["task_id"], "message" => "second"}, manager)

      assert result(manager, next)["structured_result"] == %{"answer" => "second"}
      assert_receive {:execution_brief, brief}
      assert brief =~ "Execution capabilities supplied by GenAgent Delegate"
      assert result(manager, task)["structured_result"] == %{"answer" => "first"}
    end
  end

  test "waits omit schemas while running and completed, retaining structured results and full reads" do
    manager = manager()
    {:ok, task} = spawn_task(manager, "block", %{"output_schema" => @schema})
    assert_receive {:blocked, worker}

    for timeout <- [0, 1] do
      assert {:ok, %{"timed_out" => true, "tasks" => [poll]}} =
               D.wait_tasks(%{"task_ids" => [task["task_id"]], "timeout_ms" => timeout}, manager)

      assert poll["status"] == "running"
      refute Map.has_key?(poll, "output_schema")
    end

    waiter = Task.async(fn -> result(manager, task) end)
    send(worker, :done)
    completed = Task.await(waiter)
    assert completed["status"] == "completed"
    assert completed["structured_result"] == %{"answer" => "done"}
    refute Map.has_key?(completed, "output_schema")
    assert result(manager, task) == completed
    {:ok, %{"tasks" => [full]}} = D.list_tasks(%{"full_result" => true}, manager)
    assert full["output_schema"] == @schema
    assert Map.delete(full, "output_schema") == completed
  end

  test "invalid output fails; invalid schemas fail before provider work" do
    manager = manager()
    {:ok, task} = spawn_task(manager, "invalid", %{"output_schema" => @schema})
    completed = result(manager, task)
    assert completed["status"] == "failed"
    assert completed["error_info"]["kind"] == "invalid_structured_output"
    assert completed["structured_result"] == nil
    assert completed["provider_session_id"] == "fixture-session"

    for schema <- [
          %{},
          %{"type" => "object", "$ref" => "https://example.com/schema"},
          %{"type" => "object", "properties" => %{"a" => %{"type" => "nonsense"}}}
        ] do
      assert {:error, %{code: "invalid_args"}} =
               spawn_task(manager, "must not start", %{"output_schema" => schema})
    end
  end

  test "typed errors are redacted and bounded while early session identity survives" do
    manager = manager()
    {:ok, task} = spawn_task(manager, "failure")
    completed = result(manager, task)
    assert completed["provider_session_id"] == "fixture-session"
    assert completed["error_info"]["kind"] == "rate_limited"
    assert completed["error_info"]["retryable?"]
    assert completed["error_info"]["message"] =~ "[REDACTED]"
    refute completed["error_info"]["message"] =~ "abcdefghijklmnopqrstuvwxyz"
    assert String.length(completed["error_info"]["message"]) <= 2000
    refute Map.has_key?(completed["error_info"], "raw")
  end

  test "compact lists preserve metadata and filter since; full reads retain output" do
    manager = manager()
    {:ok, task} = spawn_task(manager, "listed")
    completed = result(manager, task)
    assert completed["event_count"] >= 1
    {:ok, %{"tasks" => [compact]}} = D.list_tasks(%{"since" => task["started_at_ms"]}, manager)
    refute Map.has_key?(compact, "result")
    refute Map.has_key?(compact, "structured_result")
    assert compact["last_event"] == "result"
    {:ok, %{"tasks" => [full]}} = D.list_tasks(%{"full_result" => true}, manager)
    assert full["result"] == completed["result"]

    assert {:ok, %{"tasks" => []}} =
             D.list_tasks(%{"since" => task["started_at_ms"] + 1}, manager)
  end

  test "provider budget failures retain available evidence without implicit continuation" do
    manager = manager()
    {:ok, task} = spawn_task(manager, "turn budget")
    failed = result(manager, task)
    assert failed["status"] == "failed"
    assert failed["provider_session_id"] == "budget-session"
    assert failed["provider_metadata"]["subtype"] == "error_max_turns"
    assert failed["provider_metadata"]["num_turns"] == 7
    assert failed["provider_metadata"]["cost_usd"] == 0.25
    assert failed["usage"] == %{"input_tokens" => 100, "output_tokens" => 20}

    assert {:error, %{code: "not_completed"}} =
             D.continue_task(%{"task_id" => task["task_id"], "message" => "retry"}, manager)

    refute_receive {:resumed, _, _}
  end

  @summary_keys ~w(task_id conversation_id parent_task_id cwd backend status started_at_ms
                   finished_at_ms last_activity_at_ms event_count last_event profile access
                   model effort timeout_secs result_truncated error error_info)

  test "default list rows are an allowlist; large usage and metadata cannot inflate them" do
    manager = manager()
    {:ok, task} = spawn_task(manager, "large", %{"model" => "requested"})
    completed = result(manager, task)
    assert completed["status"] == "completed"
    assert String.length(completed["provider_metadata"]["cost_usd"]) == 100_000
    assert completed["usage"]["detail"] |> String.length() == 100_000

    {:ok, %{"tasks" => [compact]}} = D.list_tasks(%{}, manager)
    assert Map.keys(compact) -- @summary_keys == []
    assert compact["task_id"] == task["task_id"]
    assert compact["status"] == "completed"
    assert compact["backend"] == "claude"
    assert compact["model"] == "requested"

    for key <-
          ~w(result structured_result output_schema usage provider_metadata selection provider_session_id) do
      refute Map.has_key?(compact, key)
    end

    assert byte_size(Jason.encode!(compact)) < 2_000

    {:ok, %{"tasks" => [full]}} = D.list_tasks(%{"full_result" => true}, manager)
    assert full["usage"] == completed["usage"]
    assert full["provider_metadata"] == completed["provider_metadata"]
    assert full["selection"] == completed["selection"]
    assert full["provider_session_id"] == "fixture-session"
    assert full["result"] == "large ok"
    assert Map.delete(full, "output_schema") == completed
  end

  test "failed rows keep bounded redacted diagnostics and only kind/retryable error info" do
    manager = manager()
    {:ok, rate} = spawn_task(manager, "failure")
    {:ok, uni} = spawn_task(manager, "unicode failure", %{"backend" => "codex"})
    rate_full = result(manager, rate)
    uni_full = result(manager, uni)

    {:ok, %{"tasks" => rows}} = D.list_tasks(%{}, manager)
    by_id = Map.new(rows, &{&1["task_id"], &1})

    compact = by_id[rate["task_id"]]
    assert compact["status"] == "failed"
    assert compact["error_info"] == %{"kind" => "rate_limited", "retryable?" => true}
    assert compact["error"] =~ "[REDACTED]"
    refute compact["error"] =~ "abcdefghijklmnopqrstuvwxyz"
    assert String.length(compact["error"]) <= 256
    assert Map.keys(compact) -- @summary_keys == []
    refute Map.has_key?(compact, "provider_session_id")

    unicode = by_id[uni["task_id"]]
    assert unicode["error_info"] == %{"kind" => "server_error", "retryable?" => false}
    assert String.length(unicode["error"]) <= 256
    assert length(String.codepoints(unicode["error"])) <= 256
    assert String.valid?(unicode["error"])

    {:ok, %{"tasks" => full_rows}} = D.list_tasks(%{"full_result" => true}, manager)
    full_by_id = Map.new(full_rows, &{&1["task_id"], &1})
    assert Map.delete(full_by_id[rate["task_id"]], "output_schema") == rate_full
    assert Map.delete(full_by_id[uni["task_id"]], "output_schema") == uni_full
    assert String.length(full_by_id[rate["task_id"]]["error_info"]["message"]) > 256
  end

  test "records reopen and continue the latest successful provider conversation" do
    dir = directory()
    {:ok, first_manager} = D.start_link(opts(state_dir: dir))

    {:ok, first} =
      spawn_task(first_manager, "original private prompt", %{"output_schema" => @schema})

    assert result(first_manager, first)["status"] == "completed"

    {:ok, latest} =
      D.continue_task(%{"task_id" => first["task_id"], "message" => "latest"}, first_manager)

    expected = result(first_manager, latest)
    GenServer.stop(first_manager)
    manager = manager(state_dir: dir)
    assert result(manager, latest) == expected

    assert {:error, %{code: "stale_task"}} =
             D.continue_task(%{"task_id" => first["task_id"], "message" => "stale"}, manager)

    {:ok, continued} =
      D.continue_task(%{"task_id" => latest["task_id"], "message" => "resumed"}, manager)

    assert_receive {:resumed, "fixture-session", _opts}
    assert continued["conversation_id"] == first["conversation_id"]
    assert result(manager, continued)["structured_result"] == %{"answer" => "resumed"}
    [record | _] = Path.wildcard(Path.join(dir, "*.json"))
    refute Map.has_key?(Jason.decode!(File.read!(record))["spec"], "task")
  end

  test "a failed follow-up cannot resume itself or roll back to its successful parent" do
    manager = manager()
    {:ok, first} = spawn_task(manager, "first")
    assert result(manager, first)["status"] == "completed"

    {:ok, follow_up} =
      D.continue_task(%{"task_id" => first["task_id"], "message" => "failure"}, manager)

    assert result(manager, follow_up)["status"] == "failed"

    assert {:error, %{code: "not_completed"}} =
             D.continue_task(%{"task_id" => follow_up["task_id"], "message" => "retry"}, manager)

    assert {:error, %{code: "stale_task"}} =
             D.continue_task(%{"task_id" => first["task_id"], "message" => "rollback"}, manager)
  end

  test "shutdown marks unfinished work interrupted on reopen without replay" do
    dir = directory()
    {:ok, first_manager} = D.start_link(opts(state_dir: dir))
    {:ok, task} = spawn_task(first_manager, "block")
    assert_receive {:blocked, _}
    # A manager call is ordered after its checkpoint notification from the worker.
    {:ok, _} = D.list_tasks(%{}, first_manager)
    GenServer.stop(first_manager)
    manager = manager(state_dir: dir)
    recovered = result(manager, task)
    assert recovered["status"] == "interrupted"
    assert recovered["provider_session_id"] == "fixture-session"
    refute recovered["provider_settled"]

    assert {:error, %{code: "not_completed"}} =
             D.continue_task(%{"task_id" => task["task_id"], "message" => "retry"}, manager)

    refute_receive {:blocked, _}
  end
end
