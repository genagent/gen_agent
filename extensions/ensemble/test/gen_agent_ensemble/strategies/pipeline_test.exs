defmodule GenAgentEnsemble.Strategies.PipelineTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgentEnsemble.Strategies.Pipeline
  alias GenAgentEnsemble.TestAgent

  setup do
    name = "pipe-#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(name) end)
    %{name: name}
  end

  defp safe_stop(name) do
    GenAgentEnsemble.stop(name)
  catch
    :exit, _ -> :ok
  end

  defp transform(tag) do
    fn prompt -> [Event.new(:result, %{text: "#{tag}(#{prompt})"})] end
  end

  defp start_pipeline(name, stage_scripts) do
    stages =
      stage_scripts
      |> Enum.with_index(1)
      |> Enum.map(fn {scripts, i} ->
        {"#{name}-s#{i}", TestAgent, [backend: Mock, scripts: scripts]}
      end)

    GenAgentEnsemble.start_link(
      name: name,
      strategy: Pipeline,
      opts: [stages: stages]
    )
  end

  test "each stage transforms the previous output", %{name: name} do
    # s1: wraps in outer(); s2: wraps in mid(); s3: wraps in inner().
    {:ok, _} =
      start_pipeline(name, [
        [transform("outer")],
        [transform("mid")],
        [transform("inner")]
      ])

    {:ok, resp} = GenAgentEnsemble.ask(name, "seed", timeout: 5_000)
    assert resp.text == "inner(mid(outer(seed)))"
  end

  test "backend usage events aggregate across stages and reset on the next ask", %{name: name} do
    script = fn usage ->
      [Event.new(:usage, usage), Event.new(:result, %{text: "done"})]
    end

    {:ok, _} =
      start_pipeline(name, [
        [script.(%{input_tokens: 10, output_tokens: 2}), transform("a")],
        [transform("b"), script.(%{input_tokens: 1})],
        [script.(%{input_tokens: 20, output_tokens: 3}), transform("c")]
      ])

    assert {:ok, first} = GenAgentEnsemble.ask(name, "first", timeout: 5_000)

    assert first.usage == %{
             input_tokens: 30,
             output_tokens: 5,
             by_agent: %{
               "#{name}-s1" => %{input_tokens: 10, output_tokens: 2},
               "#{name}-s3" => %{input_tokens: 20, output_tokens: 3}
             }
           }

    assert {:ok, second} = GenAgentEnsemble.ask(name, "second", timeout: 5_000)
    assert second.usage == %{input_tokens: 1, by_agent: %{"#{name}-s2" => %{input_tokens: 1}}}
  end

  test "queues a second tell behind the first", %{name: name} do
    {:ok, _} =
      start_pipeline(name, [
        [transform("a"), transform("a")],
        [transform("b"), transform("b")]
      ])

    {:ok, t1} = GenAgentEnsemble.tell(name, "one")
    {:ok, t2} = GenAgentEnsemble.tell(name, "two")

    assert %{text: "b(a(one))"} = await_completion(name, t1)
    assert %{text: "b(a(two))"} = await_completion(name, t2)
  end

  test "stage error fails the token with {stage, reason}", %{name: name} do
    {:ok, _} =
      start_pipeline(name, [
        [transform("s1")],
        [{:error, :midstage_boom}]
      ])

    assert {:error, {stage, :midstage_boom}} = GenAgentEnsemble.ask(name, "in", timeout: 5_000)
    assert stage == "#{name}-s2"

    # Pipeline should be idle again.
    Process.sleep(30)
    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.phase == :idle
  end

  test "stage death halts the session", %{name: name} do
    {:ok, pid} =
      start_pipeline(name, [[transform("s1")], [transform("s2")]])

    ref = Process.monitor(pid)
    Process.exit(GenAgent.whereis("#{name}/#{name}-s1"), :kill)

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  test "status reports pipeline shape", %{name: name} do
    {:ok, _} = start_pipeline(name, [[], []])
    {:ok, info} = GenAgentEnsemble.status(name)
    assert info.phase == :idle
    assert length(info.stages) == 2
    assert info.queued == 0
  end

  defp await_completion(name, token, retries \\ 100) do
    case GenAgentEnsemble.poll(name, token) do
      {:ok, :completed, response} ->
        response

      {:ok, :pending} when retries > 0 ->
        Process.sleep(20)
        await_completion(name, token, retries - 1)

      other ->
        flunk("expected completion, got: #{inspect(other)}")
    end
  end
end
