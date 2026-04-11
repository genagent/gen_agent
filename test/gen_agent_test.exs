defmodule GenAgentTest do
  use ExUnit.Case, async: true

  test "module is defined" do
    assert Code.ensure_loaded?(GenAgent)
  end
end
