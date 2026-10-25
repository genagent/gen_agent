defmodule GenAgent.Delegation.StoreTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias GenAgent.Delegation.Store

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "delegation-store-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp snapshot(id \\ "task_1", status \\ "completed") do
    %{
      "task_id" => id,
      "conversation_id" => "conversation_1",
      "status" => status,
      "started_at_ms" => 1,
      "finished_at_ms" => 2,
      "result" => "done"
    }
  end

  defp spec do
    %{
      "backend" => "codex",
      "cwd" => "/tmp",
      "access" => "read_only",
      "timeout_secs" => 30,
      "model" => "model",
      "effort" => "low",
      "task" => "PRIVATE ORIGINAL PROMPT",
      "selection" => %{"source" => "explicit"},
      "unexpected" => "never persisted"
    }
  end

  test "save/load is private, atomic replacement retains one prompt-free JSON record", %{dir: dir} do
    {:ok, store} = Store.open(dir)
    assert :ok = Store.save(store, Map.put(snapshot(), "task", "PRIVATE ORIGINAL PROMPT"), spec())
    path = Path.join(dir, "task_1.json")
    assert (File.stat!(dir).mode &&& 0o777) == 0o700
    assert (File.stat!(path).mode &&& 0o777) == 0o600
    assert (File.stat!(Path.join(dir, ".writer.lock")).mode &&& 0o777) == 0o600
    bytes = File.read!(path)
    refute bytes =~ "PRIVATE ORIGINAL PROMPT"
    refute bytes =~ "never persisted"

    assert {:ok, [%{"snapshot" => loaded, "spec" => saved_spec, "version" => 1}], []} =
             Store.load(store)

    assert loaded == snapshot()
    assert saved_spec == Map.drop(spec(), ["task", "unexpected"])
    assert :ok = Store.save(store, Map.put(snapshot(), "result", "replacement"), spec())
    assert {:ok, [%{"snapshot" => %{"result" => "replacement"}}], []} = Store.load(store)
    assert Enum.sort(File.ls!(dir)) == [".writer.lock", "task_1.json"]
    assert :ok = Store.close(store)
    assert :ok = Store.close(store)
    assert {:error, :lock_lost} = Store.save(store, snapshot(), spec())
  end

  test "reopen marks unfinished records interrupted without claiming provider settlement", %{
    dir: dir
  } do
    {:ok, first} = Store.open(dir)
    assert :ok = Store.save(first, snapshot("running", "running"), spec())
    assert :ok = Store.save(first, snapshot("cancelling", "cancelling"), spec())
    assert :ok = Store.save(first, snapshot("complete", "completed"), spec())
    assert :ok = Store.close(first)
    {:ok, second} = Store.open(dir)
    assert {:ok, records, []} = Store.load(second)

    for record <- records do
      if record["snapshot"]["task_id"] == "complete" do
        assert record["snapshot"]["status"] == "completed"
      else
        assert record["snapshot"]["status"] == "interrupted"
        assert record["snapshot"]["error"] == "server_restarted"
        assert record["snapshot"]["provider_settled"] == false
        assert record["snapshot"]["finished_at_ms"] > 2
      end
    end

    Store.close(second)
  end

  test "kernel ownership rejects concurrent writers and permits another directory", %{dir: dir} do
    {:ok, first} = Store.open(dir)
    assert {:error, :store_locked} = Store.open(dir)
    {:ok, independent} = Store.open(Path.join(dir, "other"))
    assert :ok = Store.save(independent, snapshot(), spec())

    assert {:error, :not_owner} =
             Task.async(fn -> Store.save(first, snapshot(), spec()) end) |> Task.await()

    assert {:error, :not_owner} = Task.async(fn -> Store.close(first) end) |> Task.await()
    Store.close(independent)
    Store.close(first)
    {:ok, reopened} = Store.open(dir)
    Store.close(reopened)
  end

  test "owner death releases the kernel lock without deleting or guessing a stale lock", %{
    dir: dir
  } do
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        {:ok, store} = Store.open(dir)
        Store.save(store, snapshot("killed", "running"), spec())
        send(parent, :owned)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :owned
    assert {:error, :store_locked} = Store.open(dir)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    {:ok, recovered} = reopen(dir, 100)
    assert {:ok, [%{"snapshot" => %{"status" => "interrupted"}}], []} = Store.load(recovered)
    assert File.regular?(Path.join(dir, ".writer.lock"))
    Store.close(recovered)
  end

  test "malformed oversized unknown-version and mismatched records return warnings", %{dir: dir} do
    {:ok, store} = Store.open(dir)
    Store.save(store, snapshot("good"), spec())
    File.write!(Path.join(dir, "invalid.json"), "{broken")
    File.write!(Path.join(dir, "future.json"), Jason.encode!(%{"version" => 99}))
    File.write!(Path.join(dir, "huge.json"), String.duplicate("x", 1_048_577))

    File.write!(
      Path.join(dir, "wrong.json"),
      Jason.encode!(%{"version" => 1, "snapshot" => snapshot("different"), "spec" => %{}})
    )

    File.write!(Path.join(dir, "bad name.json"), "{}")
    File.ln_s!(Path.join(dir, "good.json"), Path.join(dir, "symlink.json"))

    assert {:ok, [%{"snapshot" => %{"task_id" => "good"}}], warnings} = Store.load(store)

    assert Map.new(warnings, &{&1.file, &1.reason}) == %{
             "invalid.json" => :invalid_json,
             "future.json" => {:unsupported_version, 99},
             "huge.json" => :record_too_large,
             "wrong.json" => :invalid_record,
             "bad name.json" => :invalid_task_id,
             "symlink.json" => :not_a_regular_record
           }

    Store.close(store)
  end

  test "invalid IDs and oversized writes cannot replace a valid record", %{dir: dir} do
    {:ok, store} = Store.open(dir)
    Store.save(store, snapshot(), spec())
    original = File.read!(Path.join(dir, "task_1.json"))

    for id <- ["../outside", "a/b", "", String.duplicate("x", 129), nil] do
      assert {:error, :invalid_task_id} = Store.save(store, snapshot(id), spec())
    end

    assert {:error, :record_too_large} =
             Store.save(
               store,
               Map.put(snapshot(), "result", String.duplicate("x", 1_048_577)),
               spec()
             )

    assert File.read!(Path.join(dir, "task_1.json")) == original
    assert Enum.sort(File.ls!(dir)) == [".writer.lock", "task_1.json"]
    Store.close(store)
  end

  test "redacts diagnostic credentials but preserves intentional result values", %{dir: dir} do
    value = %{
      "result" =>
        "Bearer abc123 token=private password='with spaces' api_key=private2 sk-testabcdefghijklmnop",
      "structured_result" => %{
        "access_token" => "hidden",
        "nested" => [%{"password" => "hidden2"}]
      },
      "usage" => %{"input_tokens" => 100},
      "provider_session_id" => "session-public"
    }

    redacted = Store.redact(value)
    refute redacted["result"] =~ "abc123"
    refute redacted["result"] =~ "private"
    refute redacted["result"] =~ "with spaces"
    refute redacted["result"] =~ "sk-test"
    assert redacted["structured_result"]["access_token"] == "[REDACTED]"
    assert redacted["structured_result"]["nested"] == [%{"password" => "[REDACTED]"}]
    assert redacted["usage"] == %{"input_tokens" => 100}
    assert redacted["provider_session_id"] == "session-public"
    assert Store.redact(redacted) == redacted
    refute Store.redact(~s({"api_key":"json_secret"})) =~ "json_secret"

    {:ok, store} = Store.open(dir)

    public =
      snapshot()
      |> Map.merge(value)
      |> Map.put("error", "Bearer diagnostic_secret")
      |> Map.put("error_info", %{"password" => "private_diagnostic"})

    Store.save(store, public, spec())
    bytes = File.read!(Path.join(dir, "task_1.json"))
    refute bytes =~ "diagnostic_secret"
    refute bytes =~ "private_diagnostic"
    assert {:ok, [%{"snapshot" => loaded}], []} = Store.load(store)
    assert loaded["result"] == value["result"]
    assert loaded["structured_result"] == value["structured_result"]
    assert loaded["error"] == "Bearer [REDACTED]"
    assert loaded["error_info"] == %{"password" => "[REDACTED]"}
    Store.close(store)
  end

  test "dedicated directory and lock inode cannot be symlinks", %{dir: dir} do
    File.mkdir_p!(dir)
    target = Path.join(dir, "target")
    File.mkdir!(target)
    directory_link = Path.join(dir, "link")
    File.ln_s!(target, directory_link)
    assert {:error, :not_a_regular_directory} = Store.open(directory_link)
    File.write!(Path.join(dir, "other"), "keep")
    File.ln_s!(Path.join(dir, "other"), Path.join(target, ".writer.lock"))
    assert {:error, :invalid_lock_file} = Store.open(target)
    assert File.read!(Path.join(dir, "other")) == "keep"
    assert {:error, :absolute_directory_required} = Store.open("relative")
  end

  defp reopen(dir, remaining) when remaining > 0 do
    case Store.open(dir) do
      {:error, :store_locked} ->
        Process.sleep(10)
        reopen(dir, remaining - 1)

      result ->
        result
    end
  end

  defp reopen(_dir, 0), do: flunk("kernel lock did not release after owner death")

  test "profile catalog is private, separate from tasks, and retains empty deletions", %{dir: dir} do
    {:ok, store} = Store.open(dir)
    assert {:ok, nil} = Store.load_profiles(store)

    entries = [
      %{"name" => "reviewer", "revision" => "rev", "instructions" => "Review the supplied code"}
    ]

    assert :ok = Store.save_profiles(store, entries)
    assert {:ok, ^entries} = Store.load_profiles(store)
    assert {:ok, [], []} = Store.load(store)
    assert (File.stat!(Path.join(dir, ".profiles.json")).mode &&& 0o777) == 0o600
    assert :ok = Store.save_profiles(store, [])
    assert {:ok, []} = Store.load_profiles(store)
    Store.close(store)
  end

  test "malformed or oversized profile catalogs fail instead of silently resetting", %{dir: dir} do
    {:ok, store} = Store.open(dir)
    path = Path.join(dir, ".profiles.json")

    for bytes <- ["bad json", ~s({"version":2,"profiles":[]}), ~s({"version":1,"profiles":{}})] do
      File.write!(path, bytes)
      assert {:error, :invalid_profile_catalog} = Store.load_profiles(store)
    end

    File.write!(path, String.duplicate(" ", 8_388_609))
    assert {:error, :invalid_profile_catalog_file} = Store.load_profiles(store)
    Store.close(store)
  end
end
