defmodule GenAgent.Structured do
  @moduledoc """
  Optional local spike: schema-checked requests and responses over GenAgent.

  `run/3` owns a fresh conversation for one request and closes it afterwards.
  `open/2`, `request/2` and `close/1` explicitly reuse a conversation. Contracts,
  provider settings and schemas are fixed for that conversation. Sessions monitor
  the opening caller and close when it exits, including normal exits. Ordinary
  `GenAgent.ask/3` remains unchanged and does not depend on this package.

  Pass a named profile and `profiles: registry` to resolve a registered template,
  or pass a fetched `Profile` snapshot directly. Lookup happens once per run/open;
  replacement or removal in the registry never changes an existing session.

  Inputs are JSON values, with optional schema validation before dispatch.
  Output is a decoded JSON value when an output schema is supplied, otherwise
  final text. Successful results and output-validation errors retain the original
  `GenAgent.Response`. No implicit retries, repairs, coercion or schema fallback.
  """
  alias GenAgent.Structured.{Contract, Error, Profile, Profiles, Provider, Session}

  def contract(opts), do: Contract.new(opts)

  @doc "Validate input, create a fresh owned conversation, perform one request and close."
  def run(target, input, opts \\ []) do
    with {:ok, contract, settings} <- prepare(target, opts),
         {:ok, _prompt} <- preflight(contract, input, settings.profile),
         {:ok, session} <- Session.start(contract, settings) do
      try do
        request(session, input)
      after
        close(session)
      end
    end
  end

  @doc "Open an owned session. Requires a provider; starts no prompt until request/2."
  def open(target, opts \\ []) do
    with {:ok, contract, settings} <- prepare(target, opts) do
      Session.start(contract, settings)
    end
  end

  @doc "Perform one request. Concurrent requests to the same session return :busy."
  def request(session, input) do
    GenServer.call(session, {:request, input}, :infinity)
  catch
    :exit, reason -> {:error, %Error{stage: :lifecycle, reason: {:session_call_exit, reason}}}
  end

  @doc "Close an owned session, replying to any pending request with a lifecycle error."
  def close(session) do
    GenServer.stop(session, :normal, 15_000)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, reason -> {:error, %Error{stage: :lifecycle, reason: {:close_failed, reason}}}
  end

  defp prepare(target, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts) and not duplicate_keys?(opts),
         {:ok, contract, profile, runtime_opts} <- resolve(target, opts),
         {:ok, settings} <- profile_settings(runtime_opts, profile) do
      {:ok, contract, settings}
    else
      false -> config_error(:invalid_options)
      failure -> failure
    end
  end

  defp prepare(_, _), do: config_error(:invalid_options)

  defp resolve(%Contract{} = contract, opts), do: {:ok, contract, nil, opts}

  defp resolve(%Profile{} = profile, opts),
    do: {:ok, profile.contract, %{name: profile.name, revision: profile.revision}, opts}

  defp resolve(name, opts) when is_binary(name) do
    case Keyword.pop(opts, :profiles) do
      {nil, _} ->
        config_error(:profile_registry_required)

      {registry, runtime_opts} ->
        with {:ok, profile} <- Profiles.fetch(registry, name),
             do: resolve(profile, runtime_opts)
    end
  end

  defp resolve(_, _), do: config_error(:invalid_contract)

  defp preflight(contract, input, profile) do
    case Contract.render(contract, input) do
      {:error, error} -> {:error, %{error | profile: profile}}
      rendered -> rendered
    end
  end

  defp profile_settings(opts, profile) do
    case settings(opts) do
      {:ok, settings} -> {:ok, Map.put(settings, :profile, profile)}
      {:error, error} -> {:error, %{error | profile: profile}}
    end
  end

  defp settings(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- [:provider, :backend_opts, :timeout_ms],
         false <- duplicate_keys?(opts),
         {:ok, provider} <- Provider.resolve(Keyword.get(opts, :provider)),
         backend_opts = Keyword.get(opts, :backend_opts, []),
         true <- is_list(backend_opts) and Keyword.keyword?(backend_opts),
         :ok <- new_conversation_options(backend_opts),
         timeout = Keyword.get(opts, :timeout_ms, 120_000),
         true <- is_integer(timeout) and timeout in 1..3_600_000 do
      {:ok, %{provider: provider, backend_opts: backend_opts, timeout_ms: timeout}}
    else
      {:error, reason} -> config_error(reason)
      _ -> config_error(:invalid_options)
    end
  end

  defp settings(_), do: config_error(:invalid_options)

  # Reuse is explicit through open/request; attaching a different existing CLI
  # conversation would invalidate the fresh-call and fixed-contract semantics.
  defp new_conversation_options(opts) do
    selectors = [:resume, :continue_session, :fork_session, :session_id, :thread_id]

    case Enum.find(selectors, &Keyword.has_key?(opts, &1)) do
      nil -> :ok
      key -> {:error, {:external_conversation_unsupported, key}}
    end
  end

  defp duplicate_keys?(opts),
    do: length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts)))

  defp config_error(reason), do: {:error, %Error{stage: :config, reason: reason}}
end
