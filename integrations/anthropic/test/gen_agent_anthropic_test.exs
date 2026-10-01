defmodule GenAgentAnthropicTest do
  use ExUnit.Case, async: true

  test "module is defined" do
    assert Code.ensure_loaded?(GenAgentAnthropic)
  end
end
