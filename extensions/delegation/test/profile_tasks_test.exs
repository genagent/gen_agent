defmodule GenAgent.Delegation.ProfileBackend do
  @behaviour GenAgent.Backend
  def start_session(opts), do: {:ok, %{opts: opts, id: "profile-session"}}

  def resume_session(id, opts) do
    send(opts[:owner], {:profile_resumed, id})
    {:ok, %{opts: opts, id: id}}
  end

  def checkpoint_session(session, id), do: %{session | id: id}
  def update_session(session, _), do: session
  def terminate_session(_), do: :ok
  def prompt(session, prompt), do: run(session, prompt)

  def prompt(session, prompt, %{checkpoint: checkpoint}) do
    :ok = checkpoint.(session.id)
    run(session, prompt)
  end

  defp run(session, prompt) do
    send(session.opts[:owner], {:profile_invoked, prompt, session.opts})
    value = %{"answer" => prompt}

    {:ok,
     [
       GenAgent.Event.new(:result, %{
         text: Jason.encode!(value),
         session_id: session.id,
         raw: %{"structured_output" => value}
       })
     ], session}
  end
end

defmodule GenAgent.Delegation.ProfileTasksTest do
  use ExUnit.Case, async: true
  alias GenAgent.Delegation, as: D

  @input %{
    "type" => "object",
    "properties" => %{"question" => %{"type" => "string"}},
    "required" => ["question"],
    "additionalProperties" => false
  }
  @output %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "string"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  defp manager(opts \\ []) do
    start_supervised!(
      {D,
       Keyword.merge(
         [
           name: nil,
           default_backend: "claude",
           backends: %{"claude" => GenAgent.Delegation.ProfileBackend},
           backend_options: %{"claude" => [owner: self()]},
           state_dir: nil
         ],
         opts
       )},
      id: make_ref(),
      restart: :temporary
    )
  end

  defp definition(extra \\ %{}),
    do:
      Map.merge(
        %{
          "name" => "custom",
          "instructions" => "Original behavior.",
          "skill" => "Use supplied evidence only.",
          "input_schema" => @input,
          "output_schema" => @output
        },
        extra
      )

  defp spawn_profile(manager, input, extra \\ %{}),
    do:
      D.spawn_task(
        Map.merge(%{"profile" => "custom", "input" => input, "cwd" => File.cwd!()}, extra),
        manager
      )

  defp result(manager, task) do
    {:ok, %{"tasks" => [result]}} =
      D.wait_tasks(%{"task_ids" => [task["task_id"]], "timeout_ms" => 2000}, manager)

    result
  end

  defp directory do
    dir = Path.join(System.tmp_dir!(), "delegate-profiles-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "catalog exposes examples and a dynamic profile validates input before provider admission" do
    manager = manager()
    {:ok, %{"profiles" => profiles}} = D.list_profiles(%{}, manager)
    assert Enum.map(profiles, & &1["name"]) == ~w(elixir-developer researcher reviewer)
    {:ok, registered} = D.register_profile(definition(), manager)
    assert {:ok, ^registered} = D.get_profile(%{"name" => "custom"}, manager)
    assert {:error, _} = D.register_profile(definition(), manager)
    assert {:error, %{code: "invalid_input"}} = spawn_profile(manager, %{"question" => 3})
    assert {:error, %{code: "invalid_input"}} = spawn_profile(manager, %{"wrong" => "shape"})
    assert {:ok, %{"tasks" => []}} = D.list_tasks(%{}, manager)
    refute_receive {:profile_invoked, _, _}
    {:ok, task} = spawn_profile(manager, %{"question" => "read"})
    assert task["profile"] == Map.take(registered, ~w(name revision))
    assert_receive {:profile_invoked, prompt, opts}

    assert prompt =~ "Claude tools: Read, Glob, Grep."

    assert String.ends_with?(
             prompt,
             "Original behavior.\n\nSkill:\nUse supplied evidence only.\n\nInput (JSON):\n{\"question\":\"read\"}"
           )

    assert opts[:permission_mode] == :dont_ask
    refute "Edit" in opts[:tools]
    assert result(manager, task)["structured_result"] == %{"answer" => prompt}
    {:ok, %{"tasks" => [summary]}} = D.list_tasks(%{}, manager)
    assert summary["profile"] == Map.take(registered, ~w(name revision))
    refute Map.has_key?(summary, "output_schema")
    refute Map.has_key?(summary, "structured_result")
  end

  test "replacing and deleting a definition cannot change old task or continuation snapshots" do
    manager = manager()
    {:ok, original} = D.register_profile(definition(), manager)
    {:ok, task} = spawn_profile(manager, %{"question" => "first"})
    expected = result(manager, task)

    {:ok, replacement} =
      D.register_profile(
        definition(%{"replace" => true, "instructions" => "New behavior."}),
        manager
      )

    refute replacement["revision"] == original["revision"]
    {:ok, newer} = spawn_profile(manager, %{"question" => "new"})
    assert result(manager, newer)["structured_result"]["answer"] =~ "New behavior."
    {:ok, %{"deleted" => true}} = D.delete_profile(%{"name" => "custom"}, manager)
    assert {:error, _} = spawn_profile(manager, %{"question" => "unknown"})

    {:ok, next} =
      D.continue_task(
        %{"task_id" => task["task_id"], "input" => %{"question" => "follow up"}},
        manager
      )

    continued = result(manager, next)
    assert continued["structured_result"]["answer"] =~ "Original behavior."
    refute continued["structured_result"]["answer"] =~ "New behavior."
    assert next["profile"]["revision"] == original["revision"]
    assert result(manager, task) == expected
  end

  test "ordinary requests keep their API; ambiguous profile and follow-up inputs are rejected" do
    manager = manager()
    {:ok, _} = D.register_profile(definition(), manager)

    for extra <- [
          %{"task" => "override"},
          %{"output_schema" => @output},
          %{"output_schema" => nil}
        ] do
      assert {:error, %{code: "invalid_args"}} =
               spawn_profile(manager, %{"question" => "q"}, extra)
    end

    assert {:error, _} = D.spawn_task(%{"profile" => "custom", "cwd" => File.cwd!()}, manager)

    assert {:error, _} =
             D.spawn_task(
               %{"profile" => nil, "input" => %{}, "task" => "plain", "cwd" => File.cwd!()},
               manager
             )

    {:ok, plain} =
      D.spawn_task(%{"task" => "plain", "profile" => nil, "cwd" => File.cwd!()}, manager)

    assert result(manager, plain)["profile"] == nil

    assert {:error, _} =
             D.continue_task(%{"task_id" => plain["task_id"], "input" => nil}, manager)

    {:ok, followed} =
      D.continue_task(%{"task_id" => plain["task_id"], "message" => "follow"}, manager)

    assert result(manager, followed)["status"] == "completed"
    {:ok, profiled} = spawn_profile(manager, %{"question" => "q"})
    result(manager, profiled)

    for args <- [
          %{"message" => "override"},
          %{"input" => %{}},
          %{"input" => %{"question" => "q"}, "message" => "override"}
        ] do
      assert {:error, _} = D.continue_task(Map.put(args, "task_id", profiled["task_id"]), manager)
    end
  end

  test "a schema-free skill accepts explicit JSON null without requiring structured output" do
    manager = manager()
    {:ok, _} = D.register_profile(%{"name" => "custom", "skill" => "Be concise."}, manager)
    {:ok, task} = spawn_profile(manager, nil)
    assert_receive {:profile_invoked, prompt, _}
    assert String.ends_with?(prompt, "Be concise.\n\nInput (JSON):\nnull")
    assert result(manager, task)["status"] == "completed"
    assert result(manager, task)["structured_result"] == nil
  end

  test "catalog mutations and per-task snapshots survive restart without persisting request input" do
    dir = directory()
    first = manager(state_dir: dir)
    {:ok, original} = D.register_profile(definition(), first)
    {:ok, task} = spawn_profile(first, %{"question" => "PRIVATE-REQUEST-INPUT"})
    completed = result(first, task)

    {:ok, replacement} =
      D.register_profile(
        definition(%{"replace" => true, "instructions" => "Revised behavior."}),
        first
      )

    {:ok, _} = D.delete_profile(%{"name" => "reviewer"}, first)
    GenServer.stop(first)
    second = manager(state_dir: dir)
    assert {:ok, ^replacement} = D.get_profile(%{"name" => "custom"}, second)
    assert {:error, _} = D.get_profile(%{"name" => "reviewer"}, second)
    assert result(second, task) == completed

    {:ok, next} =
      D.continue_task(
        %{"task_id" => task["task_id"], "input" => %{"question" => "after restart"}},
        second
      )

    assert_receive {:profile_resumed, "profile-session"}
    assert next["profile"]["revision"] == original["revision"]
    assert result(second, next)["structured_result"]["answer"] =~ "Original behavior."
    disk = File.read!(Path.join(dir, task["task_id"] <> ".json")) |> Jason.decode!()
    refute Map.has_key?(disk["spec"], "input")
    refute Map.has_key?(disk["spec"], "task")
    refute Jason.encode!(disk["spec"]) =~ "PRIVATE-REQUEST-INPUT"
    assert disk["spec"]["profile_snapshot"]["revision"] == original["revision"]

    # Intentional output can contain request content; persistence is not redaction of task results.
  end

  test "failed catalog writes leave the in-memory catalog unchanged" do
    dir = directory()
    manager = manager(state_dir: dir)
    File.rm!(Path.join(dir, ".profiles.json"))
    File.mkdir!(Path.join(dir, ".profiles.json"))
    assert {:error, %{code: "persistence_failed"}} = D.register_profile(definition(), manager)
    assert {:error, _} = D.get_profile(%{"name" => "custom"}, manager)
    {:ok, %{"profiles" => profiles}} = D.list_profiles(%{}, manager)
    assert length(profiles) == 3
  end

  test "milestone-one task records load and resume without profile metadata" do
    dir = directory()
    {:ok, store} = GenAgent.Delegation.Store.open(dir)

    old = %{
      "task_id" => "legacy_task",
      "conversation_id" => "legacy_conversation",
      "parent_task_id" => nil,
      "status" => "completed",
      "started_at_ms" => 1,
      "finished_at_ms" => 2,
      "provider_session_id" => "profile-session",
      "result" => "legacy result"
    }

    spec = %{
      "backend" => "claude",
      "cwd" => File.cwd!(),
      "access" => "read_only",
      "timeout_secs" => 30,
      "selection" => %{
        "requested" => %{},
        "selected" => %{"backend" => "claude"},
        "reported" => %{}
      }
    }

    :ok = GenAgent.Delegation.Store.save(store, old, spec)
    :ok = GenAgent.Delegation.Store.close(store)
    manager = manager(state_dir: dir)
    assert result(manager, old) == old

    {:ok, followed} =
      D.continue_task(%{"task_id" => "legacy_task", "message" => "ordinary follow-up"}, manager)

    assert_receive {:profile_resumed, "profile-session"}
    assert result(manager, followed)["status"] == "completed"
    assert followed["profile"] == nil
    assert {:ok, %{"profiles" => [_, _, _]}} = D.list_profiles(%{}, manager)
  end
end
