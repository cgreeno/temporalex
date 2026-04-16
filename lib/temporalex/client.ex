defmodule Temporalex.Client do
  @moduledoc """
  Client for interacting with Temporal workflows from outside workflow code.

  Used to start, signal, query, and cancel workflows programmatically.

  ## Usage

      # Get client from a running worker
      {:ok, client} = Temporalex.Client.connect("http://localhost:7233")

      # Start a workflow
      {:ok, run_id} = Temporalex.Client.start_workflow(client, "default",
        workflow_id: "order-123",
        workflow_type: "MyApp.Workflows.Order",
        task_queue: "my-queue",
        input: %{order_id: "123"}
      )

      # Signal a workflow
      :ok = Temporalex.Client.signal_workflow(client, "default",
        workflow_id: "order-123",
        signal_name: "approve",
        input: %{approved: true}
      )

      # Query a workflow
      {:ok, result} = Temporalex.Client.query_workflow(client, "default",
        workflow_id: "order-123",
        query_type: "status"
      )
  """

  @doc "Connect to a Temporal server. Returns `{:ok, client}` or `{:error, reason}`."
  def connect(url, opts \\ []) do
    {:ok, runtime} = Temporalex.Runtime.get()
    api_key = Keyword.get(opts, :api_key, "")
    headers = Keyword.get(opts, :headers, %{})

    Temporalex.Native.connect(runtime, url, api_key, headers, self())

    receive do
      {:connected, client} -> {:ok, client}
      {:connect_error, reason} -> {:error, reason}
    after
      10_000 -> {:error, :timeout}
    end
  end

  @doc """
  Start a workflow execution.

  ## Options (required)
  - `:workflow_id` — unique workflow identifier
  - `:workflow_type` — workflow type name (e.g., "MyApp.Workflows.Order")
  - `:task_queue` — task queue name

  ## Options (optional)
  - `:input` — workflow input (will be ETF-encoded)
  - `:request_id` — idempotency key (auto-generated if omitted)
  """
  def start_workflow(client, namespace, opts) do
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    workflow_type = Keyword.fetch!(opts, :workflow_type)
    task_queue = Keyword.fetch!(opts, :task_queue)
    input = Keyword.get(opts, :input)
    request_id = Keyword.get(opts, :request_id, generate_request_id())

    input_payload = if input, do: Temporalex.Converter.encode(input), else: nil

    Temporalex.Native.start_workflow(
      client,
      namespace,
      workflow_id,
      workflow_type,
      task_queue,
      input_payload,
      request_id,
      self()
    )

    receive do
      {:start_workflow_result, result} -> result
    after
      30_000 -> {:error, :timeout}
    end
  end

  @doc """
  Send a signal to a running workflow.

  ## Options (required)
  - `:workflow_id` — target workflow ID
  - `:signal_name` — signal name

  ## Options (optional)
  - `:input` — signal payload
  - `:run_id` — specific run ID (empty string for latest)
  """
  def signal_workflow(client, namespace, opts) do
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    signal_name = Keyword.fetch!(opts, :signal_name)
    run_id = Keyword.get(opts, :run_id, "")
    input = Keyword.get(opts, :input)
    request_id = Keyword.get(opts, :request_id, generate_request_id())

    input_payload = if input, do: Temporalex.Converter.encode(input), else: nil

    Temporalex.Native.signal_workflow(
      client,
      namespace,
      workflow_id,
      run_id,
      signal_name,
      input_payload,
      request_id,
      self()
    )

    receive do
      {:signal_workflow_result, result} -> result
    after
      30_000 -> {:error, :timeout}
    end
  end

  @doc """
  Query a workflow's state.

  ## Options (required)
  - `:workflow_id` — target workflow ID
  - `:query_type` — query name

  ## Options (optional)
  - `:args` — query arguments
  - `:run_id` — specific run ID
  """
  def query_workflow(client, namespace, opts) do
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    query_type = Keyword.fetch!(opts, :query_type)
    run_id = Keyword.get(opts, :run_id, "")
    args = Keyword.get(opts, :args)

    args_payload = if args, do: Temporalex.Converter.encode(args), else: nil

    Temporalex.Native.query_workflow(
      client,
      namespace,
      workflow_id,
      run_id,
      query_type,
      args_payload,
      self()
    )

    receive do
      {:query_workflow_result, {:ok, payload_bytes}} ->
        {:ok,
         Temporalex.Converter.decode(%{
           metadata: %{"encoding" => "binary/etf"},
           data: payload_bytes
         })}

      {:query_workflow_result, {:error, _} = err} ->
        err
    after
      30_000 -> {:error, :timeout}
    end
  end

  @doc """
  Cancel a running workflow.

  ## Options (required)
  - `:workflow_id` — target workflow ID

  ## Options (optional)
  - `:run_id` — specific run ID
  - `:reason` — cancellation reason
  """
  def cancel_workflow(client, namespace, opts) do
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    run_id = Keyword.get(opts, :run_id, "")
    reason = Keyword.get(opts, :reason, "")
    request_id = Keyword.get(opts, :request_id, generate_request_id())

    Temporalex.Native.cancel_workflow(
      client,
      namespace,
      workflow_id,
      run_id,
      reason,
      request_id,
      self()
    )

    receive do
      {:cancel_workflow_result, result} -> result
    after
      30_000 -> {:error, :timeout}
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
