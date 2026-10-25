defmodule GenAgent.Structured.Contract do
  @moduledoc """
  An immutable instruction and optional input/output JSON Schema contract.

  Schemas are string-keyed maps using draft-07. ExJsonSchema resolves the schema,
  validates it against its meta-schema, and validates request values. This local
  spike rejects schema references and identifiers (`$ref`/`$id`), other dialects,
  unknown keywords, unknown formats, and `contentEncoding`/`contentMediaType`.
  No user schema resolution performs network or filesystem access. Nested
  boolean schemas are accepted, but a top-level schema must be a map or `nil`.

  Schema JSON is limited to 64,000 bytes. JSON values and schemas allow at most
  64 nested containers. Input/output limits default to 64,000 encoded JSON bytes
  and may be configured up to 1 MiB. Values must already be JSON: string keys,
  valid UTF-8 strings, numbers, booleans, null (`nil`), lists, and ordinary maps.
  Structs and atom keys/values are rejected without coercion.

  `render/2` validates input before producing a prompt containing the fixed
  instructions and JSON input. These delimiters do not provide prompt-injection
  protection. Output validation remains necessary even when a provider accepts
  a native output schema.
  """

  alias GenAgent.Structured.Error

  @keys [:instructions, :input_schema, :output_schema, :max_input_bytes, :max_output_bytes]
  @max_bytes 1_048_576
  @default_bytes 64_000
  @max_depth 64
  @draft7 "http://json-schema.org/draft-07/schema#"
  @dialects [
    @draft7,
    "http://json-schema.org/draft-07/schema",
    "https://json-schema.org/draft-07/schema#",
    "https://json-schema.org/draft-07/schema"
  ]
  @keywords ~w($schema $comment title description default readOnly writeOnly examples type enum const multipleOf maximum exclusiveMaximum minimum exclusiveMinimum maxLength minLength pattern additionalItems items maxItems minItems uniqueItems contains maxProperties minProperties required additionalProperties definitions properties patternProperties dependencies propertyNames if then else allOf anyOf oneOf not format)
  @formats ~w(date date-time email idn-email idn-hostname hostname ipv4 ipv6 iri-reference iri json-pointer relative-json-pointer time uri-reference uri uri-template regex)
  @single_schemas ~w(additionalItems contains additionalProperties propertyNames if then else not)
  @schema_maps ~w(definitions properties patternProperties)
  @schema_lists ~w(allOf anyOf oneOf)

  @enforce_keys [:instructions]
  defstruct [
    :instructions,
    :input_schema,
    :output_schema,
    :input_validator,
    :output_validator,
    max_input_bytes: @default_bytes,
    max_output_bytes: @default_bytes
  ]

  @type t :: %__MODULE__{
          instructions: String.t(),
          input_schema: map() | nil,
          output_schema: map() | nil,
          input_validator: ExJsonSchema.Schema.Root.t() | nil,
          output_validator: ExJsonSchema.Schema.Root.t() | nil,
          max_input_bytes: pos_integer(),
          max_output_bytes: pos_integer()
        }

  @doc "Validate configuration and resolve both optional schemas without provider work."
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    with :ok <- config_keys(opts),
         :ok <- instructions(Keyword.get(opts, :instructions)),
         :ok <- limit(Keyword.get(opts, :max_input_bytes, @default_bytes)),
         :ok <- limit(Keyword.get(opts, :max_output_bytes, @default_bytes)),
         {:ok, input} <- resolve(Keyword.get(opts, :input_schema), :input_schema),
         {:ok, output} <- resolve(Keyword.get(opts, :output_schema), :output_schema) do
      {:ok,
       struct!(
         __MODULE__,
         Keyword.merge(opts, input_validator: input, output_validator: output)
       )}
    end
  end

  def new(_), do: error(:config, :expected_keyword_options)

  @doc "Validate input, then render fixed instructions followed by encoded JSON input."
  @spec render(t(), term()) :: {:ok, String.t()} | {:error, Error.t()}
  def render(%__MODULE__{} = contract, input) do
    with {:ok, json} <- encode(input, contract.max_input_bytes, :input),
         :ok <- validate(contract.input_validator, input, :input) do
      {:ok, contract.instructions <> "\n\nInput (JSON):\n" <> json}
    end
  end

  @doc "Validate a decoded output value without coercing it or truncating it."
  @spec validate_output(t(), term()) :: :ok | {:error, Error.t()}
  def validate_output(%__MODULE__{} = contract, value) do
    with {:ok, _json} <- encode(value, contract.max_output_bytes, :output),
         :ok <- validate(contract.output_validator, value, :output) do
      :ok
    end
  end

  defp config_keys(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        error(:config, :expected_keyword_options)

      Keyword.keys(opts) -- @keys != [] ->
        error(:config, :unknown_option)

      length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))) ->
        error(:config, :duplicate_option)

      true ->
        :ok
    end
  end

  defp instructions(value) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "" and byte_size(value) <= @max_bytes,
      do: :ok,
      else: error(:config, :invalid_instructions)
  end

  defp instructions(_), do: error(:config, :invalid_instructions)

  defp limit(value) when is_integer(value) and value > 0 and value <= @max_bytes, do: :ok
  defp limit(_), do: error(:config, :invalid_byte_limit)

  defp resolve(nil, _name), do: {:ok, nil}

  defp resolve(schema, name) when is_map(schema) and not is_struct(schema) do
    with {:ok, _} <- encode(schema, @default_bytes, :schema),
         :ok <- schema_options(schema) do
      {:ok, ExJsonSchema.Schema.resolve(Map.put_new(schema, "$schema", @draft7))}
    else
      {:error, %Error{} = failure} -> {:error, %{failure | reason: {name, failure.reason}}}
    end
  rescue
    _error -> error(:schema, {name, :invalid_schema})
  end

  defp resolve(_, name), do: error(:schema, {name, :expected_schema_map})

  defp schema_options(schema) when is_boolean(schema), do: :ok

  defp schema_options(schema) when is_map(schema) do
    cond do
      Map.has_key?(schema, "$ref") or Map.has_key?(schema, "$id") ->
        error(:schema, :references_and_identifiers_unsupported)

      Map.keys(schema) -- @keywords != [] ->
        error(:schema, :unsupported_keyword)

      Map.has_key?(schema, "$schema") and schema["$schema"] not in @dialects ->
        error(:schema, :unsupported_dialect)

      Map.has_key?(schema, "format") and schema["format"] not in @formats ->
        error(:schema, :unsupported_format)

      true ->
        schema
        |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
          case nested_schema_options(key, value) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
    end
  end

  # Shape errors are reported by ExJsonSchema's meta-schema validation.
  defp schema_options(_), do: :ok

  defp nested_schema_options(key, value) when key in @single_schemas,
    do: schema_options(value)

  defp nested_schema_options(key, values) when key in @schema_maps and is_map(values),
    do: each_schema(Map.values(values))

  defp nested_schema_options(key, values) when key in @schema_lists and is_list(values),
    do: each_schema(values)

  defp nested_schema_options("items", values) when is_list(values), do: each_schema(values)
  defp nested_schema_options("items", value), do: schema_options(value)

  defp nested_schema_options("dependencies", values) when is_map(values) do
    values |> Map.values() |> Enum.reject(&is_list/1) |> each_schema()
  end

  defp nested_schema_options(_, _), do: :ok

  defp each_schema(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case schema_options(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp encode(value, maximum, stage) do
    if json?(value, 0) do
      case Jason.encode(value) do
        {:ok, json} when byte_size(json) <= maximum -> {:ok, json}
        {:ok, _json} -> error(stage, {:byte_limit_exceeded, maximum})
        {:error, _} -> error(stage, :invalid_json)
      end
    else
      error(stage, :invalid_json)
    end
  rescue
    _error -> error(stage, :invalid_json)
  end

  defp json?(value, _depth) when is_nil(value) or is_boolean(value) or is_number(value), do: true
  defp json?(value, _depth) when is_binary(value), do: String.valid?(value)

  defp json?(value, depth) when is_list(value) and depth < @max_depth,
    do: Enum.all?(value, &json?(&1, depth + 1))

  defp json?(value, depth) when is_map(value) and not is_struct(value) and depth < @max_depth do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and String.valid?(key) and json?(nested, depth + 1)
    end)
  end

  defp json?(_, _), do: false

  defp validate(nil, _value, _stage), do: :ok

  defp validate(validator, value, stage) do
    case ExJsonSchema.Validator.validate(validator, value, error_formatter: false) do
      :ok -> :ok
      {:error, _errors} -> error(stage, :schema_mismatch)
    end
  rescue
    _error -> error(stage, :validation_failed)
  end

  defp error(stage, reason), do: {:error, %Error{stage: stage, reason: reason}}
end
