defmodule GenAgent.Structured.ProfilesTest do
  use ExUnit.Case, async: true

  alias GenAgent.Structured.{Contract, Error, Profile, Profiles}

  defp registry(opts \\ []) do
    start_supervised!({Profiles, opts}, id: make_ref(), restart: :temporary)
  end

  test "profiles accept instructions, skill text, or both and compile optional schemas" do
    assert {:ok, instructions} = Profile.new("plain", instructions: "Review carefully")
    assert instructions.contract.instructions == "Review carefully"
    assert instructions.skill == nil

    assert {:ok, skill} = Profile.new("skill", skill: "Check failure paths")
    assert skill.contract.instructions == "Check failure paths"
    assert skill.skill == "Check failure paths"

    schema = %{
      "type" => "object",
      "required" => ["diff"],
      "properties" => %{"diff" => %{"type" => "string"}}
    }

    assert {:ok, combined} =
             Profile.new("review",
               instructions: "Review carefully",
               skill: "Check failure paths",
               input_schema: schema,
               output_schema: %{"type" => "string"},
               max_input_bytes: 500,
               max_output_bytes: 200
             )

    assert combined.contract.instructions == "Review carefully\n\nSkill:\nCheck failure paths"
    assert combined.contract.input_schema == schema
    assert {:error, %Error{stage: :input}} = Contract.render(combined.contract, %{})
    assert {:ok, _} = Contract.render(combined.contract, %{"diff" => "changed"})
    assert :ok = Contract.validate_output(combined.contract, "fine")
    assert {:error, %Error{stage: :output}} = Contract.validate_output(combined.contract, 3)
  end

  test "registry creates only and uses explicit replacement with immutable snapshots" do
    registry = registry()

    assert {:ok, original} =
             Profiles.register(registry, "review", instructions: "Original", skill: "Old skill")

    assert {:error, %Error{stage: :config, reason: {:profile_exists, "review"}}} =
             Profiles.register(registry, "review", instructions: "Accidental overwrite")

    assert {:ok, ^original} = Profiles.fetch(registry, "review")

    assert {:ok, replacement} =
             Profiles.replace(registry, "review", instructions: "Replacement", skill: "New skill")

    assert replacement.name == original.name
    refute replacement.revision == original.revision
    assert {:ok, ^replacement} = Profiles.fetch(registry, "review")
    assert :ok = Profiles.unregister(registry, "review")

    assert {:error, %Error{stage: :config, reason: {:profile_not_found, "review"}}} =
             Profiles.fetch(registry, "review")

    assert original.skill == "Old skill"
    assert original.contract.instructions == "Original\n\nSkill:\nOld skill"

    assert {:ok, "Original\n\nSkill:\nOld skill\n\nInput (JSON):\nnull"} =
             Contract.render(original.contract, nil)

    assert {:ok, recreated} = Profiles.register(registry, "review", instructions: "Original")
    refute recreated.revision in [original.revision, replacement.revision]
  end

  test "registries are independently scoped and lists are sorted snapshots" do
    first = registry()
    second = registry()
    {:ok, zed} = Profiles.register(first, "zed", skill: "Z")
    {:ok, alpha} = Profiles.register(first, "alpha", skill: "A")
    {:ok, other} = Profiles.register(second, "alpha", skill: "Other scope")

    assert {:ok, [^alpha, ^zed]} = Profiles.list(first)
    assert {:ok, [^other]} = Profiles.list(second)
    refute alpha.revision == other.revision
    assert {:ok, ^alpha} = Profiles.fetch(first, "alpha")
    assert {:ok, ^other} = Profiles.fetch(second, "alpha")
  end

  test "invalid schemas cannot mutate a registration or replace its valid snapshot" do
    registry = registry()
    {:ok, original} = Profiles.register(registry, "review", instructions: "Keep this")

    assert {:error, %Error{stage: :schema}} =
             Profiles.replace(registry, "review",
               instructions: "Broken",
               output_schema: %{"type" => "not-a-type"}
             )

    assert {:error, %Error{stage: :schema}} =
             Profiles.register(registry, "new",
               skill: "Broken",
               input_schema: %{"$ref" => "https://example.invalid/no-fetch"}
             )

    assert {:ok, ^original} = Profiles.fetch(registry, "review")
    assert {:ok, [^original]} = Profiles.list(registry)
  end

  test "capacity is enforced and replacement works at capacity" do
    registry = registry(max_profiles: 1)
    {:ok, original} = Profiles.register(registry, "one", skill: "First")

    assert {:error, %Error{stage: :config, reason: {:profile_capacity, 1}}} =
             Profiles.register(registry, "two", skill: "Second")

    assert {:ok, replaced} = Profiles.replace(registry, "one", skill: "Updated")
    refute replaced.revision == original.revision
    assert :ok = Profiles.unregister(registry, "one")
    assert {:ok, _} = Profiles.register(registry, "two", skill: "Now fits")

    assert {:error, %Error{stage: :config, reason: {:profile_not_found, "missing"}}} =
             Profiles.replace(registry, "missing", skill: "Cannot create")

    assert {:error, %Error{stage: :config, reason: {:profile_not_found, "missing"}}} =
             Profiles.unregister(registry, "missing")
  end

  test "concurrent creates have one winner and never silently overwrite" do
    registry = registry()

    outcomes =
      1..8
      |> Task.async_stream(fn n -> Profiles.register(registry, "same", skill: "Skill #{n}") end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [winner] = for({:ok, profile} <- outcomes, do: profile)

    assert Enum.count(outcomes, fn
             {:error, %Error{reason: {:profile_exists, "same"}}} -> true
             _ -> false
           end) == 7

    assert {:ok, ^winner} = Profiles.fetch(registry, "same")
    assert {:ok, [^winner]} = Profiles.list(registry)
  end

  test "invalid names and profile options are rejected without coercion" do
    for name <- [nil, :review, "", " \n ", <<255>>, String.duplicate("n", 129)] do
      assert {:error, %Error{stage: :config, reason: :invalid_profile_name}} =
               Profile.new(name, skill: "Useful")
    end

    assert {:ok, %Profile{name: "レビュー"}} = Profile.new("レビュー", skill: "Useful")
    assert {:ok, _} = Profile.new(String.duplicate("n", 128), skill: "Useful")

    for opts <- [
          %{},
          ["not keyword"],
          [],
          [instructions: "", skill: " \n "],
          [instructions: nil],
          [skill: nil],
          [skill: "Fine", instructions: :wrong],
          [skill: <<255>>],
          [skill: "Fine", typo: true],
          [skill: "First", skill: "Second"],
          [instructions: "Fine", skill: String.duplicate("x", 1_048_576)]
        ] do
      assert {:error, %Error{stage: :config}} = Profile.new("review", opts)
    end

    registry = registry()
    assert {:error, %Error{reason: :invalid_profile_name}} = Profiles.fetch(registry, :review)
    assert {:error, %Error{reason: :invalid_profile_name}} = Profiles.unregister(registry, "")
    assert {:ok, []} = Profiles.list(registry)
  end

  test "malformed registry references return typed configuration errors" do
    for reference <- [%{}, 123, "registry", [], {:remote, "node"}, {:via, 123, "name"}] do
      assert {:error, %Error{stage: :config, reason: :invalid_profile_registry}} =
               Profiles.fetch(reference, "review")

      assert {:error, %Error{stage: :config, reason: :invalid_profile_registry}} =
               Profiles.list(reference)
    end
  end

  test "invalid registry settings are typed and dead registries report lifecycle errors" do
    for via <- [
          {:via, __MODULE__.MissingModule, "SECRET NAME"},
          {:via, Registry, {__MODULE__.MissingRegistry, "SECRET NAME"}}
        ] do
      assert {:error, %Error{stage: :lifecycle} = error} = Profiles.list(via)
      refute inspect(error.reason) =~ "SECRET NAME"
      assert {:error, %Error{stage: :config}} = Profiles.start_link(name: via)
    end

    for opts <- [
          %{},
          ["not keyword"],
          [max_profiles: 0],
          [max_profiles: 1001],
          [max_profiles: 1.5],
          [max_profiles: nil],
          [max_profiles: 2, max_profiles: 3],
          [name: "string-is-not-a-GenServer-name"],
          [unknown: true]
        ] do
      assert {:error, %Error{stage: :config}} = Profiles.start_link(opts)
    end

    registry = registry(max_profiles: 1000)
    :ok = GenServer.stop(registry)

    assert {:error, %Error{stage: :lifecycle, reason: {:profile_registry_unavailable, :noproc}}} =
             Profiles.fetch(registry, "gone")

    assert {:error, %Error{stage: :lifecycle} = error} =
             Profiles.register(registry, "gone", skill: "SECRET SKILL")

    refute inspect(error.reason) =~ "SECRET SKILL"
  end
end
