defmodule GenAgent.Structured.Provider do
  @moduledoc """
  Maps the optional structured contract to a backend's native schema support.

  A provider prepares backend options and extracts a response value; the caller
  owns schema validation, output validation, and the private directory lifetime.
  Custom providers implement the same callbacks without changing GenAgent core.
  """

  alias GenAgent.Structured.Providers

  @callback backend() :: module()
  @callback prepare(map() | boolean() | nil, keyword(), String.t() | nil) ::
              {:ok, keyword()} | {:error, term()}
  @callback extract(GenAgent.Response.t(), map() | boolean() | nil) ::
              {:ok, term()} | {:error, term()}

  @doc "Resolves a built-in name or a module implementing this behaviour."
  @spec resolve(:claude | :codex | module()) :: {:ok, module()} | {:error, term()}
  def resolve(:claude), do: resolve(Providers.Claude)
  def resolve(:codex), do: resolve(Providers.Codex)

  def resolve(module) when is_atom(module) do
    callbacks = [backend: 0, prepare: 3, extract: 2]

    if Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end) do
      {:ok, module}
    else
      {:error, {:invalid_provider, module}}
    end
  end

  def resolve(value), do: {:error, {:invalid_provider, value}}

  @doc false
  def reject_native_schema_options(opts) do
    case Enum.find([:json_schema, :output_schema], &Keyword.has_key?(opts, &1)) do
      nil -> :ok
      option -> {:error, {:schema_option_conflict, option}}
    end
  end

  @doc false
  def encode_schema(schema) do
    case Jason.encode(schema) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:invalid_schema_json, Exception.message(reason)}}
    end
  end
end

defmodule GenAgent.Structured.Providers.Claude do
  @moduledoc """
  Uses Claude's native `:json_schema` option and terminal `structured_output`.

  Structured output can accompany empty prose. A native JSON null is a present
  value and is left to the caller's schema validator, rather than treated as a
  missing response. Without a schema, the normal final text is returned.
  """

  @behaviour GenAgent.Structured.Provider

  alias GenAgent.Response
  alias GenAgent.Structured.Provider

  @impl true
  def backend, do: GenAgent.Backends.Claude

  @impl true
  def prepare(nil, opts, _directory) do
    with :ok <- Provider.reject_native_schema_options(opts), do: {:ok, opts}
  end

  def prepare(schema, opts, _directory) do
    with :ok <- Provider.reject_native_schema_options(opts),
         {:ok, json} <- Provider.encode_schema(schema) do
      {:ok, Keyword.put(opts, :json_schema, json)}
    end
  end

  @impl true
  def extract(%Response{} = response, nil),
    do: {:ok, response.final_message || response.text}

  def extract(%Response{terminal: %{data: %{raw: raw}}}, _schema) when is_map(raw) do
    case Map.fetch(raw, "structured_output") do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :missing_structured_output}
    end
  end

  def extract(%Response{}, _schema), do: {:error, :missing_structured_output}
end

defmodule GenAgent.Structured.Providers.Codex do
  @moduledoc """
  Uses a private schema file and parses Codex's final message as JSON.

  Structured requests intentionally set `:response_text` to `:final_message`,
  replacing a caller's `:all_messages` selection so commentary cannot contaminate
  the JSON value. Extraction never falls back to assembled prose. The caller must
  supply an owned private directory and keep it alive for the entire request.
  """

  @behaviour GenAgent.Structured.Provider

  alias GenAgent.Response
  alias GenAgent.Structured.Provider

  @impl true
  def backend, do: GenAgent.Backends.Codex

  @impl true
  def prepare(nil, opts, _directory) do
    with :ok <- Provider.reject_native_schema_options(opts), do: {:ok, opts}
  end

  def prepare(schema, opts, directory) when is_binary(directory) do
    with :ok <- Provider.reject_native_schema_options(opts),
         {:ok, json} <- Provider.encode_schema(schema),
         {:ok, path} <- write_schema(directory, json) do
      {:ok,
       opts
       |> Keyword.put(:output_schema, path)
       |> Keyword.put(:response_text, :final_message)}
    end
  end

  def prepare(_schema, _opts, _directory), do: {:error, :missing_schema_directory}

  @impl true
  def extract(%Response{} = response, nil),
    do: {:ok, response.final_message || response.text}

  def extract(%Response{final_message: json}, _schema) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_json, Exception.message(reason)}}
    end
  end

  def extract(%Response{}, _schema), do: {:error, :missing_final_message}

  defp write_schema(directory, json) do
    path = Path.join(directory, "schema.json")

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(file, json) do
            :ok
          end

        closed = File.close(file)

        case {result, closed} do
          {:ok, :ok} ->
            {:ok, path}

          {{:error, reason}, _} ->
            File.rm(path)
            {:error, {:schema_file, reason}}

          {:ok, {:error, reason}} ->
            File.rm(path)
            {:error, {:schema_file, reason}}
        end

      {:error, reason} ->
        {:error, {:schema_file, reason}}
    end
  end
end
