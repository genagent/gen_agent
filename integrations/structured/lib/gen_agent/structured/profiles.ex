defmodule GenAgent.Structured.Profiles do
  @moduledoc """
  An explicitly owned, bounded registry of immutable profile snapshots.

  There is no default global instance. Start a registry with `start_link/1` or
  place `{GenAgent.Structured.Profiles, max_profiles: 100}` under your supervisor.
  When placing multiple instances under one supervisor, give their child specs
  distinct IDs with `Supervisor.child_spec/2`. An optional explicit `:name` uses
  ordinary GenServer naming; callers otherwise pass the returned PID.

  `register/3` creates only; `replace/3` changes an existing name explicitly.
  Both validate the entire profile before mutation. Fetches and deterministic
  lists return snapshots, so later replacement/deletion cannot change work that
  already holds a profile. The default capacity is 100 names, configurable from
  1 to 1,000. Data is local to this registry and lost when it exits.

  Skills are supplied text; this module never loads files or resolves paths.
  """

  use GenServer

  alias GenAgent.Structured.{Error, Profile}

  @type registry :: GenServer.server()

  @doc "Start an unnamed registry unless an explicit `:name` is provided."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    with :ok <- registry_options(opts) do
      {name, opts} = Keyword.pop(opts, :name)
      GenServer.start_link(__MODULE__, opts, if(is_nil(name), do: [], else: [name: name]))
    end
  rescue
    _error in [ArgumentError, UndefinedFunctionError, FunctionClauseError] ->
      error(:config, :invalid_registry_name)
  end

  @doc "Register a new name, returning an error if it is already registered."
  @spec register(registry(), String.t(), keyword()) :: {:ok, Profile.t()} | {:error, Error.t()}
  def register(registry, name, opts) do
    with {:ok, profile} <- Profile.new(name, opts) do
      call(registry, {:register, profile})
    end
  end

  @doc "Atomically replace an existing name with a newly validated revision."
  @spec replace(registry(), String.t(), keyword()) :: {:ok, Profile.t()} | {:error, Error.t()}
  def replace(registry, name, opts) do
    with {:ok, profile} <- Profile.new(name, opts) do
      call(registry, {:replace, profile})
    end
  end

  @doc "Fetch the current immutable snapshot of a name."
  @spec fetch(registry(), String.t()) :: {:ok, Profile.t()} | {:error, Error.t()}
  def fetch(registry, name), do: named_call(registry, name, :fetch)

  @doc "Return current profile snapshots sorted by name."
  @spec list(registry()) :: {:ok, [Profile.t()]} | {:error, Error.t()}
  def list(registry), do: call(registry, :list)

  @doc "Remove an existing name. Snapshots previously returned remain usable."
  @spec unregister(registry(), String.t()) :: :ok | {:error, Error.t()}
  def unregister(registry, name), do: named_call(registry, name, :unregister)

  @impl true
  def init(opts), do: {:ok, %{profiles: %{}, maximum: Keyword.get(opts, :max_profiles, 100)}}

  @impl true
  def handle_call({:register, profile}, _from, state) do
    cond do
      Map.has_key?(state.profiles, profile.name) ->
        {:reply, error(:config, {:profile_exists, profile.name}), state}

      map_size(state.profiles) >= state.maximum ->
        {:reply, error(:config, {:profile_capacity, state.maximum}), state}

      true ->
        {:reply, {:ok, profile}, put_in(state.profiles[profile.name], profile)}
    end
  end

  def handle_call({:replace, profile}, _from, state) do
    if Map.has_key?(state.profiles, profile.name) do
      {:reply, {:ok, profile}, put_in(state.profiles[profile.name], profile)}
    else
      {:reply, error(:config, {:profile_not_found, profile.name}), state}
    end
  end

  def handle_call({:fetch, name}, _from, state) do
    reply =
      case Map.fetch(state.profiles, name) do
        {:ok, profile} -> {:ok, profile}
        :error -> error(:config, {:profile_not_found, name})
      end

    {:reply, reply, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, {:ok, state.profiles |> Map.values() |> Enum.sort_by(& &1.name)}, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    if Map.has_key?(state.profiles, name) do
      {:reply, :ok, %{state | profiles: Map.delete(state.profiles, name)}}
    else
      {:reply, error(:config, {:profile_not_found, name}), state}
    end
  end

  defp named_call(registry, name, operation) do
    if Profile.valid_name?(name),
      do: call(registry, {operation, name}),
      else: error(:config, :invalid_profile_name)
  end

  defp call(registry, request) do
    if valid_registry_ref?(registry) do
      GenServer.call(registry, request, :infinity)
    else
      error(:config, :invalid_profile_registry)
    end
  rescue
    _error in [ArgumentError, UndefinedFunctionError, FunctionClauseError] ->
      error(:lifecycle, {:profile_registry_unavailable, :invalid_registry_reference})
  catch
    :exit, {reason, {GenServer, :call, _arguments}} ->
      error(:lifecycle, {:profile_registry_unavailable, reason})

    :exit, reason ->
      error(:lifecycle, {:profile_registry_unavailable, reason})
  end

  defp registry_options(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        error(:config, :expected_registry_keyword_options)

      Keyword.keys(opts) -- [:name, :max_profiles] != [] ->
        error(:config, {:unknown_registry_options, Keyword.keys(opts) -- [:name, :max_profiles]})

      length(opts) != length(Enum.uniq(Keyword.keys(opts))) ->
        error(:config, :duplicate_registry_option)

      not valid_maximum?(Keyword.get(opts, :max_profiles, 100)) ->
        error(:config, :invalid_profile_capacity)

      not valid_registry_name?(Keyword.get(opts, :name)) ->
        error(:config, :invalid_registry_name)

      true ->
        :ok
    end
  end

  defp registry_options(_), do: error(:config, :expected_registry_keyword_options)
  defp valid_registry_ref?(registry) when is_pid(registry) or is_atom(registry), do: true
  defp valid_registry_ref?({:global, _}), do: true
  defp valid_registry_ref?({:via, module, _}) when is_atom(module), do: true
  defp valid_registry_ref?({name, node}) when is_atom(name) and is_atom(node), do: true
  defp valid_registry_ref?(_), do: false
  defp valid_maximum?(value), do: is_integer(value) and value in 1..1000
  defp valid_registry_name?(nil), do: true
  defp valid_registry_name?(name) when is_atom(name), do: true
  defp valid_registry_name?({:global, _}), do: true
  defp valid_registry_name?({:via, module, _}) when is_atom(module), do: true
  defp valid_registry_name?(_), do: false
  defp error(stage, reason), do: {:error, %Error{stage: stage, reason: reason}}
end
