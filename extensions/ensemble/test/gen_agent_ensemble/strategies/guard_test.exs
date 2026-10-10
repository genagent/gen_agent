defmodule GenAgentEnsemble.Strategies.GuardTest do
  use ExUnit.Case, async: true

  alias GenAgentEnsemble.Strategies.Guard

  test "returns the value of a normal call" do
    assert {:ok, 3} = Guard.call(:label, &Kernel.+/2, [1, 2])
  end

  test "accepts a valid result and rejects an invalid one without echoing it" do
    assert {:ok, "text"} = Guard.call(:label, fn -> "text" end, [], &is_binary/1)

    assert {:error, {:invalid_strategy_result, :label}} =
             Guard.call(:label, fn -> {:secret, "payload"} end, [], &is_binary/1)
  end

  test "classifies raise, throw and exit by kind and class" do
    cases = [
      {fn -> raise "secret-payload" end,
       {:strategy_function_failed, :label, :error, RuntimeError}},
      {fn -> raise ArgumentError, "secret-payload" end,
       {:strategy_function_failed, :label, :error, ArgumentError}},
      {fn -> :erlang.error(:badarg) end,
       {:strategy_function_failed, :label, :error, ArgumentError}},
      {fn -> :erlang.error(:custom_term) end,
       {:strategy_function_failed, :label, :error, ErlangError}},
      {fn -> throw({:secret, "payload"}) end,
       {:strategy_function_failed, :label, :throw, :other}},
      {fn -> exit({:secret, "payload"}) end, {:strategy_function_failed, :label, :exit, :other}}
    ]

    for {fun, expected} <- cases do
      assert {:error, ^expected} = Guard.call(:label, fun, [])
    end
  end

  test "failure reasons never contain the payload or message" do
    funs = [
      fn -> raise "secret-payload" end,
      fn -> throw("secret-payload") end,
      fn -> exit("secret-payload") end
    ]

    for fun <- funs do
      assert {:error, reason} = Guard.call(:label, fun, [])
      refute inspect(reason) =~ "secret"
    end
  end

  test "a raising validity predicate is the strategy's bug and propagates" do
    assert_raise ArgumentError, "bad", fn ->
      Guard.call(:label, fn -> :ok end, [], fn _ -> raise ArgumentError, "bad" end)
    end
  end

  test "a non-function or wrong-arity callback propagates instead of being reported" do
    for fun <- [nil, :not_a_function, fn -> :ok end, fn _, _ -> :ok end] do
      assert_raise FunctionClauseError, fn -> Guard.call(:label, fun, [1]) end
    end
  end

  test "a callback that raises FunctionClauseError internally is still contained" do
    fun = fn :only -> :ok end

    assert {:error, {:strategy_function_failed, :label, :error, FunctionClauseError}} =
             Guard.call(:label, fun, [:other])
  end
end
