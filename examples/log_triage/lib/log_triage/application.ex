defmodule LogTriage.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {LogTriage.Sink, name: LogTriage.Sink, agent: :log_triage},
      {Task.Supervisor, name: LogTriage.TaskSupervisor},
      GenAgent.child_spec(LogTriage.Agent,
        name: :log_triage,
        backend: LogTriage.Backend,
        sink: LogTriage.Sink,
        task_supervisor: LogTriage.TaskSupervisor,
        max_pending_notifications: 100,
        max_pending_notification_bytes: 65_536
      ),
      {LogTriage.Handler, id: :log_triage, agent: :log_triage}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: LogTriage.Supervisor)
  end
end
