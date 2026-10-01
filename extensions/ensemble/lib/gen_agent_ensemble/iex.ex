defmodule GenAgentEnsemble.IEx do
  @moduledoc """
  Ergonomic iex-flavoured frontend to `GenAgentEnsemble`.

  This module is meant to be aliased in `.iex.exs`:

      alias GenAgentEnsemble.IEx, as: E

  It delegates every core ensemble operation (`list/0`, `tell/2`,
  `ask/2`, etc.) to `GenAgentEnsemble` and adds a handful of
  helpers that make casual REPL work nicer: unwrapping the most
  useful field of a `%GenAgent.Response{}` (the `text`), blocking
  on a tell token, draining a pool to plain `{token, text}` pairs.

  For programmatic use from library code, call `GenAgentEnsemble`
  directly -- this module is a humans-at-the-prompt convenience.

  ## Example

      iex> E.list()
      ["echo", "solo"]

      iex> E.ask!("solo", "one-sentence summary of GenServer")
      "A GenServer is a generic server process..."

      iex> E.ask("solo", "give me markdown") |> E.puts()
      # Markdown content
      # ...
      :ok

      iex> {:ok, tok} = E.tell("qa-pool", "ask one")
      iex> E.await("qa-pool", tok).text
      "..."
  """

  alias GenAgent.Response

  # --- delegated core API ---

  @doc "See `GenAgentEnsemble.list/0`."
  defdelegate list(), to: GenAgentEnsemble

  @doc "See `GenAgentEnsemble.start_link/1`."
  defdelegate start_link(opts), to: GenAgentEnsemble

  @doc "See `GenAgentEnsemble.tell/2`."
  defdelegate tell(name, prompt), to: GenAgentEnsemble

  @doc "See `GenAgentEnsemble.tell/3`."
  defdelegate tell(name, prompt, opts), to: GenAgentEnsemble

  @doc "See `GenAgentEnsemble.ask/2`."
  defdelegate ask(name, prompt), to: GenAgentEnsemble

  @doc "See `GenAgentEnsemble.ask/3`."
  defdelegate ask(name, prompt, opts), to: GenAgentEnsemble

  @doc "See `GenAgentEnsemble.poll/2`."
  defdelegate poll(name, token), to: GenAgentEnsemble

  @doc "See `GenAgentEnsemble.inbox/1`."
  defdelegate inbox(name), to: GenAgentEnsemble

  @doc "See `GenAgentEnsemble.notify/2`."
  defdelegate notify(name, event), to: GenAgentEnsemble

  @doc "See `GenAgentEnsemble.status/1`."
  defdelegate status(name), to: GenAgentEnsemble

  @doc "See `GenAgentEnsemble.stop/1`."
  defdelegate stop(name), to: GenAgentEnsemble

  # --- helpers ---

  @doc """
  Blocking `ask` that returns the response text directly, or raises.

  The iex equivalent of "just give me the answer." Raises on error
  so mistakes don't silently become empty strings. Accepts the same
  `opts` as `ask/3` (e.g. `timeout: 60_000`, `agent: "alice"`).
  """
  @spec ask!(String.t(), String.t(), keyword()) :: String.t()
  def ask!(name, prompt, opts \\ []) do
    case GenAgentEnsemble.ask(name, prompt, opts) do
      {:ok, %Response{text: text}} ->
        text

      {:error, reason} ->
        raise "E.ask!(#{inspect(name)}) failed: #{inspect(reason)}"
    end
  end

  @doc """
  Extract the `text` field from a `%GenAgent.Response{}` or an
  `{:ok, response}` tuple. Raises on `{:error, reason}`.

  Useful in pipes: `E.ask("solo", q) |> E.text() |> String.length()`.
  """
  @spec text(Response.t() | {:ok, Response.t()} | {:error, term()}) :: String.t()
  def text(%Response{text: text}), do: text
  def text({:ok, %Response{text: text}}), do: text
  def text({:error, reason}), do: raise("E.text/1 on error: #{inspect(reason)}")

  @doc """
  Print the response text to stdout. Accepts a `%Response{}` or an
  `{:ok, response}` tuple. Handy for multi-line markdown output.
  """
  @spec puts(Response.t() | {:ok, Response.t()} | {:error, term()}) :: :ok
  def puts(arg) do
    arg |> text() |> IO.puts()
  end

  @doc """
  Poll `name`/`token` until the token completes or `timeout` elapses.

  Returns the `%Response{}` on success; raises on error or timeout.
  The iex counterpart to `GenAgentEnsemble.ask/3` for cases where
  the prompt was fired with `tell/2` and the caller now wants a
  blocking wait.
  """
  @spec await(String.t(), String.t(), timeout()) :: Response.t()
  def await(name, token, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(name, token, deadline)
  end

  defp do_await(name, token, deadline) do
    case GenAgentEnsemble.poll(name, token) do
      {:ok, :completed, %Response{} = response} ->
        response

      {:ok, :pending} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          do_await(name, token, deadline)
        else
          raise "E.await(#{inspect(name)}, #{inspect(token)}) timed out"
        end

      {:error, reason} ->
        raise "E.await(#{inspect(name)}, #{inspect(token)}) failed: #{inspect(reason)}"
    end
  end

  @doc """
  Drain `inbox/1` and unwrap each entry to `{token, text}` (or
  `{token, {:error, reason}}` for failed tokens).

  The quickest way to see what a Pool session has produced.
  """
  @spec drain(String.t()) :: [{String.t(), String.t() | {:error, term()}}]
  def drain(name) do
    {:ok, entries} = GenAgentEnsemble.inbox(name)

    for {token, result} <- entries do
      case result do
        {:ok, %Response{text: text}} -> {token, text}
        {:error, reason} -> {token, {:error, reason}}
      end
    end
  end
end
