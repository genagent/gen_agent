defmodule GenAgent.Delegation.Store do
  @moduledoc """
  Private, bounded local task records with one writer per state directory.

  The opening process owns the store and its kernel-lock keeper. On macOS/BSD
  the keeper uses `lockf -k`; on Linux it uses `flock`. Both retain the lock inode,
  and the operating system releases the lock when the keeper exits. No stale
  lock is guessed or removed. `sh` and one of these locking utilities must be
  installed. Use a dedicated directory on a same-host regular filesystem, not a
  network filesystem. This is not a multi-host coordination protocol.

  Records are atomically renamed after a synced write and limited to 1 MiB each.
  This does not guarantee directory-entry durability after sudden power loss.
  The caller serializes mutations and must treat a lost keeper as store failure.
  Common credentials in diagnostic fields are redacted as a best effort, not an
  exhaustive guarantee. Intentional results, structured results, and schemas are
  preserved exactly; changing them would invalidate the request/response contract.
  Original task/prompt/message fields are not persisted; model output may still
  contain sensitive task content and deserves the same care as other local logs.
  """

  @max_bytes 1_048_576
  @catalog_max_bytes 8_388_608
  @catalog_file ".profiles.json"
  @spec_keys ~w(backend cwd model effort access timeout_secs output_schema selection profile_snapshot)
  @request_keys ~w(task prompt message system_prompt)
  @diagnostic_keys ~w(error error_info persistence_error)
  @secret_keys ~w(apikey token accesstoken refreshtoken password passwd authorization secret clientsecret privatekey cookie setcookie)
  @redacted "[REDACTED]"
  @keeper_script "printf 'LOCKED\\n'; IFS= read -r release"

  @enforce_keys [:directory, :owner, :keeper]
  defstruct [:directory, :owner, :keeper]

  @type t :: %__MODULE__{directory: String.t(), owner: pid(), keeper: port()}

  @doc "Open a private state directory and exclusively own its kernel lock."
  @spec open(String.t()) :: {:ok, t()} | {:error, term()}
  def open(directory) when is_binary(directory) do
    if Path.type(directory) == :absolute do
      directory = Path.expand(directory)

      with :ok <- private_directory(directory),
           :ok <- private_lock_file(Path.join(directory, ".writer.lock")),
           {:ok, keeper} <- acquire_lock(directory) do
        {:ok, %__MODULE__{directory: directory, owner: self(), keeper: keeper}}
      end
    else
      {:error, :absolute_directory_required}
    end
  end

  def open(_), do: {:error, :absolute_directory_required}

  @doc "Load valid records, returning explicit warnings for skipped bad records."
  @spec load(t()) :: {:ok, [map()], [map()]} | {:error, term()}
  def load(%__MODULE__{} = store) do
    with :ok <- owned(store), {:ok, filenames} <- File.ls(store.directory) do
      {records, warnings} =
        filenames
        |> Enum.filter(&(String.ends_with?(&1, ".json") and &1 != @catalog_file))
        |> Enum.sort()
        |> Enum.reduce({[], []}, fn filename, {records, warnings} ->
          case read_record(store.directory, filename) do
            {:ok, record} -> {[recover(record) | records], warnings}
            {:error, reason} -> {records, [%{file: filename, reason: reason} | warnings]}
          end
        end)

      with :ok <- owned(store) do
        {:ok, Enum.reverse(records), Enum.reverse(warnings)}
      end
    end
  end

  @doc "Persist one public snapshot and a prompt-free allowlist of runtime options."
  @spec save(t(), map(), map()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = store, snapshot, spec) when is_map(snapshot) and is_map(spec) do
    with :ok <- owned(store),
         :ok <- valid_id(snapshot["task_id"]),
         :ok <- string_keys(snapshot),
         :ok <- string_keys(spec),
         {:ok, json} <-
           Jason.encode(%{
             "version" => 1,
             "snapshot" => snapshot |> Map.drop(@request_keys) |> redact_diagnostics(),
             "spec" => Map.take(spec, @spec_keys)
           }),
         :ok <- record_size(json) do
      atomic_write(store, snapshot["task_id"], json)
    else
      {:error, %_{} = reason} -> {:error, {:invalid_record_json, reason.__struct__}}
      error -> error
    end
  end

  def save(%__MODULE__{}, _, _), do: {:error, :invalid_record}

  @doc "Load the dedicated profile catalog. A missing catalog is explicitly absent."
  def load_profiles(%__MODULE__{} = store) do
    path = Path.join(store.directory, @catalog_file)

    with :ok <- owned(store) do
      case File.lstat(path) do
        {:error, :enoent} ->
          {:ok, nil}

        {:ok, %{type: :regular, size: size}} when size <= @catalog_max_bytes ->
          with {:ok, file} <- File.open(path, [:read, :binary]) do
            bytes = IO.binread(file, @catalog_max_bytes + 1)
            File.close(file)
            with :ok <- owned(store), do: decode_profiles(bytes)
          end

        {:ok, _} ->
          {:error, :invalid_profile_catalog_file}

        error ->
          error
      end
    end
  end

  @doc "Atomically replace the profile catalog under the existing state lock."
  def save_profiles(%__MODULE__{} = store, profiles) when is_list(profiles) do
    with :ok <- owned(store),
         true <- length(profiles) <= 100 || {:error, :profile_capacity},
         {:ok, json} <- Jason.encode(%{"version" => 1, "profiles" => profiles}),
         true <- byte_size(json) <= @catalog_max_bytes || {:error, :profile_catalog_too_large} do
      atomic_write(store, ".profiles", json)
    end
  end

  defp decode_profiles(bytes) when is_binary(bytes) and byte_size(bytes) <= @catalog_max_bytes do
    case Jason.decode(bytes) do
      {:ok, %{"version" => 1, "profiles" => profiles}}
      when is_list(profiles) and length(profiles) <= 100 ->
        {:ok, profiles}

      _ ->
        {:error, :invalid_profile_catalog}
    end
  end

  defp decode_profiles(_), do: {:error, :invalid_profile_catalog}

  @doc "Release the lock. Repeated closes by the owning process are harmless."
  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{owner: owner}) when owner != self(), do: {:error, :not_owner}

  def close(%__MODULE__{keeper: keeper}) do
    if Port.info(keeper) do
      try do
        Port.command(keeper, "\n")

        receive do
          {^keeper, {:exit_status, _}} -> :ok
        after
          1_000 -> close_port(keeper)
        end
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc "Best-effort recursive redaction of common credential keys and text forms."
  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if secret_key?(key), do: {key, @redacted}, else: {key, redact(nested)}
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_binary(value) do
    value
    |> then(&Regex.replace(~r/\bBearer\s+[^\s"'<>]+/i, &1, "Bearer " <> @redacted))
    |> then(
      &Regex.replace(
        ~r/\b(?:sk-(?:ant-)?[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{16,})\b/,
        &1,
        @redacted
      )
    )
    |> then(
      &Regex.replace(
        ~r/\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|passwd|client[_-]?secret|secret)["']?\s*[=:]\s*(?:\[REDACTED\]|"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;]+?)(?=\s|[,;}\]]|$)/i,
        &1,
        "\\1=" <> @redacted
      )
    )
  end

  def redact(value), do: value

  defp redact_diagnostics(snapshot) do
    Enum.reduce(@diagnostic_keys, snapshot, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.update!(acc, key, &redact/1), else: acc
    end)
  end

  defp secret_key?(key) when is_atom(key), do: key |> Atom.to_string() |> secret_key?()

  defp secret_key?(key) when is_binary(key),
    do: key |> String.downcase() |> String.replace(~r/[_-]/, "") |> then(&(&1 in @secret_keys))

  defp secret_key?(_), do: false

  defp owned(%__MODULE__{owner: owner}) when owner != self(), do: {:error, :not_owner}

  defp owned(%__MODULE__{keeper: keeper}) do
    case Port.info(keeper) do
      nil -> {:error, :lock_lost}
      _ -> :ok
    end
  end

  defp valid_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id), do: :ok, else: {:error, :invalid_task_id}
  end

  defp valid_id(_), do: {:error, :invalid_task_id}

  defp string_keys(map),
    do: if(Enum.all?(Map.keys(map), &is_binary/1), do: :ok, else: {:error, :invalid_record_keys})

  defp record_size(json),
    do: if(byte_size(json) <= @max_bytes, do: :ok, else: {:error, :record_too_large})

  defp private_directory(path) do
    with :ok <- File.mkdir_p(path),
         {:ok, %{type: :directory}} <- File.lstat(path),
         :ok <- File.chmod(path, 0o700) do
      :ok
    else
      {:ok, _} -> {:error, :not_a_regular_directory}
      error -> error
    end
  end

  defp private_lock_file(path) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result = File.chmod(path, 0o600)
        File.close(file)
        result

      {:error, :eexist} ->
        case File.lstat(path) do
          {:ok, %{type: :regular}} -> File.chmod(path, 0o600)
          {:ok, _} -> {:error, :invalid_lock_file}
          error -> error
        end

      error ->
        error
    end
  end

  defp acquire_lock(directory) do
    path = Path.join(directory, ".writer.lock")

    with {:ok, executable, args} <- lock_command(path) do
      keeper =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:line, 1_024},
          args: args
        ])

      wait_for_lock(keeper, System.monotonic_time(:millisecond) + 5_000)
    end
  rescue
    error -> {:error, {:lock_start_failed, error.__struct__}}
  end

  defp lock_command(path) do
    shell = System.find_executable("sh")
    lockf = System.find_executable("lockf")
    flock = System.find_executable("flock")

    cond do
      is_nil(shell) -> {:error, :lock_utility_unavailable}
      lockf -> {:ok, lockf, ["-k", "-s", "-t", "0", path, shell, "-c", @keeper_script]}
      flock -> {:ok, flock, ["-n", "-E", "75", path, shell, "-c", @keeper_script]}
      true -> {:error, :lock_utility_unavailable}
    end
  end

  defp wait_for_lock(keeper, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^keeper, {:data, {:eol, "LOCKED"}}} -> {:ok, keeper}
      {^keeper, {:data, _}} -> wait_for_lock(keeper, deadline)
      {^keeper, {:exit_status, 75}} -> {:error, :store_locked}
      {^keeper, {:exit_status, status}} -> {:error, {:lock_failed, status}}
    after
      remaining ->
        close_port(keeper)
        {:error, :lock_start_timeout}
    end
  end

  defp close_port(keeper) do
    Port.close(keeper)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp atomic_write(store, id, json) do
    target = Path.join(store.directory, id <> ".json")

    temp =
      Path.join(
        store.directory,
        ".write-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    result =
      with {:ok, file} <- File.open(temp, [:write, :binary, :exclusive]) do
        written =
          with :ok <- File.chmod(temp, 0o600),
               :ok <- IO.binwrite(file, json),
               :ok <- :file.sync(file),
               :ok <- owned(store) do
            :ok
          end

        closed = File.close(file)

        with :ok <- written, :ok <- closed, do: File.rename(temp, target)
      end

    if result != :ok, do: File.rm(temp)
    result
  end

  defp read_record(directory, filename) do
    id = String.replace_suffix(filename, ".json", "")
    path = Path.join(directory, filename)

    with :ok <- valid_id(id),
         {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= @max_bytes || {:error, :record_too_large},
         {:ok, file} <- File.open(path, [:read, :binary]) do
      bytes = IO.binread(file, @max_bytes + 1)
      File.close(file)
      decode_record(bytes, id)
    else
      {:ok, _} -> {:error, :not_a_regular_record}
      error -> error
    end
  end

  defp decode_record(bytes, id) when is_binary(bytes) do
    with :ok <- record_size(bytes),
         {:ok, record} <- Jason.decode(bytes),
         :ok <- record_shape(record, id) do
      {:ok, record}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      error -> error
    end
  end

  defp decode_record(:eof, _), do: {:error, :invalid_json}
  defp decode_record({:error, reason}, _), do: {:error, reason}

  defp record_shape(%{"version" => version}, _) when version != 1,
    do: {:error, {:unsupported_version, version}}

  defp record_shape(
         %{"version" => 1, "snapshot" => %{"task_id" => id} = snapshot, "spec" => spec},
         id
       )
       when is_map(spec) do
    if is_binary(snapshot["status"]), do: :ok, else: {:error, :invalid_record}
  end

  defp record_shape(_, _), do: {:error, :invalid_record}

  defp recover(%{"snapshot" => %{"status" => status} = snapshot} = record)
       when status in ["running", "cancelling"] do
    Map.put(
      record,
      "snapshot",
      Map.merge(snapshot, %{
        "status" => "interrupted",
        "error" => "server_restarted",
        "finished_at_ms" => System.system_time(:millisecond),
        "provider_settled" => false
      })
    )
  end

  defp recover(record), do: record
end
