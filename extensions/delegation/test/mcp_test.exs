defmodule GenAgent.Delegation.MCPTest do
  use ExUnit.Case, async: false

  defmodule UsageBackend do
    @behaviour GenAgent.Backend

    def start_session(_opts), do: {:ok, nil}

    def prompt(session, _prompt) do
      events = [
        GenAgent.Event.new(:usage, %{input_tokens: 12, output_tokens: 3}),
        GenAgent.Event.new(:result, %{text: "usage recorded"})
      ]

      {:ok, events, session}
    end

    def terminate_session(_session), do: :ok
  end

  setup do
    start_supervised!(
      {GenAgent.Delegation,
       default_backend: "claude",
       backends: %{"claude" => GenAgent.Delegation.Echo, "codex" => GenAgent.Delegation.Echo},
       state_dir: nil}
    )

    {:ok, client} = Snodo.Client.direct(GenAgent.Delegation.MCP.runtime())
    on_exit(fn -> Snodo.Client.close(client) end)
    %{client: client}
  end

  test "identity describes the actual manager rather than state-directory environment hints" do
    directory =
      Path.join(System.tmp_dir!(), "delegate-identity-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    manager =
      start_supervised!(
        {GenAgent.Delegation,
         name: nil, state_dir: directory, default_backend: "codex", max_running: 2, max_tasks: 7},
        restart: :temporary,
        id: :identity_manager
      )

    identity = GenAgent.Delegation.MCP.server_identity(manager)
    assert identity["name"] == "gen-agent-delegate"
    assert identity["version"] == "0.0.12"
    assert identity["state_directory"] == Path.expand(directory)
    assert identity["default_backend"] == "codex"
    assert identity["max_running"] == 2
    assert identity["max_tasks"] == 7
    assert File.regular?(identity["runtime_module_path"])

    assert String.ends_with?(
             identity["runtime_module_path"],
             "Elixir.GenAgent.Delegation.MCP.beam"
           )

    assert Snodo.JSONValue.valid?(identity)
    refute Map.has_key?(identity, "backend_options")
    refute Map.has_key?(identity, "task_records")
  end

  test "discovers ten task and profile tools with public provider schemas", %{client: client} do
    assert {:ok, tools} = Snodo.Client.list_tools(client)

    assert Enum.sort(Enum.map(tools, & &1["name"])) ==
             ~w(cancel_task check_environment continue_task delete_profile get_profile list_profiles list_tasks register_profile spawn_task wait_tasks)

    spawn = Enum.find(tools, &(&1["name"] == "spawn_task"))
    assert spawn["inputSchema"]["required"] == ["cwd"]
    assert spawn["inputSchema"]["properties"]["profile"]["type"] == ["string", "null"]
    refute Map.has_key?(spawn["inputSchema"]["properties"]["input"], "type")
    assert spawn["inputSchema"]["properties"]["backend"]["enum"] == ["claude", "codex"]
    assert spawn["inputSchema"]["properties"]["output_schema"]["type"] == "object"
    wait = Enum.find(tools, &(&1["name"] == "wait_tasks"))
    assert wait["inputSchema"]["properties"]["timeout_ms"]["default"] == 30_000
    list = Enum.find(tools, &(&1["name"] == "list_tasks"))
    assert list["inputSchema"]["properties"]["limit"]["maximum"] == 10_000
    assert list["inputSchema"]["properties"]["full_result"]["default"] == false
    assert spawn["inputSchema"]["properties"]["access"]["default"] == "read_only"
    assert spawn["inputSchema"]["additionalProperties"] == false

    register = Enum.find(tools, &(&1["name"] == "register_profile"))
    assert register["inputSchema"]["required"] == ["name"]
    assert register["inputSchema"]["properties"]["replace"]["default"] == false
    refute Map.has_key?(register["inputSchema"]["properties"], "backend")
    assert register["inputSchema"]["additionalProperties"] == false
    continue = Enum.find(tools, &(&1["name"] == "continue_task"))
    assert continue["inputSchema"]["required"] == ["task_id"]
    assert Map.has_key?(continue["inputSchema"]["properties"], "input")
  end

  test "profile CRUD and pinned continuations work through MCP", %{client: client} do
    name = "mcp-profile-#{System.unique_integer([:positive])}"

    original = call(client, "register_profile", %{"name" => name, "skill" => "Original behavior"})
    assert original["name"] == name
    assert is_binary(original["revision"])
    assert original["skill"] == "Original behavior"
    assert call(client, "get_profile", %{"name" => name}) == original

    profiles = call(client, "list_profiles", %{})["profiles"]
    metadata = Enum.find(profiles, &(&1["name"] == name))
    assert metadata["revision"] == original["revision"]
    refute Map.has_key?(metadata, "skill")
    refute Map.has_key?(metadata, "input_schema")

    assert Enum.all?(~w(researcher elixir-developer reviewer), fn seeded ->
             Enum.any?(profiles, &(&1["name"] == seeded))
           end)

    first =
      call(client, "spawn_task", %{
        "profile" => name,
        "input" => %{"request" => "first"},
        "cwd" => File.cwd!(),
        "backend" => "claude"
      })

    identity = Map.take(original, ["name", "revision"])
    assert first["profile"] == identity
    completed = wait_for(client, first["task_id"])
    assert completed["status"] == "completed"
    assert completed["result"] =~ "Original behavior"
    assert completed["result"] =~ Jason.encode!(%{"request" => "first"})

    replacement =
      call(client, "register_profile", %{
        "name" => name,
        "skill" => "Replacement behavior",
        "replace" => true
      })

    assert replacement["revision"] != original["revision"]
    assert call(client, "get_profile", %{"name" => name}) == replacement

    second =
      call(client, "continue_task", %{
        "task_id" => first["task_id"],
        "input" => %{"request" => "second"}
      })

    assert second["profile"] == identity
    assert second["conversation_id"] == first["conversation_id"]
    second_result = wait_for(client, second["task_id"])
    assert second_result["status"] == "completed"
    assert second_result["result"] =~ "Original behavior"
    refute second_result["result"] =~ "Replacement behavior"

    assert call(client, "delete_profile", %{"name" => name}) == %{
             "name" => name,
             "deleted" => true
           }

    assert error(client, "get_profile", %{"name" => name})["code"] == "profile_not_found"

    third = call(client, "continue_task", %{"task_id" => second["task_id"], "input" => nil})
    assert third["profile"] == identity
    third_result = wait_for(client, third["task_id"])
    assert third_result["status"] == "completed"
    assert third_result["result"] =~ "Original behavior"
    assert third_result["result"] =~ "null"
    assert wait_for(client, first["task_id"])["result"] == completed["result"]
  end

  test "profile validation and mutually exclusive input modes return MCP errors", %{
    client: client
  } do
    name = "mcp-errors-#{System.unique_integer([:positive])}"
    assert error(client, "register_profile", %{"name" => name})["code"] == "invalid_profile"

    call(client, "register_profile", %{"name" => name, "instructions" => "Bounded profile"})

    assert error(client, "register_profile", %{"name" => name, "skill" => "Duplicate"})["code"] ==
             "profile_exists"

    for args <- [
          %{"profile" => name},
          %{"profile" => name, "input" => nil, "task" => "mixed"},
          %{"profile" => name, "input" => nil, "output_schema" => %{"type" => "object"}},
          %{"task" => "ordinary", "input" => nil},
          %{"profile" => nil}
        ] do
      assert error(client, "spawn_task", Map.put(args, "cwd", File.cwd!()))["code"] ==
               "invalid_args"
    end

    for args <- [
          %{"name" => name, "skill" => "No defaults", "backend" => "claude"},
          %{"name" => name, "skill" => "No defaults", "access" => "workspace_write"},
          %{"name" => name, "replace" => "true", "skill" => "Invalid"}
        ] do
      assert {:ok, %{"isError" => true}} =
               Snodo.Client.call_tool(client, "register_profile", args)
    end

    profiled =
      call(client, "spawn_task", %{"profile" => name, "input" => nil, "cwd" => File.cwd!()})

    assert wait_for(client, profiled["task_id"])["status"] == "completed"

    assert error(client, "continue_task", %{
             "task_id" => profiled["task_id"],
             "message" => "wrong mode"
           })["code"] == "invalid_args"

    ordinary =
      call(client, "spawn_task", %{"profile" => nil, "task" => "plain", "cwd" => File.cwd!()})

    assert String.ends_with?(wait_for(client, ordinary["task_id"])["result"], "plain")

    assert error(client, "continue_task", %{"task_id" => ordinary["task_id"], "input" => nil})[
             "code"
           ] == "invalid_args"
  end

  test "configured fake provider results and continuation work through MCP", %{client: client} do
    spawned =
      call(client, "spawn_task", %{
        "task" => "first MCP turn",
        "cwd" => File.cwd!(),
        "backend" => "claude"
      })

    id = spawned["task_id"]
    assert is_binary(id)

    completed = wait_for(client, id)
    assert completed["status"] == "completed"
    assert completed["result"] =~ "Claude tools: Read, Glob, Grep."
    assert String.ends_with?(completed["result"], "first MCP turn")

    continued = call(client, "continue_task", %{"task_id" => id, "message" => "second MCP turn"})
    assert continued["task_id"] != id
    assert continued["conversation_id"] == spawned["conversation_id"]
    assert continued["parent_task_id"] == id

    second = wait_for(client, continued["task_id"])
    assert second["status"] == "completed"
    assert second["result"] =~ "Claude tools: Read, Glob, Grep."
    assert String.ends_with?(second["result"], "second MCP turn")

    listed = call(client, "list_tasks", %{"status" => "completed", "limit" => 100})
    assert Enum.any?(listed["tasks"], &(&1["task_id"] == id))
    assert Enum.any?(listed["tasks"], &(&1["task_id"] == continued["task_id"]))

    # Results remain repeatable after the conversation advances.
    assert wait_for(client, id)["result"] == completed["result"]
  end

  test "invalid tool arguments are rejected before dispatch", %{client: client} do
    for args <- [
          %{"task_ids" => [], "timeout_ms" => 0},
          %{"task_ids" => ["unknown"], "timeout_ms" => 55_001},
          %{"task_ids" => ["unknown"], "extra" => true}
        ] do
      assert {:ok, %{"isError" => true}} = Snodo.Client.call_tool(client, "wait_tasks", args)
    end

    assert {:ok, %{"isError" => true}} =
             Snodo.Client.call_tool(client, "spawn_task", %{
               "task" => "",
               "cwd" => File.cwd!()
             })
  end

  test "resources contain the exact canonical plugin guidance", %{client: client} do
    assert {:ok, resources} = Snodo.Client.list_resources(client)
    assert length(resources) == 6
    plugin_skill = Path.join(GenAgent.Delegation.PluginPackage.asset_root(), "skills/delegate")

    for resource <- resources do
      uri = resource["uri"]
      assert String.starts_with?(uri, "skill://gen-agent-delegate/delegate/")
      refute String.contains?(uri, "consult")
      relative = String.replace_prefix(uri, "skill://gen-agent-delegate/delegate/", "")

      assert {:ok, %{"contents" => [%{"uri" => ^uri, "text" => text}]}} =
               Snodo.Client.read_resource(client, uri)

      assert text == File.read!(Path.join(plugin_skill, relative))
      assert resource["mimeType"] == "text/markdown"
    end

    assert GenAgent.Delegation.MCP.runtime().instructions =~
             "skill://gen-agent-delegate/delegate/SKILL.md"
  end

  test "manager errors retain machine-readable codes and MCP isError", %{client: client} do
    assert {:ok, %{"isError" => true, "structuredContent" => %{"error" => error}}} =
             Snodo.Client.call_tool(client, "continue_task", %{
               "task_id" => "unknown-task",
               "message" => "follow up"
             })

    assert error["code"] == "not_found"
    assert is_binary(error["message"])

    # The raw MCP result retains additive error data across legacy negotiation too.
    {:ok, legacy} =
      Snodo.Client.direct(
        GenAgent.Delegation.MCP.runtime(protocols: [Snodo.Protocol.V2025_11_25])
      )

    on_exit(fn -> Snodo.Client.close(legacy) end)

    assert {:ok,
            %{"isError" => true, "structuredContent" => %{"error" => %{"code" => "not_found"}}}} =
             Snodo.Client.call_tool(legacy, "cancel_task", %{"task_id" => "unknown-task"})
  end

  test "public schema excludes test-only Echo and invalid diagnostics selectors", %{
    client: client
  } do
    assert {:ok, %{"isError" => true}} =
             Snodo.Client.call_tool(client, "spawn_task", %{
               "task" => "must never dispatch",
               "cwd" => File.cwd!(),
               "backend" => "echo"
             })

    assert {:ok, %{"isError" => true}} =
             Snodo.Client.call_tool(client, "check_environment", %{"backend" => "echo"})
  end

  test "provider usage remains JSON-safe in structured MCP results" do
    manager =
      start_supervised!(
        {GenAgent.Delegation,
         name: nil,
         default_backend: "claude",
         backends: %{"claude" => UsageBackend},
         state_dir: nil},
        restart: :temporary,
        id: :usage_manager
      )

    assert {:ok, task} =
             GenAgent.Delegation.spawn_task(
               %{"task" => "report usage", "cwd" => File.cwd!()},
               manager
             )

    assert {:ok, snapshot} =
             GenAgent.Delegation.wait_tasks(
               %{"task_ids" => [task["task_id"]], "timeout_ms" => 1_000},
               manager
             )

    assert [%{"usage" => %{"input_tokens" => 12, "output_tokens" => 3}}] = snapshot["tasks"]
    assert Snodo.JSONValue.valid?(snapshot)
    assert %Snodo.Result{kind: :structured, value: ^snapshot} = Snodo.Result.structured(snapshot)
  end

  defp call(client, name, args) do
    assert {:ok, response} = Snodo.Client.call_tool(client, name, args)
    refute response["isError"]
    assert is_map(response["structuredContent"])
    response["structuredContent"]
  end

  defp error(client, name, args) do
    assert {:ok, %{"isError" => true, "structuredContent" => %{"error" => error}}} =
             Snodo.Client.call_tool(client, name, args)

    assert is_binary(error["code"])
    assert is_binary(error["message"])
    error
  end

  defp wait_for(client, id) do
    result = call(client, "wait_tasks", %{"task_ids" => [id], "timeout_ms" => 1_000})
    assert result["errors"] == []
    assert [task] = result["tasks"]
    assert task["task_id"] == id
    task
  end
end
