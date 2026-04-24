defmodule Temporalex.StateModelTest do
  @moduledoc """
  Priority 3 — State Model (SM1-SM6) from TESTS_V2.md.

  Three state types in the workflow API:

  1. **Local variables** — closed over inside `run/1`; private to the runner
     process.
  2. **Published state** — set via `API.publish_state/1`; visible to query
     handlers.
  3. **Receive state** — the argument to `API.receive/2`; scoped to one
     receive block, mutable via handler return values and `update_state/1`.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test workflows ---

  defmodule LocalsWorkflow do
    use Temporalex.Workflow

    def handle_query("locals", _args, state), do: {:reply, state}

    def run(_args) do
      local_value = :only_in_run

      # Never published, never exposed to queries.
      _ = local_value

      result =
        API.receive(:ignored,
          signal: %{
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, {local_value, result}}
    end
  end

  defmodule ReceiveNotQueryableWorkflow do
    use Temporalex.Workflow

    def handle_query("state", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(:published_snapshot)

      result =
        API.receive(:receive_only,
          signal: %{
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, result}
    end
  end

  defmodule PhaseWorkflow do
    use Temporalex.Workflow

    def handle_query("phase", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(:phase_one)

      _ =
        API.receive(:p1_initial,
          signal: %{"next" => fn _p, s -> {:stop, s} end}
        )

      API.publish_state(:phase_two)

      _ =
        API.receive(:p2_initial,
          signal: %{"finish" => fn _p, s -> {:stop, s} end}
        )

      {:ok, :complete}
    end
  end

  defmodule ReplaceStateWorkflow do
    use Temporalex.Workflow

    def handle_query("state", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(%{a: 1, b: 2, c: 3})
      {:ok, _} = wait_and_then()

      # Replace entirely — no merge; :a and :b are gone.
      API.publish_state(%{only: :this_key})
      {:ok, :done}
    end

    defp wait_and_then do
      API.receive(nil,
        signal: %{"go" => fn _p, s -> {:stop, s} end}
      )

      {:ok, :ok}
    end
  end

  defmodule ThreeStatesWorkflow do
    use Temporalex.Workflow

    def handle_query("snapshot", _args, state), do: {:reply, state}

    def run(_args) do
      local = :runner_local
      API.publish_state(%{published: :yes})

      receive_result =
        API.receive(%{rx_counter: 0},
          update: %{
            "bump" => fn _args, s ->
              {:reply, :ok, %{s | rx_counter: s.rx_counter + 1}}
            end
          },
          signal: %{
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, %{local: local, receive_final: receive_result}}
    end
  end

  defmodule AsyncPublishWorkflow do
    use Temporalex.Workflow

    def handle_query("state", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(%{published_count: 0})

      _ =
        API.receive(%{internal: 0},
          update: %{
            "kick" => fn _args, state ->
              {:async,
               fn ->
                 # Inside async handler — mutate both receive_state (via
                 # update_state) AND published_state (via publish_state).
                 API.update_state(fn s -> {s.internal + 1, %{s | internal: s.internal + 1}} end)
                 API.publish_state(%{published_count: 99})
               end, state}
            end
          },
          signal: %{
            "done" => fn _payload, s -> {:stop, s} end
          }
        )

      {:ok, :complete}
    end
  end

  # --- Tests ---

  describe "SM1 — local variables private to run/1" do
    test "local variable is not reachable via queries, only via final result" do
      {:ok, exec} = Testing.start_workflow(LocalsWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      # No publish_state was ever called — query returns nil.
      assert {:reply, nil} = Testing.query(exec, "locals")

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      # Local value only visible in the returned workflow result.
      assert {:ok, {:only_in_run, :ignored}} = Testing.next(exec)
    end
  end

  describe "SM2 — receive state not visible to queries" do
    test "query returns last published_state, not the receive_state value" do
      {:ok, exec} = Testing.start_workflow(ReceiveNotQueryableWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      assert {:reply, :published_snapshot} = Testing.query(exec, "state")

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      # Workflow returns receive_state, which was never exposed to queries.
      assert {:ok, :receive_only} = Testing.next(exec)
    end
  end

  describe "SM3 — published state persists across receives" do
    test "published_state set in phase one is still queryable during phase two" do
      {:ok, exec} = Testing.start_workflow(PhaseWorkflow, %{})

      assert {:receive, _} = Testing.next(exec)
      assert {:reply, :phase_one} = Testing.query(exec, "phase")

      Testing.send_signal(exec, "next", nil)
      Process.sleep(20)

      assert {:receive, _} = Testing.next(exec)
      assert {:reply, :phase_two} = Testing.query(exec, "phase")

      Testing.send_signal(exec, "finish", nil)
      Process.sleep(20)

      # Last published value survives workflow completion.
      assert {:ok, :complete} = Testing.next(exec)
      assert {:reply, :phase_two} = Testing.query(exec, "phase")
    end
  end

  describe "SM4 — published state replaced entirely on each publish" do
    test "second publish_state wholly replaces the first" do
      {:ok, exec} = Testing.start_workflow(ReplaceStateWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      assert {:reply, %{a: 1, b: 2, c: 3}} = Testing.query(exec, "state")

      Testing.send_signal(exec, "go", nil)
      Process.sleep(20)

      # After the second publish_state, the previous keys are gone.
      assert {:ok, :done} = Testing.next(exec)
      assert {:reply, %{only: :this_key}} = Testing.query(exec, "state")
    end
  end

  describe "SM5 — all three state types independent" do
    test "local, published, and receive state each evolve without cross-contamination" do
      {:ok, exec} = Testing.start_workflow(ThreeStatesWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      # Only published_state reaches queries.
      assert {:reply, %{published: :yes}} = Testing.query(exec, "snapshot")

      # Mutate receive_state via an update handler.
      assert :ok = Testing.send_update(exec, "bump", [])
      assert :ok = Testing.send_update(exec, "bump", [])

      # Query still sees only the published snapshot (unchanged).
      assert {:reply, %{published: :yes}} = Testing.query(exec, "snapshot")

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      # Local and receive_state surface only in the returned result.
      assert {:ok, %{local: :runner_local, receive_final: %{rx_counter: 2}}} =
               Testing.next(exec)
    end
  end

  describe "SM6 — publish_state works from async handlers" do
    test "publish_state called inside an async update handler mutates query-visible state" do
      {:ok, exec} = Testing.start_workflow(AsyncPublishWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      assert {:reply, %{published_count: 0}} = Testing.query(exec, "state")

      # Fire async update — it calls publish_state from the handler process.
      update_task = Task.async(fn -> Testing.send_update(exec, "kick", []) end)
      _ = Task.await(update_task, 1_000)

      # Query now reflects the async handler's publish_state.
      assert {:reply, %{published_count: 99}} = Testing.query(exec, "state")

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, :complete} = Testing.next(exec)
    end
  end
end
