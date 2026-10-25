defmodule GenAgent.Delegation.ProfileCatalogTest do
  use ExUnit.Case, async: true

  alias GenAgent.Delegation.ProfileCatalog, as: Catalog
  alias GenAgent.Structured.Contract

  defp args(name \\ "custom"), do: %{"name" => name, "skill" => "Answer the supplied input."}

  test "bundled definitions are ordinary strict object contracts with honest output variants" do
    assert {:ok, catalog} = Catalog.seed()

    assert Enum.map(Catalog.list(catalog), & &1["name"]) ==
             ~w(elixir-developer researcher reviewer)

    samples = %{
      "researcher" => {
        %{
          "question" => "What is known?",
          "context" => "No source was supplied.",
          "sources" => [],
          "constraints" => ["Do not retrieve sources."]
        },
        %{
          "summary" => "No evidence is available.",
          "findings" => [],
          "sources" => [],
          "unknowns" => ["No evidence was inspected."]
        }
      },
      "elixir-developer" => {
        %{
          "task" => "Fix the code.",
          "context" => "No checkout is available.",
          "acceptance_criteria" => ["Tests pass"],
          "constraints" => []
        },
        %{
          "status" => "blocked",
          "summary" => "Missing checkout",
          "changes" => [],
          "verification" => [
            %{"command" => "mix test", "status" => "not_run", "details" => "No checkout"}
          ],
          "remaining_work" => ["Provide a checkout"]
        }
      },
      "reviewer" => {
        %{"diff" => "", "context" => "No change provided", "focus" => []},
        %{
          "verdict" => "needs_information",
          "summary" => "Missing diff",
          "findings" => [],
          "limitations" => ["No code was inspected."]
        }
      }
    }

    for {name, {input, output}} <- samples do
      assert {:ok, entry} = Catalog.get(catalog, name)
      assert {:ok, _} = Catalog.render(entry, input)
      assert :ok = Contract.validate_output(entry.profile.contract, output)
      assert {:error, %{code: "invalid_input"}} = Catalog.render(entry, %{})
      assert_strict_objects(entry.snapshot["input_schema"])
      assert_strict_objects(entry.snapshot["output_schema"])
      assert byte_size(Jason.encode!(Catalog.definition(entry))) <= 64_000
      refute Map.has_key?(entry.snapshot, "access")
      refute Map.has_key?(entry.snapshot, "provider")
    end
  end

  test "create and replace are explicit and old entries retain their behavior and revision" do
    assert {:ok, first, catalog} = Catalog.register(%{}, args())
    assert {:error, %{code: "profile_exists"}} = Catalog.register(catalog, args())
    assert {:ok, ^first} = Catalog.get(catalog, "custom")
    replacement = %{"name" => "custom", "instructions" => "Changed", "replace" => true}
    assert {:ok, second, replaced} = Catalog.register(catalog, replacement)
    refute second.profile.revision == first.profile.revision
    assert {:ok, ^second} = Catalog.get(replaced, "custom")
    assert {:ok, "Answer the supplied input.\n\nInput (JSON):\nnull"} = Catalog.render(first, nil)
    assert {:ok, "Changed\n\nInput (JSON):\nnull"} = Catalog.render(second, nil)
    assert {:error, %{code: "profile_not_found"}} = Catalog.register(%{}, replacement)

    assert {:error, %{code: "invalid_profile"}} =
             Catalog.register(catalog, Map.put(args(), "replace", "yes"))

    assert {:error, %{code: "invalid_profile"}} = Catalog.build(Map.put(args(), "replace", true))
  end

  test "reviewer accepts inline or typed absolute diff files and rejects malformed sources" do
    {:ok, catalog} = Catalog.seed()
    {:ok, reviewer} = Catalog.get(catalog, "reviewer")
    base = %{"context" => "Review local evidence", "focus" => ["regressions"]}

    for diff <- [%{"file" => "/tmp/review.patch"}, "inline patch"] do
      assert {:ok, prompt} = Catalog.render(reviewer, Map.put(base, "diff", diff))
      assert prompt =~ "read that file"
      assert prompt =~ Jason.encode!(diff)
    end

    for diff <- [
          nil,
          [],
          1,
          %{},
          %{"file" => "relative.patch"},
          %{"file" => ""},
          %{"file" => "/tmp/diff", "command" => "git show"},
          %{"file" => "/" <> String.duplicate("x", 4096)}
        ] do
      assert {:error, %{code: "invalid_input"}} =
               Catalog.render(reviewer, Map.put(base, "diff", diff))
    end
  end

  test "restore revalidates schemas and preserves exact revision and original text once" do
    assert {:ok, entry} =
             Catalog.build(%{
               "name" => "original",
               "instructions" => "Instructions",
               "skill" => "Skill contents",
               "input_schema" => %{"type" => "integer"},
               "output_schema" => %{"type" => "object"}
             })

    snapshot = entry |> Catalog.definition() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, restored} = Catalog.restore(snapshot)
    assert restored.snapshot == entry.snapshot
    assert restored.profile.revision == entry.profile.revision
    assert restored.profile.contract.instructions == "Instructions\n\nSkill:\nSkill contents"
    assert restored.profile.contract.input_schema == %{"type" => "integer"}

    assert {:ok, "Instructions\n\nSkill:\nSkill contents\n\nInput (JSON):\n1"} =
             Catalog.render(restored, 1)

    assert {:error, %{code: "invalid_input"}} = Catalog.render(restored, "1")

    assert {:error, %{code: "invalid_profile"}} =
             Catalog.restore(
               Map.put(snapshot, "output_schema", %{"$ref" => "https://example.invalid/schema"})
             )

    for bad <- [nil, "", "revision\n", String.duplicate("x", 129)] do
      assert {:error, %{code: "invalid_profile"}} =
               Catalog.restore(Map.put(snapshot, "revision", bad))
    end
  end

  test "optional absent schemas and text restore while explicit nil behavior is rejected at registration" do
    assert {:ok, entry} =
             Catalog.build(%{
               "name" => "plain",
               "instructions" => "Plain",
               "input_schema" => nil,
               "output_schema" => nil
             })

    assert {:ok, restored} = Catalog.restore(Catalog.definition(entry))
    assert restored.snapshot == entry.snapshot
    assert restored.profile.contract.output_schema == nil
    assert {:ok, _} = Catalog.render(restored, [1, nil, "JSON"])

    assert Catalog.list(%{"plain" => entry}) == [
             %{
               "name" => "plain",
               "revision" => entry.profile.revision,
               "has_skill" => false,
               "has_input_schema" => false,
               "has_output_schema" => false
             }
           ]

    for field <- ["instructions", "skill"] do
      assert {:error, %{code: "invalid_profile"}} = Catalog.build(Map.put(args(), field, nil))
    end
  end

  test "catalog capacity is enforced without blocking replacement or mutation of captured entries" do
    catalog =
      Enum.reduce(1..100, %{}, fn n, catalog ->
        {:ok, _, next} = Catalog.register(catalog, args("p#{n}"))
        next
      end)

    assert {:error, %{code: "capacity"}} = Catalog.register(catalog, args("overflow"))
    assert {:ok, captured} = Catalog.get(catalog, "p1")
    assert {:ok, _, replaced} = Catalog.register(catalog, args("p1") |> Map.put("replace", true))
    assert {:ok, reduced} = Catalog.delete(replaced, "p1")
    assert {:ok, _, _} = Catalog.register(reduced, args("overflow"))
    assert {:ok, _} = Catalog.render(captured, %{})
    assert {:error, %{code: "profile_not_found"}} = Catalog.delete(reduced, "p1")
    assert {:error, %{code: "invalid_profile"}} = Catalog.get(catalog, :p1)
  end

  test "schemas use the existing inline subset and output root must be an object" do
    for schema <- [
          %{"type" => "string"},
          false,
          [],
          %{"$ref" => "local"},
          %{"type" => "object", "unknown" => true},
          %{"type" => "object", "properties" => %{"bad" => %{"$ref" => "local"}}}
        ] do
      assert {:error, %{code: "invalid_profile"}} =
               Catalog.build(Map.put(args(), "output_schema", schema))
    end

    assert {:ok, _} = Catalog.build(Map.put(args(), "input_schema", %{"type" => "null"}))

    assert {:error, %{code: "invalid_profile"}} =
             Catalog.build(Map.put(args(), "input_schema", %{"type" => "invalid"}))
  end

  test "boundaries reject unknown fields invalid names non-JSON content and oversized snapshots" do
    for bad <- [
          :bad,
          [],
          %{"name" => "only_name"},
          %{"name" => "bad", "skill" => " "},
          %{"name" => "", "skill" => "Useful"},
          %{"name" => String.duplicate("x", 129), "skill" => "Useful"},
          Map.put(args(), "provider", "codex"),
          Map.put(args(), "access", "workspace_write"),
          Map.put(args(), :unknown, true),
          Map.put(args(), "skill", self()),
          Map.put(args(), "skill", String.duplicate("s", 64_000))
        ] do
      assert {:error, %{code: "invalid_profile"}} = Catalog.build(bad)
    end

    assert {:ok, unicode} = Catalog.build(args("レビュー"))
    assert unicode.profile.name == "レビュー"
    assert {:error, %{code: "invalid_input"}} = Catalog.render(unicode, %{atom_key: "not JSON"})

    assert {:error, %{code: "invalid_profile"}} =
             Catalog.restore(Map.put(unicode.snapshot, "task", "Not a profile field"))
  end

  defp assert_strict_objects(%{"type" => "object", "properties" => properties} = schema) do
    assert schema["additionalProperties"] == false
    assert Enum.sort(schema["required"]) == Enum.sort(Map.keys(properties))
    Enum.each(Map.values(properties), &assert_strict_objects/1)
  end

  defp assert_strict_objects(%{"type" => "array", "items" => items}),
    do: assert_strict_objects(items)

  defp assert_strict_objects(%{"anyOf" => choices}),
    do: Enum.each(choices, &assert_strict_objects/1)

  defp assert_strict_objects(_), do: :ok
end
