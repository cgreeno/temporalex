defmodule Temporalex.UpdatesTest do
  @moduledoc """
  Priority 2 — Updates (U1-U10) from TESTS_V2.md.

  `Testing.send_update/3` now blocks until the handler's return value
  produces a reply. For handlers that can't complete without further
  test-driven interaction (activity resolutions, async work), wrap
  `send_update` in `Task.async/1` and drive the workflow from the main
  test process.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test activities ---

  defmodule Acts do
    use Temporalex.Activity

    defactivity(double(x), do: {:ok, x * 2})
  end

  # --- Test workflows ---

  # Sync handler returns {:reply, response, state}.
  defmodule ReplyWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(%{items: []},
          update: %{
            "add" => fn [item], state ->
              {:reply, {:added, item}, %{state | items: [item | state.items]}}
            end
          },
          signal: %{
            "done" => fn _payload, state -> {:stop, state} end
          }
        )

      {:ok, result}
    end
  end

  # Sync handler with validator.
  defmodule ValidatedWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive([],
          update: %{
            "push" => {
              fn [value], list -> {:reply, :ok, [value | list]} end,
              validator: fn [value], _list ->
                if is_integer(value), do: :ok, else: {:error, :not_an_integer}
              end
            }
          },
          signal: %{
            "done" => fn _payload, list -> {:stop, Enum.reverse(list)} end
          }
        )

      {:ok, result}
    end
  end

  # Sync handler returns {:stop, response, state}.
  defmodule StopReplyWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(:pending,
          update: %{
            "finish" => fn [value], _state -> {:stop, {:final, value}, :finished} end
          }
        )

      {:ok, result}
    end
  end

  # Update handler calls an activity, then replies with the result.
  defmodule ActivityUpdateWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(:waiting,
          update: %{
            "compute" => fn [value], state ->
              {:ok, doubled} = Acts.double(value)
              {:reply, doubled, state}
            end
          },
          signal: %{
            "done" => fn _payload, state -> {:stop, state} end
          }
        )

      {:ok, result}
    end
  end

  # Async update handler — runs activity, returns result via update_state.
  defmodule AsyncUpdateWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(%{last: nil},
          update: %{
            "compute_async" => fn [value], state ->
              {:async,
               fn ->
                 {:ok, doubled} = Acts.double(value)
                 API.update_state(fn s -> {doubled, %{s | last: doubled}} end)
               end, state}
            end
          },
          signal: %{
            "done" => fn _payload, state -> {:stop, state} end
          }
        )

      {:ok, result}
    end
  end

  # Async update handler that crashes.
  defmodule AsyncCrashWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(%{processed: 0},
          update: %{
            "explode" => fn _args, state ->
              {:async,
               fn ->
                 raise "async handler exploded"
               end, state}
            end,
            "bump" => fn _args, state ->
              {:reply, :bumped, %{state | processed: state.processed + 1}}
            end
          },
          signal: %{
            "done" => fn _payload, state -> {:stop, state} end
          }
        )

      {:ok, result}
    end
  end

  defmodule NoHandlerWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(:waiting,
          update: %{
            "known" => fn _args, state -> {:reply, :ok, state} end
          },
          signal: %{
            "done" => fn _payload, state -> {:stop, state} end
          }
        )

      {:ok, result}
    end
  end

  defmodule NoReceiveWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      {:ok, _} = Acts.double(10)
      {:ok, :finished}
    end
  end

  # --- Tests ---

  describe "U1 — {:reply, response, state}" do
    test "handler response is returned to the send_update caller" do
      {:ok, exec} = Testing.start_workflow(ReplyWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      assert {:added, "apple"} = Testing.send_update(exec, "add", ["apple"])
      assert {:added, "banana"} = Testing.send_update(exec, "add", ["banana"])

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, %{items: items}} = Testing.next(exec)
      assert items == ["banana", "apple"]
    end
  end

  describe "U2 — validator accept" do
    test "validator :ok lets handler run and reply" do
      {:ok, exec} = Testing.start_workflow(ValidatedWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      assert :ok = Testing.send_update(exec, "push", [1])
      assert :ok = Testing.send_update(exec, "push", [2])

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, [1, 2]} = Testing.next(exec)
    end
  end

  describe "U3 — validator reject" do
    test "validator {:error, reason} surfaces to caller without running handler" do
      {:ok, exec} = Testing.start_workflow(ValidatedWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      assert {:error, :not_an_integer} = Testing.send_update(exec, "push", ["nope"])

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      # Rejected update did not add anything.
      assert {:ok, []} = Testing.next(exec)
    end
  end

  describe "U4 — update rejected outside receive" do
    test "send_update returns {:error, :not_in_receive} when workflow has no receive" do
      {:ok, exec} = Testing.start_workflow(NoReceiveWorkflow, %{})
      assert {:activity, _} = Testing.next(exec)

      assert {:error, :not_in_receive} = Testing.send_update(exec, "whatever", [])

      # Workflow still completes normally.
      assert {:ok, :finished} = Testing.resolve(exec, {:ok, 20})
    end
  end

  describe "U5 — no matching handler" do
    test "send_update returns {:error, :no_handler} for unregistered names" do
      {:ok, exec} = Testing.start_workflow(NoHandlerWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      assert {:error, :no_handler} = Testing.send_update(exec, "unknown", [])

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, :waiting} = Testing.next(exec)
    end
  end

  describe "U6 — handler calls activities" do
    test "update handler can call an activity and reply with its result" do
      {:ok, exec} = Testing.start_workflow(ActivityUpdateWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      # The handler blocks on the activity — wrap send_update so this test
      # process can resolve it.
      update_task = Task.async(fn -> Testing.send_update(exec, "compute", [7]) end)

      Process.sleep(20)
      assert {:activity, call} = Testing.next(exec)
      assert call.input == [7]

      # Resolve activity → handler's {:reply, _, _} replies to the task.
      Testing.resolve(exec, {:ok, 14})
      assert 14 = Task.await(update_task, 1_000)

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, :waiting} = Testing.next(exec)
    end
  end

  describe "U7 — {:stop, response, state} exits receive" do
    test "stop response replies to caller and ends the receive" do
      {:ok, exec} = Testing.start_workflow(StopReplyWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      assert {:final, 42} = Testing.send_update(exec, "finish", [42])
      Process.sleep(20)

      assert {:ok, :finished} = Testing.next(exec)
    end
  end

  describe "U8 — {:async, fn, state}" do
    test "async handler runs activity and finally unblocks send_update" do
      {:ok, exec} = Testing.start_workflow(AsyncUpdateWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      update_task =
        Task.async(fn -> Testing.send_update(exec, "compute_async", [5]) end)

      Process.sleep(20)
      assert {:activity, call} = Testing.next(exec)
      assert call.input == [5]

      Testing.resolve(exec, {:ok, 10})
      _ = Task.await(update_task, 1_000)

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, %{last: 10}} = Testing.next(exec)
    end
  end

  describe "U9 — async handler return becomes reply" do
    test "the async fn's return value is returned to the send_update caller" do
      {:ok, exec} = Testing.start_workflow(AsyncUpdateWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      update_task =
        Task.async(fn -> Testing.send_update(exec, "compute_async", [6]) end)

      Process.sleep(20)
      assert {:activity, _} = Testing.next(exec)
      Testing.resolve(exec, {:ok, 12})

      # update_state inside the async fn returns the first tuple element;
      # that becomes the async fn's return value, which becomes the reply.
      assert 12 = Task.await(update_task, 1_000)

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)
      assert {:ok, %{last: 12}} = Testing.next(exec)
    end
  end

  describe "U10 — async handler failure" do
    test "caller gets {:error, {:handler_crashed, _}}; workflow keeps running" do
      {:ok, exec} = Testing.start_workflow(AsyncCrashWorkflow, %{})
      assert {:receive, _} = Testing.next(exec)

      update_task = Task.async(fn -> Testing.send_update(exec, "explode", []) end)

      assert {:error, {:handler_crashed, _reason}} = Task.await(update_task, 1_000)

      # Workflow continues — another update still works.
      assert :bumped = Testing.send_update(exec, "bump", [])

      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, %{processed: 1}} = Testing.next(exec)
    end
  end
end
