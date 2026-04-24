defmodule Temporalex.ReceiveTest do
  use ExUnit.Case, async: true

  alias Temporalex.Testing

  # --- Test activities ---

  defmodule Activities.Pricing do
    use Temporalex.Activity

    defactivity lookup(sku) do
      _ = sku
      {:ok, 9.99}
    end
  end

  # --- Test workflows ---

  defmodule CounterWorkflow do
    use Temporalex.Workflow

    def handle_query("value", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(0)

      result =
        API.receive(0,
          signal: %{
            "increment" => fn _args, count -> {:noreply, count + 1} end,
            "decrement" => fn _args, count -> {:noreply, count - 1} end,
            "done" => fn _args, count -> {:stop, count} end
          }
        )

      API.publish_state(result)
      {:ok, result}
    end
  end

  defmodule UpdateWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      result =
        API.receive(%{items: []},
          update: %{
            "add_item" => {
              fn [item], state ->
                {:reply, :ok, %{state | items: [item | state.items]}}
              end,
              validator: fn [item], _state ->
                if item != "", do: :ok, else: {:error, "empty item"}
              end
            },
            "get_items" => fn _args, state ->
              {:reply, state.items, state}
            end
          },
          signal: %{
            "done" => fn _args, state -> {:stop, state} end
          }
        )

      {:ok, result}
    end
  end

  defmodule AsyncHandlerWorkflow do
    use Temporalex.Workflow

    def handle_query("stock", _args, state), do: {:reply, state}

    def run(_args) do
      API.publish_state(%{})

      result =
        API.receive(%{stock: %{}},
          update: %{
            "restock" => fn [item], state ->
              {:async,
               fn ->
                 {:ok, price} = Activities.Pricing.lookup(item.sku)

                 API.update_state(fn s ->
                   entry = %{quantity: item.qty, price: price}
                   new_stock = Map.put(s.stock, item.sku, entry)
                   {entry, %{s | stock: new_stock}}
                 end)
               end, state}
            end
          },
          signal: %{
            "close" => fn _args, state -> {:stop, state} end
          }
        )

      {:ok, result.stock}
    end
  end

  defmodule TimeoutWorkflow do
    use Temporalex.Workflow

    def run(_args) do
      case API.receive(0,
             signal: %{
               "event" => fn _args, count -> {:noreply, count + 1} end
             },
             timeout: 60_000
           ) do
        {:timeout, count} -> {:ok, {:timed_out, count}}
        count -> {:ok, {:stopped, count}}
      end
    end
  end

  # --- Tests ---

  describe "receive with signals" do
    test "counter workflow: increment, decrement, done" do
      {:ok, exec} = Testing.start_workflow(CounterWorkflow, %{})

      assert {:receive, info} = Testing.next(exec)
      assert "increment" in info.signals
      assert "done" in info.signals

      # Send signals one at a time, allowing handlers to process
      Testing.send_signal(exec, "increment", nil)
      Process.sleep(10)
      Testing.send_signal(exec, "increment", nil)
      Process.sleep(10)
      Testing.send_signal(exec, "decrement", nil)
      Process.sleep(10)

      # Query published state (set before receive, not updated by handlers)
      assert {:reply, 0} = Testing.query(exec, "value")

      # Stop the receive
      Testing.send_signal(exec, "done", nil)
      Process.sleep(10)

      assert {:ok, 1} = Testing.next(exec)
    end
  end

  describe "receive with updates" do
    test "add items with validation" do
      {:ok, exec} = Testing.start_workflow(UpdateWorkflow, %{})

      assert {:receive, info} = Testing.next(exec)
      assert "add_item" in info.updates

      # Valid item
      assert :ok = Testing.send_update(exec, "add_item", ["apple"])
      Process.sleep(20)

      # Invalid item — validator rejects
      assert {:error, "empty item"} = Testing.send_update(exec, "add_item", [""])

      # Add another valid item
      assert :ok = Testing.send_update(exec, "add_item", ["banana"])
      Process.sleep(20)

      # Stop
      Testing.send_signal(exec, "done", nil)
      Process.sleep(20)

      assert {:ok, result} = Testing.next(exec)
      assert "banana" in result.items
      assert "apple" in result.items
    end
  end

  describe "receive with async handlers" do
    test "async update handler with activity and update_state" do
      {:ok, exec} = Testing.start_workflow(AsyncHandlerWorkflow, %{})

      assert {:receive, _info} = Testing.next(exec)

      # send_update blocks until the handler's reply is ready. The async
      # handler needs the test to resolve an activity before it completes,
      # so we spawn send_update in a Task and drive the activity from here.
      update_task =
        Task.async(fn ->
          Testing.send_update(exec, "restock", [%{sku: "WIDGET", qty: 10}])
        end)

      Process.sleep(20)
      assert {:activity, call} = Testing.next(exec)
      assert call.type =~ "Pricing.lookup"

      # Resolve the activity — handler calls update_state then exits.
      # resolve returns {:receive, ...} since we're back in the receive loop.
      assert {:receive, _} = Testing.resolve(exec, {:ok, 19.99})

      # Async handler's result is the reply to send_update.
      _update_reply = Task.await(update_task, 1_000)

      # Close the receive
      Testing.send_signal(exec, "close", nil)

      assert {:ok, stock} = Testing.next(exec)
      assert stock["WIDGET"] == %{quantity: 10, price: 19.99}
    end
  end

  describe "receive edge cases" do
    test "signals buffered before receive are dispatched" do
      # Use a workflow that buffers a signal then enters receive
      defmodule BufferedSignalWorkflow do
        use Temporalex.Workflow

        def run(_args) do
          # First, wait for a signal outside receive (buffers it)
          # Then enter receive where the signal should be consumed
          _approval = API.wait_for_signal("start")

          result =
            API.receive(0,
              signal: %{
                "increment" => fn _args, count -> {:noreply, count + 1} end,
                "done" => fn _args, count -> {:stop, count} end
              }
            )

          {:ok, result}
        end
      end

      {:ok, exec} = Testing.start_workflow(BufferedSignalWorkflow, %{})

      # Workflow waits for "start" signal
      assert {:signal, "start"} = Testing.next(exec)

      # Buffer an "increment" signal before sending "start"
      Testing.send_signal(exec, "increment", nil)
      # Now send "start" to unblock wait_for_signal
      Testing.send_signal(exec, "start", nil)

      # Workflow enters receive — buffered "increment" should auto-dispatch
      Process.sleep(50)
      # The increment handler should have run, now send done
      Testing.send_signal(exec, "done", nil)
      Process.sleep(50)

      assert {:ok, 1} = Testing.next(exec)
    end
  end
end
