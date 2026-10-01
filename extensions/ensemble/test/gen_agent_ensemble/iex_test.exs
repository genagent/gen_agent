defmodule GenAgentEnsemble.IExTest do
  use ExUnit.Case, async: false

  alias GenAgent.Backends.Mock
  alias GenAgent.Event
  alias GenAgent.Response
  alias GenAgentEnsemble.IEx, as: E
  alias GenAgentEnsemble.Strategies.Solo
  alias GenAgentEnsemble.TestAgent

  setup do
    name = "iex-#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(name) end)
    %{name: name}
  end

  defp safe_stop(name) do
    GenAgentEnsemble.stop(name)
  catch
    :exit, _ -> :ok
  end

  defp start_solo(name, scripts) do
    GenAgentEnsemble.start_link(
      name: name,
      strategy: Solo,
      opts: [agent: {"w", TestAgent, [backend: Mock, scripts: scripts]}]
    )
  end

  describe "delegations" do
    test "list/0, status/1, tell/2, poll/2", %{name: name} do
      {:ok, _} = start_solo(name, [[Event.new(:result, %{text: "hi"})]])

      assert name in E.list()
      assert {:ok, %{session: ^name}} = E.status(name)

      {:ok, token} = E.tell(name, "prompt")
      assert is_binary(token)
    end
  end

  describe "ask!/2" do
    test "returns the text string on success", %{name: name} do
      {:ok, _} = start_solo(name, [[Event.new(:result, %{text: "answer"})]])

      assert "answer" == E.ask!(name, "question")
    end

    test "raises on error", %{name: name} do
      {:ok, _} = start_solo(name, [{:error, :boom}])

      assert_raise RuntimeError, ~r/ask!.*failed.*boom/, fn ->
        E.ask!(name, "question")
      end
    end
  end

  describe "text/1" do
    test "extracts text from a Response struct" do
      assert "hi" == E.text(%Response{text: "hi"})
    end

    test "extracts text from an {:ok, response} tuple" do
      assert "hi" == E.text({:ok, %Response{text: "hi"}})
    end

    test "raises on {:error, reason}" do
      assert_raise RuntimeError, ~r/on error.*boom/, fn ->
        E.text({:error, :boom})
      end
    end
  end

  describe "puts/1" do
    test "prints response text and returns :ok" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok == E.puts({:ok, %Response{text: "line one\nline two"}})
        end)

      assert output == "line one\nline two\n"
    end
  end

  describe "await/2-3" do
    test "blocks until the token completes", %{name: name} do
      {:ok, _} = start_solo(name, [[Event.new(:result, %{text: "done"})]])

      {:ok, token} = E.tell(name, "go")
      response = E.await(name, token, 2_000)

      assert %Response{text: "done"} = response
    end

    test "raises on timeout when the token never completes", %{name: name} do
      # slow_fn sleeps longer than the await timeout
      slow = fn _prompt ->
        Process.sleep(500)
        [Event.new(:result, %{text: "eventually"})]
      end

      {:ok, _} = start_solo(name, [slow])
      {:ok, token} = E.tell(name, "slow")

      assert_raise RuntimeError, ~r/timed out/, fn ->
        E.await(name, token, 50)
      end
    end

    test "raises on error", %{name: name} do
      {:ok, _} = start_solo(name, [{:error, :nope}])
      {:ok, token} = E.tell(name, "boom")

      # Give the mock time to fail the token
      Process.sleep(50)

      assert_raise RuntimeError, ~r/failed.*nope/, fn ->
        E.await(name, token, 500)
      end
    end
  end

  describe "drain/1" do
    test "unwraps inbox entries to {token, text}", %{name: name} do
      {:ok, _} =
        start_solo(name, [
          [Event.new(:result, %{text: "x"})],
          [Event.new(:result, %{text: "y"})]
        ])

      {:ok, ta} = E.tell(name, "p1")
      {:ok, tb} = E.tell(name, "p2")

      # Let both tells complete and land in the inbox.
      Process.sleep(100)

      drained = E.drain(name)
      assert Map.new(drained) == %{ta => "x", tb => "y"}
    end

    test "surfaces token failures as {token, {:error, reason}}", %{name: name} do
      {:ok, _} = start_solo(name, [{:error, :kaput}])
      {:ok, t} = E.tell(name, "bad")

      Process.sleep(50)

      assert [{^t, {:error, :kaput}}] = E.drain(name)
    end
  end
end
