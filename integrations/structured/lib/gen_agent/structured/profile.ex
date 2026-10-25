defmodule GenAgent.Structured.Profile do
  @moduledoc """
  An immutable named snapshot of behavior and a structured contract.

  `skill` is caller-supplied text, never a path to load. Instructions and skill
  text are combined into the effective contract instructions, and all ordinary
  `GenAgent.Structured.Contract` options remain available. At least one text
  field must be nonblank. Explicitly supplied fields must be UTF-8 strings.

  Names are nonblank UTF-8 strings of 1–128 bytes; they are preserved exactly,
  without normalization or atom conversion. A new random `revision` identifies
  each successful construction. Replacing a registered name creates a fresh
  snapshot; previously returned profiles keep their original contract and skill.
  """

  alias GenAgent.Structured.{Contract, Error}

  @keys [
    :instructions,
    :skill,
    :input_schema,
    :output_schema,
    :max_input_bytes,
    :max_output_bytes
  ]

  @enforce_keys [:name, :revision, :contract]
  defstruct [:name, :revision, :contract, :skill]

  @type t :: %__MODULE__{
          name: String.t(),
          revision: String.t(),
          contract: Contract.t(),
          skill: String.t() | nil
        }

  @doc "Build and validate a profile without registering it or loading files."
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(name, opts) do
    with :ok <- name_option(name),
         :ok <- options(opts),
         {:ok, instructions} <- text_option(opts, :instructions),
         {:ok, skill} <- text_option(opts, :skill),
         :ok <- meaningful_text(instructions, skill),
         {:ok, contract} <-
           opts
           |> Keyword.delete(:skill)
           |> Keyword.put(:instructions, combine(instructions, skill))
           |> Contract.new() do
      {:ok,
       %__MODULE__{
         name: name,
         revision: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
         contract: contract,
         skill: skill
       }}
    end
  end

  @doc false
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name),
    do: byte_size(name) in 1..128 and String.valid?(name) and String.trim(name) != ""

  def valid_name?(_), do: false

  defp name_option(name) do
    if valid_name?(name), do: :ok, else: error(:invalid_profile_name)
  end

  defp options(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        error(:expected_profile_keyword_options)

      Keyword.keys(opts) -- @keys != [] ->
        error({:unknown_profile_options, Keyword.keys(opts) -- @keys})

      length(opts) != length(Enum.uniq(Keyword.keys(opts))) ->
        error(:duplicate_profile_option)

      true ->
        :ok
    end
  end

  defp options(_), do: error(:expected_profile_keyword_options)

  defp text_option(opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        if String.valid?(value), do: {:ok, value}, else: error({:invalid_profile_text, key})

      {:ok, _} ->
        error({:invalid_profile_text, key})
    end
  end

  defp meaningful_text(instructions, skill) do
    if Enum.any?([instructions, skill], &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else: error(:missing_profile_behavior)
  end

  defp combine(nil, skill), do: skill
  defp combine(instructions, nil), do: instructions
  defp combine(instructions, skill), do: instructions <> "\n\nSkill:\n" <> skill

  defp error(reason), do: {:error, %Error{stage: :config, reason: reason}}
end
