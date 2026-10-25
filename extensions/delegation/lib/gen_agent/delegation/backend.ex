defmodule GenAgent.Delegation.Backend do
  @moduledoc """
  Delegation-owned backend proxy for resume and early session-ID bookkeeping.

  All provider options go unchanged to the underlying backend. A supplied saved
  session ID requires that backend's `resume_session/2`; it never falls back to a
  fresh conversation. Core validates a request-scoped checkpoint and invokes
  `checkpoint_session/2` in the core owner, which sends the manager
  `{:delegation_checkpoint, name, id}` before returning. Cancellation of the
  prompt worker cannot drop that notification between core acceptance and the
  worker receiving its reply. This is asynchronous bookkeeping, not an
  acknowledgement that persistence completed.
  Lazy streams remain lazy, and this proxy never initiates additional turns.
  """

  @behaviour GenAgent.Backend
  @keys [:backend, :backend_opts, :manager, :name, :provider_session_id]

  @enforce_keys [:backend, :session, :manager, :name]
  defstruct [:backend, :session, :manager, :name]

  @impl true
  def start_session(opts) do
    with :ok <- validate_options(opts),
         backend = Keyword.fetch!(opts, :backend),
         :ok <- validate_backend(backend),
         {:ok, session} <- initialize(backend, opts) do
      {:ok,
       %__MODULE__{
         backend: backend,
         session: session,
         manager: Keyword.fetch!(opts, :manager),
         name: Keyword.fetch!(opts, :name)
       }}
    end
  end

  @impl true
  def prompt(%__MODULE__{} = proxy, prompt) do
    proxy.backend.prompt(proxy.session, prompt)
    |> wrap_prompt(proxy)
  end

  @impl true
  def prompt(%__MODULE__{} = proxy, prompt, %{checkpoint: checkpoint} = context)
      when is_function(checkpoint, 1) do
    result =
      if function_exported?(proxy.backend, :prompt, 3) do
        proxy.backend.prompt(proxy.session, prompt, context)
      else
        proxy.backend.prompt(proxy.session, prompt)
      end

    wrap_prompt(result, proxy)
  end

  @impl true
  def update_session(%__MODULE__{} = proxy, data) do
    if function_exported?(proxy.backend, :update_session, 2),
      do: %{proxy | session: proxy.backend.update_session(proxy.session, data)},
      else: proxy
  end

  @impl true
  def checkpoint_session(%__MODULE__{} = proxy, id) do
    updated =
      if function_exported?(proxy.backend, :checkpoint_session, 2),
        do: %{proxy | session: proxy.backend.checkpoint_session(proxy.session, id)},
        else: proxy

    send(proxy.manager, {:delegation_checkpoint, proxy.name, id})
    updated
  end

  @impl true
  def terminate_session(%__MODULE__{} = proxy),
    do: proxy.backend.terminate_session(proxy.session)

  defp initialize(backend, opts) do
    backend_opts = Keyword.get(opts, :backend_opts, [])

    case Keyword.get(opts, :provider_session_id) do
      nil ->
        backend.start_session(backend_opts)

      id ->
        if function_exported?(backend, :resume_session, 2),
          do: backend.resume_session(id, backend_opts),
          else: {:error, :resume_unsupported}
    end
  end

  defp wrap_prompt({:ok, stream, next_session}, proxy),
    do: {:ok, stream, %{proxy | session: next_session}}

  defp wrap_prompt({:error, _} = error, _proxy), do: error

  defp validate_options(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_proxy_options}

      Keyword.keys(opts) -- @keys != [] or
          length(opts) != length(Enum.uniq(Keyword.keys(opts))) ->
        {:error, :invalid_proxy_options}

      not is_pid(Keyword.get(opts, :manager)) or not Keyword.has_key?(opts, :name) ->
        {:error, :invalid_proxy_owner}

      not Keyword.keyword?(Keyword.get(opts, :backend_opts, [])) ->
        {:error, :invalid_backend_options}

      not valid_session_id?(Keyword.get(opts, :provider_session_id)) ->
        {:error, :invalid_provider_session_id}

      true ->
        :ok
    end
  end

  defp validate_options(_), do: {:error, :invalid_proxy_options}

  defp validate_backend(backend) when is_atom(backend) and backend != __MODULE__ do
    required = [start_session: 1, prompt: 2, terminate_session: 1]

    if Code.ensure_loaded?(backend) and
         Enum.all?(required, fn {name, arity} -> function_exported?(backend, name, arity) end),
       do: :ok,
       else: {:error, :invalid_backend}
  end

  defp validate_backend(_), do: {:error, :invalid_backend}

  defp valid_session_id?(nil), do: true

  defp valid_session_id?(id) when is_binary(id) and byte_size(id) in 1..1024,
    do: String.valid?(id) and not String.match?(id, ~r/[\x00-\x1F\x7F]/)

  defp valid_session_id?(_), do: false
end
