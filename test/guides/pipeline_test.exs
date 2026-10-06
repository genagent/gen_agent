guide = Path.expand("../../guides/patterns/pipeline.md", __DIR__)

for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
    String.starts_with?(code, ["defmodule Pipeline.Stage do", "defmodule Pipeline do"]) do
  Code.compile_string(code, guide)
end

defmodule GenAgent.PipelineGuideTest do
  use ExUnit.Case, async: false

  defmodule Backend do
    @behaviour GenAgent.Backend

    @impl true
    def start_session(opts) do
      [_, role] = Regex.run(~r/^You are (.+)\. /, Keyword.fetch!(opts, :system))
      {:ok, {Process.whereis(GenAgent.PipelineGuideTest), role}}
    end

    @impl true
    def prompt({observer, role} = session, prompt) do
      send(observer, {:stage, role, prompt})

      if role == "fail" do
        {:error, :scripted_failure}
      else
        {:ok, [GenAgent.Event.new(:result, %{text: "#{role}(#{prompt})"})], session}
      end
    end

    @impl true
    def terminate_session(_session), do: :ok
  end

  setup do
    Process.register(self(), __MODULE__)
    :ok
  end

  defp run(roles) do
    configs =
      Enum.map(roles, fn role ->
        %{name: role, role: role, instruction: "Transform the input."}
      end)

    assert {:ok, %{stages: names}} = Pipeline.run("seed", configs, backend: Backend)

    on_exit(fn ->
      for name <- names, GenAgent.whereis(name), do: GenAgent.stop(name)
    end)

    names
  end

  defp await_halted(name, attempts \\ 100)
  defp await_halted(_name, 0), do: flunk("pipeline did not halt")

  defp await_halted(name, attempts) do
    status = GenAgent.status(name)

    if status.halted do
      status.agent_state
    else
      Process.sleep(10)
      await_halted(name, attempts - 1)
    end
  end

  test "the guide pipeline forwards each completed stage's output" do
    [first, second, third] = run(["first", "second", "third"])

    assert_receive {:stage, "first", "seed"}
    assert_receive {:stage, "second", "first(seed)"}
    assert_receive {:stage, "third", "second(first(seed))"}

    assert await_halted(first).output == "first(seed)"
    assert await_halted(second).input == "first(seed)"
    assert await_halted(third).output == "third(second(first(seed)))"
  end

  test "a failed stage notifies downstream stages without dispatching them" do
    [first, second, third] = run(["first", "fail", "third"])

    assert_receive {:stage, "first", "seed"}
    assert_receive {:stage, "fail", "first(seed)"}
    refute_receive {:stage, "third", _}, 100

    assert await_halted(first).output == "first(seed)"
    assert await_halted(second).error == :scripted_failure
    assert await_halted(third).error == {:upstream_failed, :scripted_failure}
  end
end
