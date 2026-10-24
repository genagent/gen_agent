defmodule GenAgentEnsemble.ForwardBoundary do
  @moduledoc false

  def pause(pid) do
    if observer = Process.delete(__MODULE__) do
      ref = make_ref()
      send(observer, {:forward_validated, self(), pid, ref})

      receive do
        {:release_forward, ^ref} -> :ok
      end
    end
  end
end
