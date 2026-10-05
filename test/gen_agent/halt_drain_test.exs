defmodule GenAgent.HaltDrainTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias GenAgent.Backends.Mock
  alias GenAgent.{Event, Server}
  alias GenAgent.Support.TestAgent

  setup do
    %{task_sup: start_supervised!(Task.Supervisor)}
  end

  for outcome <- [:response, :error],
      halt_source <- [:turn, :event, :rejected_event, :rejected_chain] do
    @tag outcome: outcome, halt_source: halt_source
    test "#{outcome} turn finalizes after all notifications when #{halt_source} halts",
         %{task_sup: task_sup, outcome: outcome, halt_source: halt_source} do
      parent = self()
      name = "halt-drain-#{System.unique_integer([:positive])}"

      trace = fn state, entry ->
        %{state | extra: Map.update(state.extra, :trace, [entry], &(&1 ++ [entry]))}
      end

      decision = fn state ->
        case halt_source do
          :turn -> {:halt, state}
          :rejected_chain -> {:prompt, String.duplicate("next", 100), state}
          _ -> {:noreply, state}
        end
      end

      script = fn _prompt ->
        send(parent, {:turn_blocked, self()})

        receive do
          :complete ->
            case outcome do
              :response -> [Event.new(:result, %{text: "done"})]
              :error -> [Event.new(:error, %{reason: :failed})]
            end
        end
      end

      opts = [
        name: name,
        backend: Mock,
        module: TestAgent,
        task_supervisor: task_sup,
        watchdog_ms: 5_000,
        max_pending_prompts: 0,
        max_pending_prompt_bytes: 64,
        init_opts: [
          scripts: [script],
          responder: fn _ref, _response, state -> decision.(trace.(state, :response)) end,
          error_handler: fn _ref, reason, state ->
            case reason do
              {:overloaded, _info} -> {:halt, trace.(state, :rejected_prompt)}
              :failed -> decision.(trace.(state, :error))
            end
          end,
          post_turn: fn _outcome, _ref, state -> {:ok, trace.(state, :post_turn)} end,
          event_handler: fn event, state ->
            state = trace.(state, event)

            case {event, halt_source} do
              {:repeat_halt, _} -> {:halt, state}
              {:halt, :rejected_event} -> {:prompt, "event prompt", state}
              {:halt, source} when source in [:turn, :event] -> {:halt, state}
              _ -> {:noreply, state}
            end
          end,
          post_run: fn state ->
            send(parent, {:completion, :post_run, state})
            :ok
          end
        ]
      ]

      handler = "halt-drain-#{name}"

      :ok =
        :telemetry.attach(
          handler,
          [:gen_agent, :halted],
          fn _event, _measurements, metadata, _config ->
            if metadata.agent == name,
              do: send(parent, {:completion, :halted, metadata.agent_state})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      pid = start_supervised!({Server, opts})
      caller = Task.async(fn -> :gen_statem.call(pid, {:ask, "go"}) end)
      assert_receive {:turn_blocked, task_pid}

      for event <- [:first, :halt, :last],
          do: assert(:ok == :gen_statem.call(pid, {:notify_ack, event}))

      send(task_pid, :complete)

      case outcome do
        :response -> assert {:ok, %{text: "done"}} = Task.await(caller)
        :error -> assert {:error, :failed} = Task.await(caller)
      end

      # Both callbacks run in the server process; consume the oldest message
      # rather than selectively receiving by kind to verify their order too.
      assert_receive {:completion, first_kind, final_state}
      assert first_kind == :post_run
      assert final_state.events == [:first, :halt, :last]

      expected_trace =
        case halt_source do
          :rejected_chain -> [outcome, :post_turn, :rejected_prompt, :first, :halt, :last]
          :rejected_event -> [outcome, :post_turn, :first, :halt, :rejected_prompt, :last]
          _ -> [outcome, :post_turn, :first, :halt, :last]
        end

      assert final_state.extra.trace == expected_trace
      assert_receive {:completion, second_kind, telemetry_state}
      assert second_kind == :halted
      assert telemetry_state == final_state
      assert %{halted: true, agent_state: ^final_state} = :gen_statem.call(pid, :status)

      # Completion describes the drained batch, not future notifications.
      assert :ok = :gen_statem.call(pid, {:notify_ack, :later})
      assert :ok = :gen_statem.call(pid, {:notify_ack, :repeat_halt})

      assert %{halted: true, agent_state: %{events: [:first, :halt, :last, :later, :repeat_halt]}} =
               :gen_statem.call(pid, :status)

      refute_received {:completion, _, _}
    end
  end
end
