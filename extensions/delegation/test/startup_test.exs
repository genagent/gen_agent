defmodule GenAgent.Delegation.StartupTest do
  use ExUnit.Case, async: false

  alias GenAgent.Delegation.{MCP, Store}

  setup do
    previous_opts = Application.fetch_env(:gen_agent_delegation, :manager_opts)

    previous_env =
      Map.new(~w(GEN_AGENT_STATE_DIR GEN_AGENT_MAX_RUNNING), &{&1, System.get_env(&1)})

    :ok = Application.stop(:gen_agent_delegation)
    Application.delete_env(:gen_agent_delegation, :manager_opts)

    directory =
      Path.join(System.tmp_dir!(), "delegation-startup-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Application.stop(:gen_agent_delegation)

      case previous_opts do
        {:ok, opts} -> Application.put_env(:gen_agent_delegation, :manager_opts, opts)
        :error -> Application.delete_env(:gen_agent_delegation, :manager_opts)
      end

      for {key, value} <- previous_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      {:ok, _} = Application.ensure_all_started(:gen_agent_delegation)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "adding the dependency does not read manager environment, create state or register a manager",
       ctx do
    System.put_env("GEN_AGENT_STATE_DIR", ctx.directory)
    System.put_env("GEN_AGENT_MAX_RUNNING", "invalid-until-MCP-starts")
    {:ok, _} = Application.ensure_all_started(:gen_agent_delegation)

    assert Supervisor.which_children(GenAgent.Delegation.Supervisor) == []
    assert Process.whereis(GenAgent.Delegation) == nil
    refute File.exists?(ctx.directory)
  end

  test "explicit library options start one configured manager and retain its owner lock", ctx do
    Application.put_env(:gen_agent_delegation, :manager_opts,
      default_backend: "echo",
      state_dir: ctx.directory,
      max_running: 2
    )

    {:ok, _} = Application.ensure_all_started(:gen_agent_delegation)
    manager = Process.whereis(GenAgent.Delegation)
    assert is_pid(manager)
    assert GenAgent.Delegation.server_info(manager)["max_running"] == 2
    assert {:error, :store_locked} = Store.open(ctx.directory)

    # MCP deliberately selects this application-owned configured child.
    assert {:ok, ^manager} = MCP.start_manager()

    assert [{GenAgent.Delegation, ^manager, :worker, _}] =
             Supervisor.which_children(GenAgent.Delegation.Supervisor)
  end

  test "MCP explicitly starts the environment-configured owner from an empty application", ctx do
    System.put_env("GEN_AGENT_STATE_DIR", ctx.directory)
    System.put_env("GEN_AGENT_MAX_RUNNING", "5")
    {:ok, _} = Application.ensure_all_started(:gen_agent_delegation)
    refute File.exists?(ctx.directory)

    assert {:ok, manager} = MCP.start_manager()
    identity = MCP.server_identity(manager)
    assert identity["state_directory"] == Path.expand(ctx.directory)
    assert identity["max_running"] == 5
    assert {:error, :store_locked} = Store.open(ctx.directory)
    assert {:ok, ^manager} = MCP.start_manager()
    assert length(Supervisor.which_children(GenAgent.Delegation.Supervisor)) == 1
  end

  test "MCP refuses to adopt a manager owned by another supervisor", ctx do
    System.put_env("GEN_AGENT_STATE_DIR", ctx.directory)
    System.delete_env("GEN_AGENT_MAX_RUNNING")
    {:ok, _} = Application.ensure_all_started(:gen_agent_delegation)
    manager = start_supervised!({GenAgent.Delegation, default_backend: "echo", state_dir: nil})

    assert {:error, {:already_started, ^manager}} = MCP.start_manager()
    assert Supervisor.which_children(GenAgent.Delegation.Supervisor) == []
    refute File.exists?(ctx.directory)
  end

  test "stdio serve starts its manager and exposes retained tasks without a provider request",
       ctx do
    executable = System.find_executable("elixir") || raise "elixir executable required"
    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", Path.expand(to_string(path))] end)
    code = "GenAgent.Delegation.MCP.serve()"

    {:ok, client} =
      Snodo.Client.connect(
        {:stdio, executable, paths ++ ["-e", code]},
        env: [{"GEN_AGENT_STATE_DIR", ctx.directory}, {"GEN_AGENT_MAX_RUNNING", "2"}],
        cd: System.tmp_dir!(),
        timeout: 10_000
      )

    try do
      assert {:ok, %{"structuredContent" => %{"tasks" => []}}} =
               Snodo.Client.call_tool(client, "list_tasks", %{})

      assert {:error, :store_locked} = Store.open(ctx.directory)
      assert {:ok, resources} = Snodo.Client.list_resources(client)
      assert length(resources) == 6
    after
      Snodo.Client.close(client)
      {:ok, store} = reopen(ctx.directory, 100)
      :ok = Store.close(store)
    end
  end

  defp reopen(directory, attempts) when attempts > 0 do
    case Store.open(directory) do
      {:error, :store_locked} ->
        Process.sleep(10)
        reopen(directory, attempts - 1)

      result ->
        result
    end
  end

  defp reopen(_directory, 0), do: flunk("stdio owner did not release its kernel lock")
end
