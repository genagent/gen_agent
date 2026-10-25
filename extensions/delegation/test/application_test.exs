defmodule GenAgent.Delegation.ApplicationTest do
  use ExUnit.Case, async: true

  alias GenAgent.Delegation.Application, as: DelegationApplication

  test "hosts without session identity get independent launch directories" do
    first = DelegationApplication.runtime_options(fn _ -> nil end)
    second = DelegationApplication.runtime_options(fn _ -> nil end)
    assert first[:default_backend] == "claude"
    assert first[:max_running] == 3

    assert Path.dirname(first[:state_dir]) ==
             Path.expand("~/.local/state/gen-agent-delegate/launches")

    assert Path.basename(first[:state_dir]) =~ ~r/\A[0-9a-f]{32}\z/
    refute first[:state_dir] == second[:state_dir]
  end

  test "host sessions are stable, isolated and never interpreted as paths" do
    directory = fn env -> DelegationApplication.runtime_options(&Map.get(env, &1))[:state_dir] end
    first = directory.(%{"CODEX_THREAD_ID" => "thread-a"})
    assert first == directory.(%{"CODEX_THREAD_ID" => "thread-a"})
    refute first == directory.(%{"CODEX_THREAD_ID" => "thread-b"})
    refute first == directory.(%{"GEN_AGENT_SESSION_ID" => "thread-a"})

    assert directory.(%{"GEN_AGENT_SESSION_ID" => "chosen", "CODEX_THREAD_ID" => "thread-a"}) ==
             directory.(%{"GEN_AGENT_SESSION_ID" => "chosen"})

    unsafe = directory.(%{"CODEX_THREAD_ID" => "../../outside\n"})
    assert Path.dirname(unsafe) == Path.expand("~/.local/state/gen-agent-delegate/sessions")
    assert Path.basename(unsafe) =~ ~r/\Acodex-[0-9a-f]{64}\z/
    blank = directory.(%{"GEN_AGENT_SESSION_ID" => "", "CODEX_THREAD_ID" => ""})
    assert Path.basename(blank) =~ ~r/\A[0-9a-f]{32}\z/
  end

  test "configured capacity 5 preserves backend and state overrides" do
    env = %{
      "GEN_AGENT_MAX_RUNNING" => "5",
      "GEN_AGENT_DEFAULT_BACKEND" => "codex",
      "GEN_AGENT_STATE_DIR" => "/tmp/delegation-test-state",
      "CODEX_THREAD_ID" => "ignored",
      "GEN_AGENT_SESSION_ID" => "also-ignored"
    }

    assert DelegationApplication.runtime_options(&Map.get(env, &1)) == [
             default_backend: "codex",
             state_dir: "/tmp/delegation-test-state",
             max_running: 5
           ]
  end

  test "accepts decimal capacity boundaries" do
    for value <- ["1", "32", "05"] do
      opts =
        DelegationApplication.runtime_options(fn
          "GEN_AGENT_MAX_RUNNING" -> value
          _ -> nil
        end)

      assert opts[:max_running] == String.to_integer(value)
    end
  end

  test "invalid capacities raise an actionable error" do
    for value <- [
          "",
          "0",
          "-1",
          "33",
          "999999999999999999999",
          "1.5",
          "five",
          "5x",
          " 5",
          "5 ",
          "+5",
          "5\n"
        ] do
      error =
        assert_raise ArgumentError, fn ->
          DelegationApplication.runtime_options(fn
            "GEN_AGENT_MAX_RUNNING" -> value
            _ -> nil
          end)
        end

      assert error.message =~ "GEN_AGENT_MAX_RUNNING must be a decimal integer from 1 to 32"
      assert error.message =~ "unset it to use the default of 3"
    end
  end
end
