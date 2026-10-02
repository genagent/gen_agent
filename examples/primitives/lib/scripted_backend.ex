defmodule Primitives.ScriptedBackend do
  @moduledoc """
  A local backend that echoes words as lazy text events, then usage and a result.

  `:delay_ms` delays each turn (default 0). `:script` maps prompt strings to
  `:echo`, `{:slow, milliseconds}`, `{:error, reason}`, `{:fail, reason}`, `{:tools, [{name, input, output}]}`,
  or `{:gate, owner_pid}`. Errors emit a terminal event; failures return a
  synchronous error. Tools emit use/result pairs after the text deltas.
  A gate sends `{:scripted_turn, prompt, task_pid, token}` to its owner and
  waits for `{:release, token}`. This makes queue demonstrations deterministic.
  Token counts are illustrative word counts, not provider tokenization.
  """
  @behaviour GenAgent.Backend

  alias GenAgent.Event

  @impl true
  def start_session(opts) do
    {:ok, %{delay_ms: Keyword.get(opts, :delay_ms, 0), script: Keyword.get(opts, :script, %{})}}
  end

  @impl true
  def prompt(session, prompt) do
    behavior = Map.get(session.script, prompt, :echo)

    case behavior do
      {:fail, reason} -> {:error, reason}
      _ -> stream_prompt(session, prompt, behavior)
    end
  end

  defp stream_prompt(session, prompt, behavior) do
    stream =
      Stream.flat_map([prompt], fn text ->
        wait(behavior, text)
        Process.sleep(session.delay_ms)
        words = String.split(text)

        deltas =
          words
          |> Stream.with_index()
          |> Stream.map(fn {word, index} ->
            Event.new(:text, %{text: if(index == 0, do: word, else: " " <> word)})
          end)

        terminal =
          case behavior do
            {:error, reason} -> Event.new(:error, %{reason: reason})
            _ -> Event.new(:result, %{text: Enum.join(words, " ")})
          end

        Stream.concat([
          deltas,
          tool_events(behavior),
          [
            Event.new(:usage, %{input_tokens: length(words), output_tokens: length(words)}),
            terminal
          ]
        ])
      end)

    {:ok, stream, session}
  end

  @impl true
  def terminate_session(_session), do: :ok

  defp tool_events({:tools, tools}) do
    Stream.flat_map(tools, fn {name, input, output} ->
      [
        Event.new(:tool_use, %{name: name, input: input}),
        Event.new(:tool_result, %{name: name, output: output})
      ]
    end)
  end

  defp tool_events(_behavior), do: []

  defp wait({:slow, milliseconds}, _prompt), do: Process.sleep(milliseconds)

  defp wait({:gate, owner}, prompt) do
    token = make_ref()
    send(owner, {:scripted_turn, prompt, self(), token})

    receive do
      {:release, ^token} -> :ok
    after
      10_000 -> raise "scripted turn was never released: #{prompt}"
    end
  end

  defp wait(_behavior, _prompt), do: :ok
end
