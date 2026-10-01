defmodule GenAgentCodexTest do
  use ExUnit.Case, async: true

  test "module is defined" do
    assert Code.ensure_loaded?(GenAgentCodex)
  end
end
