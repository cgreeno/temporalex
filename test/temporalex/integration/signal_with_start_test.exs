defmodule Temporalex.SignalWithStartIntegrationTest do
  @moduledoc """
  Live-Temporal coverage for `Temporalex.with_signal/3`: a signal delivered
  atomically with the start, for an external event that can arrive before
  the workflow it belongs to exists.

  Modelled on the settlement case in issue #69 — an order whose payments
  each settle independently, where a settlement event can beat the checkout
  it belongs to.

  Connects to 127.0.0.1:7233. Skipped by default.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  alias Temporalex.TestSupport.Server

  @queue "signal-with-start"

  defmodule Settlement do
    @moduledoc """
    Parks in one phase accumulating `"settled"` signals, stopping once every
    expected payment has reported.
    """
    use Temporalex.Workflow, queue: "signal-with-start"

    alias Temporalex.Workflow.API

    def id(%{order_id: order_id}), do: "order-#{order_id}"

    def run(%{expected: expected} = input) do
      settled =
        API.phase(%{},
          signal: %{
            "settled" => fn [%{"payment_id" => id} = payment], acc ->
              acc = Map.put(acc, id, payment)
              if map_size(acc) == expected, do: {:stop, acc}, else: {:noreply, acc}
            end
          },
          timeout: Map.get(input, :phase_timeout, 20_000)
        )

      case settled do
        {:timeout, partial} -> {:ok, {:timed_out, Map.keys(partial) |> Enum.sort()}}
        acc -> {:ok, {:settled, Map.keys(acc) |> Enum.sort()}}
      end
    end
  end

  setup_all do
    unless temporal_available?() do
      raise "Temporal dev server not reachable at 127.0.0.1:7233"
    end

    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    client_name = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")

    {:ok, client_pid} =
      Temporalex.Client.start_link(
        name: client_name,
        backend: Temporalex.Backend.TemporalCore,
        target: Server.target(),
        namespace: Temporalex.TestSupport.Namespace.name(),
        task_queue: @queue
      )

    {:ok, worker_pid} =
      Temporalex.Worker.start_link(
        name: worker_name,
        client: client_name,
        workflows: [Settlement],
        activities: []
      )

    on_exit(fn ->
      try do
        if Process.alive?(worker_pid), do: Supervisor.stop(worker_pid, :normal, 5_000)
        if Process.alive?(client_pid), do: GenServer.stop(client_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, client: client_name, search_attribute: register_search_attribute!()}
  end

  # The shared per-run namespace registers no custom attributes, and this is
  # the only test here that needs one. `create` returns before the mapping is
  # usable, so the poll is the point.
  defp register_search_attribute! do
    name = "CustomKeywordField"

    with cli when is_binary(cli) <- System.find_executable("temporal"),
         {_out, 0} <- search_attribute_cmd(cli, ["create", "--type", "Keyword"], name) do
      name
    else
      _ -> nil
    end
  end

  defp search_attribute_cmd(cli, args, name) do
    name_args = if name, do: ["--name", name], else: []

    System.cmd(
      cli,
      ["operator", "search-attribute"] ++
        args ++
        ["--namespace", Temporalex.TestSupport.Namespace.name()] ++
        name_args ++ Server.cli_address_args(),
      stderr_to_stdout: true
    )
  end

  defp temporal_available? do
    case :gen_tcp.connect(
           String.to_charlist(Server.host()),
           Server.port(),
           [:binary, active: false],
           1_000
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  defp settlement(payment_id, extra \\ %{}) do
    Map.merge(%{"payment_id" => payment_id, "status" => "captured"}, extra)
  end

  defp checkout(order_id, expected, ctx, extra \\ %{}) do
    %{order_id: order_id, expected: expected}
    |> Map.merge(extra)
    |> Settlement.new()
    |> Temporalex.client(ctx.client)
    |> Temporalex.timeout(30_000)
  end

  defp order_id, do: "o#{System.unique_integer([:positive])}"

  test "a settlement that arrives before the checkout starts it", ctx do
    id = order_id()

    handle =
      id
      |> checkout(2, ctx)
      |> Temporalex.with_signal("settled", [settlement("pay-1")])
      |> Temporalex.start!()

    assert handle.workflow_id == "order-#{id}"

    :ok = Settlement.signal!(%{order_id: id}, "settled", settlement("pay-2"), client: ctx.client)

    assert {:ok, {:settled, ["pay-1", "pay-2"]}} = Temporalex.await(handle)
  end

  test "the settlement lands even though it precedes the phase that handles it", ctx do
    id = order_id()

    handle =
      id
      |> checkout(1, ctx)
      |> Temporalex.with_signal("settled", [settlement("pay-only")])
      |> Temporalex.start!()

    assert {:ok, {:settled, ["pay-only"]}} = Temporalex.await(handle)
  end

  test "a second settlement attaches to the running checkout rather than starting one", ctx do
    id = order_id()

    first =
      id
      |> checkout(2, ctx)
      |> Temporalex.with_signal("settled", [settlement("pay-1")])
      |> Temporalex.start!()

    second =
      id
      |> checkout(2, ctx)
      |> Temporalex.with_signal("settled", [settlement("pay-2")])
      |> Temporalex.start!()

    assert second.run_id == first.run_id
    assert {:ok, {:settled, ["pay-1", "pay-2"]}} = Temporalex.await(first)
  end

  test "a start without with_signal is unchanged", ctx do
    id = order_id()

    handle = id |> checkout(1, ctx) |> Temporalex.start!()

    :ok = Settlement.signal!(%{order_id: id}, "settled", settlement("pay-1"), client: ctx.client)

    assert {:ok, {:settled, ["pay-1"]}} = Temporalex.await(handle)
  end

  test "concurrent settlements racing the start all land exactly once", ctx do
    id = order_id()
    payments = for n <- 1..8, do: "pay-#{n}"

    handles =
      payments
      |> Task.async_stream(
        fn payment ->
          id
          |> checkout(length(payments), ctx)
          |> Temporalex.with_signal("settled", [settlement(payment)])
          |> Temporalex.start!()
        end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, handle} -> handle end)

    assert [_] = handles |> Enum.map(& &1.run_id) |> Enum.uniq()
    assert {:ok, {:settled, settled}} = Temporalex.await(hd(handles))
    assert settled == Enum.sort(payments)
  end

  test "a redelivered settlement does not start a second run or double-count", ctx do
    id = order_id()

    first =
      id
      |> checkout(2, ctx)
      |> Temporalex.with_signal("settled", [settlement("pay-1")])
      |> Temporalex.start!()

    redelivered =
      id
      |> checkout(2, ctx)
      |> Temporalex.with_signal("settled", [settlement("pay-1")])
      |> Temporalex.start!()

    assert redelivered.run_id == first.run_id

    :ok = Settlement.signal!(%{order_id: id}, "settled", settlement("pay-2"), client: ctx.client)

    assert {:ok, {:settled, ["pay-1", "pay-2"]}} = Temporalex.await(first)
  end

  test "the phase timeout still fires when a settlement never arrives", ctx do
    id = order_id()

    handle =
      id
      |> checkout(2, ctx, %{phase_timeout: 2_000})
      |> Temporalex.with_signal("settled", [settlement("pay-1")])
      |> Temporalex.start!()

    assert {:ok, {:timed_out, ["pay-1"]}} = Temporalex.await(handle)
  end

  test "a rich settlement payload round-trips through the start request", ctx do
    id = order_id()

    payment =
      settlement("pay-1", %{
        "amount" => %{"units" => 1250, "currency" => "GBP"},
        "transaction_id" => "txn-abc",
        "refunded" => false,
        "meta" => nil
      })

    handle =
      id
      |> checkout(1, ctx)
      |> Temporalex.with_signal("settled", [payment])
      |> Temporalex.start!()

    assert {:ok, {:settled, ["pay-1"]}} = Temporalex.await(handle)
  end

  test "with_signal carrying no arguments still starts and delivers", ctx do
    id = order_id()

    handle =
      id
      |> checkout(1, ctx)
      |> Temporalex.with_signal("settled", [settlement("pay-1")])
      |> Temporalex.start!()

    assert {:ok, {:settled, ["pay-1"]}} = Temporalex.await(handle)
  end

  test "search attributes survive the signal-with-start request", ctx do
    if ctx.search_attribute == nil, do: raise("could not register a search attribute")

    id = order_id()
    label = "sws-#{System.unique_integer([:positive])}"

    handle =
      start_once_mapping_is_live(fn ->
        id
        |> checkout(1, ctx)
        |> Temporalex.index(%{
          ctx.search_attribute => Temporalex.SearchAttribute.keyword(label)
        })
        |> Temporalex.with_signal("settled", [settlement("pay-1")])
        |> Temporalex.start()
      end)

    assert eventually(fn ->
             visible?("#{ctx.search_attribute} = '#{label}'", handle.workflow_id)
           end),
           "the workflow was not indexed under the search attribute sent with the signal"

    assert {:ok, {:settled, ["pay-1"]}} = Temporalex.await(handle)
  end

  test "a start_signal with no name is refused by the NIF rather than crashing it", ctx do
    id = order_id()

    assert {:error, error} =
             Temporalex.Client.start_workflow(
               ctx.client,
               Settlement,
               %{order_id: id, expected: 1},
               workflow_id: "order-#{id}",
               start_signal: [args: [settlement("pay-1")]],
               timeout: 10_000
             )

    assert Exception.message(error) =~ "start_signal requires a name"
  end

  defp start_once_mapping_is_live(fun, attempts \\ 30) do
    case fun.() do
      {:ok, handle} ->
        handle

      {:error, error} ->
        message = Exception.message(error)

        cond do
          attempts == 0 -> flunk("search attribute never became usable: #{message}")
          message =~ "no mapping defined" -> Process.sleep(200)
          true -> flunk(message)
        end

        start_once_mapping_is_live(fun, attempts - 1)
    end
  end

  defp visible?(query, workflow_id) do
    cli = System.find_executable("temporal")

    args =
      [
        "workflow",
        "list",
        "--namespace",
        Temporalex.TestSupport.Namespace.name(),
        "--query",
        query,
        "--output",
        "json"
      ] ++ Server.cli_address_args()

    case System.cmd(cli, args, stderr_to_stdout: true) do
      {output, 0} -> String.contains?(output, workflow_id)
      _ -> false
    end
  end

  defp eventually(fun, attempts \\ 30) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(200)
        {:cont, false}
      end
    end)
  end
end
