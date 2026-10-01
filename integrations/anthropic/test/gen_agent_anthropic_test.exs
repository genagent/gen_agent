defmodule GenAgentAnthropicTest do
  use ExUnit.Case
  doctest GenAgentAnthropic

  test "greets the world" do
    assert GenAgentAnthropic.hello() == :world
  end
end
