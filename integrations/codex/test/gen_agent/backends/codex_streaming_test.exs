defmodule GenAgent.Backends.CodexStreamingTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Codex

  defmodule CaptureRunner do
    @behaviour CodexWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:error, :not_used}

    @impl true
    def stream_lines(binary, args, opts, _timeout) do
      parent = Application.fetch_env!(:gen_agent_codex, :capture_parent)
      send(parent, {:command, binary, args, opts})

      [
        ~s({"type":"thread.started","thread_id":"fixture-thread"}),
        ~s({"type":"item.completed","item":{"type":"agent_message","text":"ok"}}),
        ~s({"type":"turn.completed"})
      ]
    end
  end

  setup do
    previous_runner = Application.get_env(:codex_wrapper, :runner)
    Application.put_env(:codex_wrapper, :runner, CaptureRunner)
    Application.put_env(:gen_agent_codex, :capture_parent, self())

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:codex_wrapper, :runner, previous_runner)
      else
        Application.delete_env(:codex_wrapper, :runner)
      end

      Application.delete_env(:gen_agent_codex, :capture_parent)
    end)

    :ok
  end

  test "fresh and resumed streams keep the configured model, sandbox, policy, features and images" do
    {:ok, session} =
      Codex.start_session(
        binary: "fixture-codex",
        cwd: "/fixture",
        model: "fixture-model",
        sandbox: :read_only,
        approval_policy: :never,
        config_overrides: ["mcp_servers.fixture.enabled=false"],
        enabled_features: ["fixture_feature"],
        disabled_features: ["other_feature"],
        images: ["/fixture/image.png"]
      )

    {:ok, first, _} = Codex.prompt(session, "fresh")
    assert Enum.map(Enum.to_list(first), & &1.kind) == [:text, :result]
    assert_receive {:command, "fixture-codex", fresh_args, fresh_opts}
    assert fresh_args |> Enum.take(1) == ["exec"]
    assert {"-c", "approval_policy=\"never\""} in pairs(fresh_args)
    assert {"--sandbox", "read-only"} in pairs(fresh_args)
    assert {:cd, "/fixture"} in fresh_opts

    session = Codex.update_session(session, %{session_id: "fixture-thread"})
    {:ok, second, _} = Codex.prompt(session, "follow-up")
    assert Enum.map(Enum.to_list(second), & &1.kind) == [:text, :result]
    assert_receive {:command, "fixture-codex", resume_args, resume_opts}
    assert Enum.take(resume_args, 2) == ["exec", "resume"]
    assert {"-c", "approval_policy=\"never\""} in pairs(resume_args)
    assert {"-c", "sandbox_mode=\"read-only\""} in pairs(resume_args)
    assert {"-c", "mcp_servers.fixture.enabled=false"} in pairs(resume_args)
    assert {"--model", "fixture-model"} in pairs(resume_args)
    assert {"--enable", "fixture_feature"} in pairs(resume_args)
    assert {"--disable", "other_feature"} in pairs(resume_args)
    assert {"--image", "/fixture/image.png"} in pairs(resume_args)
    assert {:cd, "/fixture"} in resume_opts
    assert List.last(resume_args) == "follow-up"
  end

  test "options that cannot be preserved on resume fail at startup" do
    for option <- [:cd, :add_dirs, :search] do
      assert {:error, {:unsupported_resume_option, ^option}} =
               Codex.start_session([{option, "fixture"}])

      assert {:error, {:unsupported_resume_option, ^option}} =
               Codex.resume_session("fixture-thread", [{option, "fixture"}])
    end

    assert {:error, {:invalid_approval_policy, :on_failure}} =
             Codex.start_session(approval_policy: :on_failure)
  end

  test "unknown options report an unsupported option on start and resume" do
    for option <- [:system_prompt, :system, :max_tokens, :modle] do
      assert {:error, {:unsupported_option, ^option}} =
               Codex.start_session([{option, "fixture"}])

      assert {:error, {:unsupported_option, ^option}} =
               Codex.resume_session("fixture-thread", [{option, "fixture"}])
    end
  end

  test "an explicit approval policy wins over a conflicting config override on resume" do
    {:ok, session} =
      Codex.resume_session("fixture-thread",
        approval_policy: :on_request,
        config_overrides: [~s(approval_policy="never")]
      )

    {:ok, stream, _} = Codex.prompt(session, "follow-up")
    Enum.to_list(stream)
    assert_receive {:command, _binary, args, _opts}

    policies =
      args
      |> pairs()
      |> Enum.filter(fn {flag, value} ->
        flag == "-c" and String.starts_with?(value, "approval_policy=")
      end)

    assert List.last(policies) == {"-c", ~s(approval_policy="on-request")}
  end

  defp pairs(args), do: args |> Enum.chunk_every(2, 1, :discard) |> Enum.map(&List.to_tuple/1)
end
