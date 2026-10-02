guide = Path.expand("../../guides/patterns/research.md", __DIR__)

[code] =
  for [_, code] <- Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(guide)),
      String.starts_with?(code, "defmodule Research.Agent do"),
      do: code

Code.compile_string(code, guide)

defmodule GenAgent.ResearchGuideTest do
  use ExUnit.Case, async: false

  defmodule Backend do
    @behaviour GenAgent.Backend
    def start_session(_opts), do: {:ok, Process.whereis(GenAgent.ResearchGuideTest)}

    def prompt(observer, prompt) do
      send(observer, {:prompt, prompt, self()})

      receive do
        {:text, text} -> {:ok, [GenAgent.Event.new(:result, %{text: text})], observer}
        :fail -> {:error, :scripted_failure}
      after
        5_000 -> {:error, :fixture_timeout}
      end
    end

    def terminate_session(_), do: :ok
  end

  defp await(fun, n \\ 1_000)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(1)
          await(fun, n - 1)
        )
  end

  defp respond(reply) do
    assert_receive {:prompt, _, task}, 1_000
    send(task, reply)
  end

  for terminal <- [:done, :failed], extra <- [:ask, :tell, :error] do
    test "#{terminal} preserves report and phase after resume and #{extra}" do
      Process.register(self(), __MODULE__)
      name = "research-#{System.unique_integer([:positive])}"

      assert {:ok, pid} =
               GenAgent.start_agent(Research.Agent, name: name, backend: Backend, topic: "topic")

      on_exit(fn -> if GenAgent.whereis(name), do: GenAgent.stop(name) end)
      GenAgent.tell(name, "list")

      if unquote(terminal) == :done do
        respond({:text, "question"})
        respond({:text, "answer"})
        respond({:text, "report"})
      else
        respond(:fail)
      end

      await(fn -> GenAgent.status(name).halted end)
      before = GenAgent.status(name).agent_state
      assert before.phase == unquote(terminal)

      if unquote(terminal) == :done do
        assert before.final_report == "report"
        assert before.answered == [{"question", "answer"}]
        assert before.turns == 3
      end

      GenAgent.resume(name)

      if unquote(extra) == :ask do
        caller = Task.async(fn -> GenAgent.ask(name, "extra") end)
        respond({:text, "ignored"})
        assert {:ok, _} = Task.await(caller)
      else
        GenAgent.tell(name, "extra")
        respond(if unquote(extra) == :error, do: :fail, else: {:text, "ignored"})
      end

      await(fn -> GenAgent.status(name).halted end)
      after_state = GenAgent.status(name).agent_state
      assert after_state.phase == before.phase
      assert after_state.final_report == before.final_report
      assert after_state.turns == before.turns
      assert Process.alive?(pid)
    end
  end
end
