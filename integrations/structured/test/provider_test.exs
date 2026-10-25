defmodule GenAgent.Structured.ProviderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias GenAgent.{Event, Response}
  alias GenAgent.Structured.Provider
  alias GenAgent.Structured.Providers.{Claude, Codex}

  @schema %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "structured-provider-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "resolves built-ins and custom callback modules without loading backends" do
    assert {:ok, Claude} = Provider.resolve(:claude)
    assert {:ok, Codex} = Provider.resolve(:codex)
    assert {:ok, Claude} = Provider.resolve(Claude)
    assert {:error, {:invalid_provider, Enum}} = Provider.resolve(Enum)
    assert {:error, {:invalid_provider, :missing_provider}} = Provider.resolve(:missing_provider)
    assert {:error, {:invalid_provider, "claude"}} = Provider.resolve("claude")
    assert Claude.backend() == GenAgent.Backends.Claude
    assert Codex.backend() == GenAgent.Backends.Codex
  end

  test "Claude encodes the native schema while retaining unrelated options" do
    assert {:ok, opts} = Claude.prepare(@schema, [model: "chosen", max_turns: 3], nil)
    assert Jason.decode!(opts[:json_schema]) == @schema
    assert opts[:model] == "chosen"
    assert opts[:max_turns] == 3
  end

  test "Codex writes a private exclusive schema file and selects final text", %{directory: dir} do
    assert {:ok, opts} =
             Codex.prepare(@schema, [model: "chosen", response_text: :all_messages], dir)

    assert opts[:output_schema] == Path.join(dir, "schema.json")
    assert opts[:output_schema] |> File.read!() |> Jason.decode!() == @schema
    assert (File.stat!(opts[:output_schema]).mode &&& 0o777) == 0o600
    assert opts[:response_text] == :final_message
    assert opts[:model] == "chosen"

    original = File.read!(opts[:output_schema])
    assert {:error, {:schema_file, :eexist}} = Codex.prepare(%{}, [], dir)
    assert File.read!(opts[:output_schema]) == original
  end

  test "native schema conflicts are rejected instead of silently overwritten", %{directory: dir} do
    for provider <- [Claude, Codex], key <- [:json_schema, :output_schema] do
      assert {:error, {:schema_option_conflict, ^key}} =
               provider.prepare(@schema, [{key, nil}], dir)

      assert {:error, {:schema_option_conflict, ^key}} =
               provider.prepare(nil, [{key, nil}], nil)
    end

    refute File.exists?(Path.join(dir, "schema.json"))
  end

  test "schema-free ordinary options pass through without files" do
    opts = [model: "chosen", response_text: :all_messages]

    assert {:ok, ^opts} = Claude.prepare(nil, opts, nil)
    assert {:ok, ^opts} = Codex.prepare(nil, opts, nil)
  end

  test "schema encoding and filesystem errors are returned", %{directory: dir} do
    assert {:error, {:invalid_schema_json, _}} = Claude.prepare(%{"bad" => self()}, [], nil)
    assert {:error, {:invalid_schema_json, _}} = Codex.prepare(%{"bad" => self()}, [], dir)
    assert {:error, :missing_schema_directory} = Codex.prepare(@schema, [], nil)

    assert {:error, {:schema_file, :enoent}} =
             Codex.prepare(@schema, [], Path.join(dir, "absent"))
  end

  test "Claude extracts native output even when prose is empty" do
    response = %Response{
      text: "",
      final_message: "",
      terminal: Event.new(:result, %{raw: %{"structured_output" => %{"ok" => true}}})
    }

    assert {:ok, %{"ok" => true}} = Claude.extract(response, @schema)
  end

  test "Claude preserves a present null and distinguishes missing native output" do
    response = %Response{terminal: Event.new(:result, %{raw: %{"structured_output" => nil}})}
    assert {:ok, nil} = Claude.extract(response, %{"type" => "null"})

    for terminal <- [nil, Event.new(:result, %{}), Event.new(:result, %{raw: %{}})] do
      response = %Response{text: ~s({"ok":true}), terminal: terminal}
      assert {:error, :missing_structured_output} = Claude.extract(response, @schema)
    end
  end

  test "Codex parses only final JSON and ignores commentary" do
    response = %Response{
      text: "Let me inspect the files.\n{\"ok\":true}",
      final_message: ~s({"ok":true})
    }

    assert {:ok, %{"ok" => true}} = Codex.extract(response, @schema)
    assert {:ok, nil} = Codex.extract(%Response{final_message: "null"}, %{"type" => "null"})
  end

  test "Codex rejects absent, invalid, fenced, or truncated final JSON" do
    assert {:error, :missing_final_message} =
             Codex.extract(%Response{text: ~s({"ok":true})}, @schema)

    for text <- ["", "done", "{\"ok\":", "```json\n{}\n```"] do
      assert {:error, {:invalid_json, _}} = Codex.extract(%Response{final_message: text}, @schema)
    end
  end

  test "schema-free extraction prefers final text and otherwise falls back to assembled text" do
    for provider <- [Claude, Codex] do
      assert {:ok, "final"} =
               provider.extract(%Response{text: "commentary", final_message: "final"}, nil)

      assert {:ok, "plain"} = provider.extract(%Response{text: "plain"}, nil)
      assert {:ok, ""} = provider.extract(%Response{text: "commentary", final_message: ""}, nil)
    end
  end
end
