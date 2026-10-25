# Registration and schema checks only. No model calls or workspace edits.
Code.require_file("profiles.exs", __DIR__)

alias GenAgent.Structured.{Contract, Error, ExampleProfiles, Profiles}

{:ok, registry} = Profiles.start_link()

try do
  for {name, definition} <- Enum.sort(ExampleProfiles.definitions()) do
    {:ok, profile} = Profiles.register(registry, name, definition)
    %{input: input, output: output} = Map.fetch!(ExampleProfiles.samples(), name)

    {:ok, _prompt} = Contract.render(profile.contract, input)
    :ok = Contract.validate_output(profile.contract, output)

    # Every profile has a meaningful required request/response shape. Missing
    # requests and responses must fail, not silently become unconstrained work.
    {:error, %Error{stage: :input}} = Contract.render(profile.contract, %{})
    {:error, %Error{stage: :output}} = Contract.validate_output(profile.contract, %{})

    # These distinctions matter for downstream consumers of the reports.
    invalid_output =
      case name do
        "researcher" ->
          put_in(output, ["findings", Access.at(0), "kind"], "unverified_fact")

        "elixir_developer" ->
          put_in(output, ["verification", Access.at(0), "status"], "probably_passed")

        "reviewer" ->
          put_in(output, ["findings", Access.at(0), "severity"], "unknown")
      end

    {:error, %Error{stage: :output}} =
      Contract.validate_output(profile.contract, invalid_output)

    IO.puts("#{name}: registered; sample I/O accepted; malformed I/O rejected")
  end
after
  GenServer.stop(registry)
end
