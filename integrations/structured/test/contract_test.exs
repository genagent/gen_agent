defmodule GenAgent.Structured.ContractTest do
  use ExUnit.Case, async: true

  alias GenAgent.Structured.{Contract, Error}

  @line_schema %{
    "type" => "object",
    "properties" => %{
      "sku" => %{"type" => "string", "pattern" => "^[A-Z]{2}$"},
      "quantity" => %{"type" => "integer", "minimum" => 1}
    },
    "required" => ["sku", "quantity"],
    "additionalProperties" => false
  }

  @input_schema %{
    "type" => "object",
    "properties" => %{
      "lines" => %{"type" => "array", "items" => @line_schema, "minItems" => 1}
    },
    "required" => ["lines"],
    "additionalProperties" => false
  }

  test "schemas are optional; input stays JSON and fixed instructions remain intact" do
    assert {:ok, contract} = Contract.new(instructions: "Summarize the input")
    assert contract.input_validator == nil
    assert contract.output_validator == nil
    assert contract.max_input_bytes == 64_000
    assert contract.max_output_bytes == 64_000
    assert {:ok, prompt} = Contract.render(contract, %{"value" => "hello\nworld"})
    assert "Summarize the input\n\nInput (JSON):\n" <> json = prompt
    assert Jason.decode!(json) == %{"value" => "hello\nworld"}
    assert :ok = Contract.validate_output(contract, [true, nil, 42, "done"])
  end

  test "nested required properties, pattern, type and extra fields are enforced before rendering" do
    assert {:ok, contract} =
             Contract.new(instructions: "Summarize", input_schema: @input_schema)

    good = %{"lines" => [%{"sku" => "AB", "quantity" => 2}]}
    assert {:ok, prompt} = Contract.render(contract, good)
    assert String.ends_with?(prompt, Jason.encode!(good))

    for input <- [
          %{},
          %{"lines" => []},
          %{"lines" => [%{"sku" => "AB"}]},
          %{"lines" => [%{"sku" => "abc", "quantity" => 2}]},
          %{"lines" => [%{"sku" => "AB", "quantity" => "2"}]},
          %{"lines" => [%{"sku" => "AB", "quantity" => 0}]},
          %{"lines" => [%{"sku" => "AB", "quantity" => 2, "extra" => true}]}
        ] do
      assert {:error, %Error{stage: :input, reason: :schema_mismatch}} =
               Contract.render(contract, input)
    end
  end

  test "output uses full validator behavior for combinators and conditional branches" do
    schema = %{
      "type" => "object",
      "required" => ["kind", "value"],
      "properties" => %{
        "kind" => %{"enum" => ["count", "label"]},
        "value" => %{}
      },
      "additionalProperties" => false,
      "if" => %{"properties" => %{"kind" => %{"const" => "count"}}},
      "then" => %{"properties" => %{"value" => %{"type" => "integer", "minimum" => 0}}},
      "else" => %{"properties" => %{"value" => %{"type" => "string", "minLength" => 1}}}
    }

    assert {:ok, contract} = Contract.new(instructions: "Classify", output_schema: schema)
    assert :ok = Contract.validate_output(contract, %{"kind" => "count", "value" => 2})
    assert :ok = Contract.validate_output(contract, %{"kind" => "label", "value" => "ok"})

    for value <- [
          %{"kind" => "count", "value" => "2"},
          %{"kind" => "label", "value" => 2},
          %{"kind" => "label", "value" => ""}
        ] do
      assert {:error, %Error{stage: :output, reason: :schema_mismatch}} =
               Contract.validate_output(contract, value)
    end

    assert {:ok, union} =
             Contract.new(
               instructions: "Choose",
               output_schema: %{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]}
             )

    assert :ok = Contract.validate_output(union, "ok")
    assert :ok = Contract.validate_output(union, 7)
    assert {:error, %Error{stage: :output}} = Contract.validate_output(union, false)
  end

  test "malformed schemas fail during construction rather than provider execution" do
    for schema <- [
          %{"type" => "not-a-type"},
          %{"required" => "field"},
          %{"properties" => []},
          %{"type" => "string", "pattern" => "["},
          %{"minimum" => "zero"},
          %{"items" => %{"type" => "invalid"}}
        ] do
      assert {:error, %Error{stage: :schema}} =
               Contract.new(instructions: "Work", input_schema: schema)
    end

    for schema <- [true, false, "{}", %{type: "string"}, %URI{}] do
      assert {:error, %Error{stage: :schema}} =
               Contract.new(instructions: "Work", output_schema: schema)
    end
  end

  test "only draft-07 is accepted and nested references cannot invoke a resolver" do
    for schema <- [
          %{"$ref" => "https://example.invalid/schema.json"},
          %{"$ref" => "file:///tmp/schema.json"},
          %{"$ref" => "#/definitions/local"},
          %{"$id" => "http://json-schema.org/draft-07/schema#", "type" => "invalid"},
          %{"properties" => %{"value" => %{"$ref" => "https://example.invalid/nested"}}},
          %{"allOf" => [%{"$ref" => "#/local"}]},
          %{"$schema" => "https://json-schema.org/draft/2020-12/schema"},
          %{"$schema" => "http://json-schema.org/draft-04/schema#"},
          %{"$schema" => "http://json-schema.org/draft-07/schema#unexpected"},
          %{"properties" => %{"value" => %{"$schema" => "https://example.invalid/dialect"}}},
          %{"unevaluatedProperties" => false},
          %{"format" => "unrecognized-format"},
          %{"contentMediaType" => "application/json"}
        ] do
      assert {:error, %Error{stage: :schema}} =
               Contract.new(instructions: "Work", input_schema: schema)
    end

    assert {:ok, contract} =
             Contract.new(
               instructions: "Work",
               input_schema: %{
                 "$schema" => "https://json-schema.org/draft-07/schema#",
                 "type" => "object",
                 "properties" => %{"anything" => true, "forbidden" => false}
               }
             )

    assert :ok = ExJsonSchema.Validator.validate(contract.input_validator, %{"anything" => 5})

    assert {:error, %Error{stage: :input}} =
             Contract.render(contract, %{"forbidden" => 5})
  end

  test "literal JSON data in annotations and const is not mistaken for a schema reference" do
    literal = %{"$ref" => "https://example.invalid/just-data", "anything" => true}

    assert {:ok, contract} =
             Contract.new(instructions: "Work", output_schema: %{"const" => literal})

    assert :ok = Contract.validate_output(contract, literal)
    assert {:error, %Error{stage: :output}} = Contract.validate_output(contract, %{})
  end

  test "non-JSON values are rejected even without a schema, without coercion" do
    {:ok, contract} = Contract.new(instructions: "Work")

    for value <- [
          %{key: "value"},
          %{"nested" => :value},
          :value,
          %URI{},
          self(),
          {"tuple", "value"},
          <<255>>,
          %{<<255>> => "bad key"},
          Enum.reduce(1..65, nil, fn _, inner -> [inner] end)
        ] do
      assert {:error, %Error{stage: :input, reason: :invalid_json}} =
               Contract.render(contract, value)

      assert {:error, %Error{stage: :output, reason: :invalid_json}} =
               Contract.validate_output(contract, value)
    end
  end

  test "byte limits include JSON encoding overhead and reject rather than truncate" do
    {:ok, contract} =
      Contract.new(instructions: "Work", max_input_bytes: 4, max_output_bytes: 4)

    assert {:ok, _} = Contract.render(contract, "ab")
    assert :ok = Contract.validate_output(contract, "ab")

    assert {:error, %Error{stage: :input, reason: {:byte_limit_exceeded, 4}}} =
             Contract.render(contract, "abc")

    assert {:error, %Error{stage: :output, reason: {:byte_limit_exceeded, 4}}} =
             Contract.validate_output(contract, "abc")

    assert {:error, %Error{stage: :schema}} =
             Contract.new(
               instructions: "Work",
               output_schema: %{"description" => String.duplicate("x", 64_001)}
             )
  end

  test "invalid configuration and unknown keys are rejected" do
    for opts <- [
          %{},
          ["not keyword"],
          [],
          [instructions: ""],
          [instructions: "  "],
          [instructions: <<255>>],
          [instructions: "Work", typo: true],
          [instructions: "one", instructions: "two"],
          [instructions: "Work", max_input_bytes: 0],
          [instructions: "Work", max_output_bytes: 1_048_577],
          [instructions: "Work", max_output_bytes: 1.5]
        ] do
      assert {:error, %Error{stage: :config}} = Contract.new(opts)
    end
  end

  test "exception messages omit sensitive error and response content" do
    error = %Error{
      stage: :output,
      reason: {:bad_output, "SECRET"},
      request_id: "request",
      response: %GenAgent.Response{text: "SECRET"}
    }

    assert Exception.message(error) == "Structured request failed at output stage"
    refute Exception.message(error) =~ "SECRET"
  end
end
