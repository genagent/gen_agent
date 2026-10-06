defmodule ClaudeRepoReview.Supervisor do
  @moduledoc "Caller-owned task and agent supervision for repository reviewers."
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: ClaudeRepoReview.TaskSupervisor},
      {DynamicSupervisor, name: ClaudeRepoReview.AgentSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def start_reviewer(opts) do
    spec =
      GenAgent.child_spec(
        ClaudeRepoReview.Reviewer,
        [
          name: Keyword.fetch!(opts, :name),
          backend: GenAgent.Backends.Claude,
          task_supervisor: ClaudeRepoReview.TaskSupervisor,
          watchdog_ms: 600_000,
          max_events_per_turn: 10_000
        ] ++ Keyword.take(opts, [:cwd, :binary, :env, :resume])
      )

    DynamicSupervisor.start_child(ClaudeRepoReview.AgentSupervisor, spec)
  end

  def stop_reviewer(name) do
    GenAgent.stop(name, ClaudeRepoReview.AgentSupervisor)
  end
end
