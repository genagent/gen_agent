defmodule GenAgentAppTest do
  use ExUnit.Case

  test "the application boots a named agent and routes through one API" do
    assert {:ok, ["echo"]} = GenAgentApp.agents()
    assert {:ok, %{text: "echo: hello"}} = GenAgentApp.ask("echo", "hello")
    assert {:error, {:unknown_agent, "missing"}} = GenAgentApp.ask("missing", "hello")
  end
end
