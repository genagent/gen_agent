defmodule GenAgent.Delegation.Options do
  @moduledoc false
  @spawn_keys ~w(task cwd backend model effort access timeout_secs output_schema)
  @efforts ~w(none minimal low medium high xhigh max ultra)

  def spawn(args, defaults \\ %{})

  def spawn(args, defaults) when is_map(args) do
    requested = Map.take(args, ~w(backend model effort))

    args =
      Map.merge(
        %{
          "backend" => Map.get(defaults, :default_backend, "claude"),
          "access" => "read_only",
          "timeout_secs" => 600
        },
        args
      )

    cond do
      Map.keys(args) -- @spawn_keys != [] ->
        error("unsupported spawn options")

      not text?(args["task"]) ->
        error("task must be a nonempty string of at most 131072 bytes")

      not is_binary(args["cwd"]) ->
        error("cwd must be an existing absolute directory")

      Path.type(args["cwd"]) != :absolute or not File.dir?(args["cwd"]) ->
        error("cwd must be an existing absolute directory")

      args["backend"] not in Map.get(defaults, :backends, ~w(claude codex)) ->
        error("unsupported backend")

      args["access"] not in ~w(read_only workspace_write) ->
        error("unsupported access")

      not is_integer(args["timeout_secs"]) or args["timeout_secs"] not in 1..3600 ->
        error("timeout_secs must be 1..3600")

      Map.has_key?(args, "model") and not text?(args["model"]) ->
        error("model must be a nonempty string")

      Map.has_key?(args, "effort") and args["effort"] not in @efforts ->
        error("unsupported effort")

      args["backend"] == "claude" and args["effort"] in ~w(none minimal ultra) ->
        error("unsupported Claude effort")

      true ->
        with {:ok, _} <- contract(args["output_schema"]) do
          {:ok,
           Map.put(args, "selection", %{
             "requested" => requested,
             "selected" => Map.take(args, ~w(backend model effort)),
             "reported" => %{}
           })}
        end
    end
  end

  def spawn(_, _), do: error("arguments must be an object")

  def text?(value),
    do:
      is_binary(value) and byte_size(value) in 1..131_072 and String.trim(value) != "" and
        String.valid?(value)

  def contract(nil), do: {:ok, nil}

  def contract(%{"type" => "object"} = schema) do
    case GenAgent.Structured.Contract.new(
           instructions: "Complete the delegated task.",
           output_schema: schema
         ) do
      {:ok, contract} -> {:ok, contract}
      {:error, reason} -> error("unsupported output_schema: " <> inspect(reason.reason))
    end
  end

  def contract(_), do: error("output_schema must be an inline draft-07 object schema")

  def error(message), do: {:error, %{code: "invalid_args", message: message}}

  def task_prompt(%{"backend" => backend} = spec) when backend in ~w(claude codex) do
    capabilities =
      case backend do
        "claude" ->
          tools =
            if spec["access"] == "workspace_write",
              do: "Read, Glob, Grep, Edit, Write",
              else: "Read, Glob, Grep"

          "Claude tools: #{tools}. Bash/shell and MCP tools are disabled. " <>
            "This tool restriction is not an OS filesystem sandbox."

        "codex" ->
          "Codex can inspect local files using shell commands such as rg, sed, and git diff " <>
            "inside its #{spec["access"]} sandbox. User configuration is ignored, " <>
            "so installed MCP plugins are not inherited. Approval requests are disabled."
      end

    """
    Execution capabilities supplied by GenAgent Delegate:
    #{capabilities}
    Working directory: #{spec["cwd"]}
    Access mode: #{spec["access"]}. These describe available capabilities; they do not
    override narrower restrictions in the delegated request. Network availability
    is not guaranteed. Do not invent inspection or checks you could not perform.

    --- Delegated request ---
    #{spec["task"]}
    """
    |> String.trim_trailing()
  end

  def task_prompt(spec), do: spec["task"]

  def backend_opts(%{"backend" => "echo"}), do: []

  def backend_opts(%{"backend" => "codex"} = spec) do
    [
      working_dir: spec["cwd"],
      sandbox: access(spec["access"]),
      approval_policy: :never,
      ignore_user_config: true,
      skip_git_repo_check: true,
      response_text: :final_message
    ]
    |> maybe(:model, spec["model"])
    |> maybe(:config_overrides, effort_override(spec["effort"]))
  end

  def backend_opts(%{"backend" => "claude"} = spec) do
    tools =
      if spec["access"] == "workspace_write",
        do: ~w(Read Glob Grep Edit Write),
        else: ~w(Read Glob Grep)

    [
      working_dir: spec["cwd"],
      permission_mode: :dont_ask,
      tools: tools,
      allowed_tools: tools,
      strict_mcp_config: true,
      mcp_config: ~s({"mcpServers":{}}),
      setting_sources: "",
      disable_slash_commands: true
    ]
    |> maybe(:model, spec["model"])
    |> maybe(:effort, claude_effort(spec["effort"]))
  end

  defp access("read_only"), do: :read_only
  defp access("workspace_write"), do: :workspace_write
  defp effort_override(nil), do: nil
  defp effort_override(value), do: ["model_reasoning_effort=\"#{value}\""]
  defp claude_effort(nil), do: nil

  defp claude_effort(value),
    do: Enum.find([:low, :medium, :high, :xhigh, :max], &(Atom.to_string(&1) == value))

  defp maybe(opts, _key, nil), do: opts
  defp maybe(opts, key, value), do: Keyword.put(opts, key, value)
end
