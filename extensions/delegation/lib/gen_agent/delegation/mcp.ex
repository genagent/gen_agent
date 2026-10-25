defmodule GenAgent.Delegation.MCP do
  @moduledoc """
  Local stdio MCP facade for GenAgent task delegation.

  Run with `mix run --no-start -e 'GenAgent.Delegation.MCP.serve()'` after compiling.
  Each stdio process owns one task manager and its configured local state directory.
  """

  @instructions """
  GenAgent Delegate runs bounded local Claude or Codex tasks. Read
  skill://gen-agent-delegate/delegate/SKILL.md with resources/read, then only
  relevant linked references. Resources contain the same canonical skill text
  as the local plugin; clients decide when to load them into model context.
  The calling session manages task distribution, sequencing and acceptance.
  Workers stay within their assigned scope; configured server limits still apply.

  Use spawn_task, retain its ID, then wait_tasks to collect status and results.
  Wait returns when any selected task is terminal; remove settled IDs before
  waiting again. A wait timeout does not cancel work. continue_task resumes only
  the conversation's newest task if completed, with its original settings;
  failed follow-ups cannot roll back to an older task. cancel_task targets that request but does not
  certify provider subprocess cleanup. Inspect lifecycle and cleanup evidence.
  list_tasks returns a summary by default; use wait_tasks or full_result for
  output, usage, provider metadata and provider session IDs.
  After a restart, list retained tasks before starting replacement work.
  Excess work is refused rather than queued. check_environment reports the
  effective per-manager capacity (default 3; GEN_AGENT_MAX_RUNNING configures it).
  Inspect capacity error messages: full retained history is not freed by waiting.

  Profiles package behavior and optional input/output schemas, not execution
  permissions or provider defaults. list_profiles discovers the seeded researcher,
  elixir-developer and reviewer profiles; get_profile reads the full definition.
  register_profile creates a name or explicitly replaces it with replace: true;
  delete_profile removes it for future tasks. Spawn with profile and explicit input,
  or with a plain task. Continue a profile task with input, an ordinary task with
  message. Existing tasks keep their profile revision after replacement/deletion.
  Read the profiles resource for the exact contract and validation limits.

  Supply an absolute existing cwd and a self-contained authorized brief. Default
  access is read_only. Claude uses a restricted toolset, not an OS filesystem
  sandbox; its write mode has editing tools but no shell. Codex uses its CLI sandbox.
  Honor explicit backend/model/effort choices. Omitted backend uses server config
  (normally Claude); omitted model/effort use CLI behavior, not the calling chat.
  check_environment probes local executable/version/auth status without a model
  request or credential contents. An inconclusive probe does not prove logout.
  """

  @skill_root Path.expand("../../../priv/plugin/skills/delegate", __DIR__)
  @version Mix.Project.config()[:version]
  @resource_files [
    "SKILL.md",
    "references/parallel-tasks.md",
    "references/implementation-review.md",
    "references/follow-up.md",
    "references/model-effort.md",
    "references/profiles.md"
  ]
  for relative <- @resource_files do
    @external_resource Path.join(@skill_root, relative)
  end

  @resource_text Map.new(@resource_files, fn relative ->
                   {relative, File.read!(Path.join(@skill_root, relative))}
                 end)

  use Snodo.Server,
    name: "gen-agent-delegate",
    version: @version,
    instructions: @instructions,
    schema_validator: Snodo.Schema.Validator.Basic,
    protocols: [
      Snodo.Protocol.V2026_07_28,
      Snodo.Protocol.V2025_11_25,
      Snodo.Protocol.V2025_06_18
    ]

  tool "spawn_task",
    description:
      "Start bounded work from a plain task or a named profile plus explicit JSON input." do
    input_schema(%{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["cwd"],
      "properties" => %{
        "task" => %{
          "type" => "string",
          "minLength" => 1,
          "description" =>
            "Required when profile is absent or null; forbidden with a named profile"
        },
        "profile" => %{
          "type" => ["string", "null"],
          "minLength" => 1,
          "maxLength" => 128,
          "description" => "Registered profile name; omitted/null uses ordinary task mode"
        },
        "input" => %{
          "description" =>
            "Any JSON value, explicitly required for named profiles (null allowed if its schema permits); forbidden in ordinary task mode"
        },
        "cwd" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "Absolute existing directory"
        },
        "backend" => %{
          "type" => "string",
          "enum" => ["claude", "codex"],
          "description" => "Omitted uses GEN_AGENT_DEFAULT_BACKEND, normally claude"
        },
        "model" => %{"type" => "string", "minLength" => 1},
        "effort" => %{
          "type" => "string",
          "enum" => ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"],
          "description" => "Literal provider/model effort; omitted leaves the CLI default"
        },
        "output_schema" => %{
          "type" => "object",
          "description" =>
            "Ordinary tasks only: inline draft-07 object schema without references; inherited by follow-ups. Profile tasks use the profile schema."
        },
        "access" => %{
          "type" => "string",
          "enum" => ["read_only", "workspace_write"],
          "default" => "read_only"
        },
        "timeout_secs" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 3600,
          "default" => 600
        }
      }
    })

    @impl true
    def call(args, _context), do: GenAgent.Delegation.MCP.run(:spawn_task, args)
  end

  tool "wait_tasks",
    description:
      "Return when any selected task is terminal or the wait expires; remove settled IDs before waiting again. Snapshots include results without repeated output schemas. Use get_profile or list_tasks(full_result=true) for schemas." do
    input_schema(%{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["task_ids"],
      "properties" => %{
        "task_ids" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 32,
          "items" => %{"type" => "string", "minLength" => 1}
        },
        "timeout_ms" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => 55_000,
          "default" => 30_000
        }
      }
    })

    annotations(%{"readOnlyHint" => true})

    @impl true
    def call(args, _context), do: GenAgent.Delegation.MCP.run(:wait_tasks, args)
  end

  tool "list_tasks",
    description:
      "List retained tasks newest first as summaries (no output, usage, provider metadata or session IDs; short redacted error) unless full_result is true." do
    input_schema(%{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 10_000, "default" => 50},
        "since" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" => "Inclusive Unix timestamp in milliseconds"
        },
        "full_result" => %{"type" => "boolean", "default" => false},
        "status" => %{
          "type" => "string",
          "enum" => ["running", "cancelling", "completed", "failed", "cancelled", "interrupted"]
        }
      }
    })

    annotations(%{"readOnlyHint" => true})

    @impl true
    def call(args, _context), do: GenAgent.Delegation.MCP.run(:list_tasks, args)
  end

  tool "continue_task",
    description:
      "Continue only the conversation's newest task if completed: message for ordinary tasks, input for profile tasks; retains settings and profile revision. Failed follow-ups cannot roll back to older tasks." do
    input_schema(%{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["task_id"],
      "properties" => %{
        "task_id" => %{"type" => "string", "minLength" => 1},
        "message" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "Required for ordinary tasks; forbidden for profile tasks"
        },
        "input" => %{
          "description" =>
            "Explicit JSON input required for profile tasks; forbidden for ordinary tasks"
        }
      }
    })

    @impl true
    def call(args, _context), do: GenAgent.Delegation.MCP.run(:continue_task, args)
  end

  tool "cancel_task",
    description: "Cancel a task's current request without certifying provider process exit." do
    input_schema(%{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["task_id"],
      "properties" => %{"task_id" => %{"type" => "string", "minLength" => 1}}
    })

    @impl true
    def call(args, _context), do: GenAgent.Delegation.MCP.run(:cancel_task, args)
  end

  tool "check_environment",
    description:
      "Identify this server's version, runtime, state directory and limits; check Claude/Codex executable/version/auth status without a model call." do
    input_schema(%{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"backend" => %{"type" => "string", "enum" => ["claude", "codex"]}}
    })

    annotations(%{"readOnlyHint" => true})

    @impl true
    def call(args, _context), do: GenAgent.Delegation.MCP.run(:check_environment, args)
  end

  tool "register_profile",
    description:
      "Create a named behavior/schema profile, or replace an existing name only with replace: true. At least instructions or skill must be nonblank." do
    input_schema(%{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
        "instructions" => %{"type" => "string", "description" => "Behavior instructions as text"},
        "skill" => %{
          "type" => "string",
          "description" => "Caller-supplied skill text, never a path"
        },
        "input_schema" => %{
          "type" => ["object", "null"],
          "description" => "Optional inline draft-07 input schema without references"
        },
        "output_schema" => %{
          "type" => ["object", "null"],
          "description" => "Optional inline draft-07 schema with root type object; no references"
        },
        "replace" => %{"type" => "boolean", "default" => false}
      }
    })

    @impl true
    def call(args, _context), do: GenAgent.Delegation.MCP.run(:register_profile, args)
  end

  tool "get_profile",
    description: "Read one profile's full behavior, schemas and current revision." do
    input_schema(%{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}}
    })

    annotations(%{"readOnlyHint" => true})

    @impl true
    def call(args, _context), do: GenAgent.Delegation.MCP.run(:get_profile, args)
  end

  tool "list_profiles",
    description: "List compact profile metadata; use get_profile for full definitions." do
    input_schema(%{"type" => "object", "additionalProperties" => false, "properties" => %{}})
    annotations(%{"readOnlyHint" => true})

    @impl true
    def call(args, _context), do: GenAgent.Delegation.MCP.run(:list_profiles, args)
  end

  tool "delete_profile",
    description:
      "Delete a registered name for future work; existing task snapshots remain unchanged." do
    input_schema(%{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}}
    })

    @impl true
    def call(args, _context), do: GenAgent.Delegation.MCP.run(:delete_profile, args)
  end

  resource "delegate",
    uri: "skill://gen-agent-delegate/delegate/SKILL.md",
    description: "Read first: canonical delegation skill and links to focused references.",
    mime_type: "text/markdown" do
    @impl true
    def read(_params, _context), do: {:ok, GenAgent.Delegation.MCP.resource_text("SKILL.md")}
  end

  resource "parallel-tasks",
    uri: "skill://gen-agent-delegate/delegate/references/parallel-tasks.md",
    description: "Independent tasks, ownership, bounded concurrency and collecting outcomes.",
    mime_type: "text/markdown" do
    @impl true
    def read(_params, _context),
      do: {:ok, GenAgent.Delegation.MCP.resource_text("references/parallel-tasks.md")}
  end

  resource "implementation-review",
    uri: "skill://gen-agent-delegate/delegate/references/implementation-review.md",
    description:
      "Scoped edits, provider access limits, mechanical checks and independent review.",
    mime_type: "text/markdown" do
    @impl true
    def read(_params, _context),
      do: {:ok, GenAgent.Delegation.MCP.resource_text("references/implementation-review.md")}
  end

  resource "follow-up",
    uri: "skill://gen-agent-delegate/delegate/references/follow-up.md",
    description: "Conversation continuity, waiting, cancellation and restart evidence.",
    mime_type: "text/markdown" do
    @impl true
    def read(_params, _context),
      do: {:ok, GenAgent.Delegation.MCP.resource_text("references/follow-up.md")}
  end

  resource "model-effort",
    uri: "skill://gen-agent-delegate/delegate/references/model-effort.md",
    description: "User settings, CLI defaults, provider support and selection provenance.",
    mime_type: "text/markdown" do
    @impl true
    def read(_params, _context),
      do: {:ok, GenAgent.Delegation.MCP.resource_text("references/model-effort.md")}
  end

  resource "profiles",
    uri: "skill://gen-agent-delegate/delegate/references/profiles.md",
    description:
      "Named behavior/schema profiles, typed input, immutable task revisions and CRUD tools.",
    mime_type: "text/markdown" do
    @impl true
    def read(_params, _context),
      do: {:ok, GenAgent.Delegation.MCP.resource_text("references/profiles.md")}
  end

  @operations [
    :spawn_task,
    :wait_tasks,
    :list_tasks,
    :continue_task,
    :cancel_task,
    :register_profile,
    :get_profile,
    :list_profiles,
    :delete_profile
  ]

  @doc false
  def resource_text(relative), do: Map.fetch!(@resource_text, relative)

  @doc false
  def run(operation, args, manager \\ GenAgent.Delegation)

  def run(:check_environment, args, manager) do
    with {:ok, report} <- GenAgent.Delegation.Diagnostics.check(args) do
      reply({:ok, Map.put(report, "server", server_identity(manager))})
    else
      error -> reply(error)
    end
  catch
    :exit, _reason ->
      reply({:error, %{code: "server_unavailable", message: "Task manager unavailable"}})
  end

  def run(operation, args, manager) when operation in @operations do
    reply(apply(GenAgent.Delegation, operation, [args, manager]))
  catch
    :exit, _reason ->
      reply({:error, %{code: "server_unavailable", message: "Task manager unavailable"}})
  end

  @doc false
  def server_identity(manager) do
    GenAgent.Delegation.server_info(manager)
    |> Map.merge(%{
      "name" => "gen-agent-delegate",
      "version" => Application.spec(:gen_agent_delegation, :vsn) |> to_string(),
      "runtime_module_path" => :code.which(__MODULE__) |> to_string(),
      "launch_path" => System.get_env("GEN_AGENT_DELEGATE_LAUNCH_PATH")
    })
  end

  defp reply({:ok, data}), do: {:ok, Snodo.Result.structured(Snodo.JSONValue.encodable!(data))}

  defp reply({:error, error}) when is_map(error) do
    error = Snodo.JSONValue.encodable!(error)

    {:ok,
     Snodo.Result.raw(%{
       "isError" => true,
       "structuredContent" => %{"error" => error},
       "content" => [%{"type" => "text", "text" => Jason.encode!(%{"error" => error})}]
     })}
  end

  @doc false
  def start_manager do
    # An explicitly configured application child is the opted-in owner. Never
    # adopt a manager registered by another supervisor or start a second owner.
    case List.keyfind(
           Supervisor.which_children(GenAgent.Delegation.Supervisor),
           GenAgent.Delegation,
           0
         ) do
      {GenAgent.Delegation, pid, :worker, _} when is_pid(pid) ->
        {:ok, pid}

      nil ->
        opts =
          Application.get_env(:gen_agent_delegation, :manager_opts) ||
            GenAgent.Delegation.Application.runtime_options()

        Supervisor.start_child(GenAgent.Delegation.Supervisor, {GenAgent.Delegation, opts})

      _ ->
        {:error, :manager_unavailable}
    end
  end

  @doc "Start the configured manager and serve MCP until stdin closes."
  def serve do
    {:ok, _} = Application.ensure_all_started(:logger)
    stdout_to_protocol_only()
    {:ok, _} = Application.ensure_all_started(:gen_agent_delegation)
    {:ok, _manager} = start_manager()
    Snodo.Transport.Stdio.serve(runtime(), request_timeout: 60_000)
  end

  defp stdout_to_protocol_only do
    with {:ok, %{module: module, config: %{type: :standard_io}} = config} <-
           :logger.get_handler_config(:default) do
      :ok = :logger.remove_handler(:default)

      handler =
        config
        |> Map.take([:level, :filter_default, :filters, :formatter])
        |> Map.put(:config, %{type: :standard_error})

      :ok = :logger.add_handler(:default, module, handler)
    end

    :ok
  end
end
