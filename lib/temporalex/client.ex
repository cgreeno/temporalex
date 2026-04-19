defmodule Temporalex.Client do
  @moduledoc """
  Client for interacting with workflows on a Temporal server.

  Provides start, signal, query, cancel, and terminate operations.
  Requires a `Temporalex.Connection` (GenServer name or pid) or
  a map with `:client` and `:namespace` keys.

  ## Examples

      # Start a workflow
      {:ok, handle} = Temporalex.Client.start_workflow(conn,
        MyApp.Workflows.Greeting,
        ["world"],
        id: "greeting-1",
        task_queue: "my-queue"
      )

      # Signal a running workflow
      :ok = Temporalex.Client.signal_workflow(conn, "greeting-1", "my_signal", %{key: "value"})

      # Query workflow state
      {:ok, result} = Temporalex.Client.query_workflow(conn, "greeting-1", "get_status")

      # Cancel a workflow
      :ok = Temporalex.Client.cancel_workflow(conn, "greeting-1")
  """
  require Logger

  alias Temporal.Api.Common.V1.Payloads
  alias Temporalex.Converter

  @default_timeout 10_000

  @type workflow_handle :: %{workflow_id: String.t(), run_id: String.t()}

  @doc """
  Start a workflow execution.

  This is the Elixir equivalent of `ExecuteWorkflow` (Go), `execute_workflow` (Python),
  and `client.workflow.start` (TypeScript). Named `start_workflow` to follow Elixir
  conventions (`start_link`, `start_child`).

  Returns `{:ok, handle}` where handle contains `workflow_id` and `run_id`.

  `args` is the workflow input — pass a single value (map, string, number)
  or a list for multiple positional arguments. The workflow's `run/1` callback
  receives the decoded value directly (single arg) or as a list (multiple args).

  ## Examples

      # Single argument — workflow receives %{"name" => "World"}
      start_workflow(conn, MyWorkflow, %{name: "World"}, id: "wf-1", task_queue: "q")

      # No arguments — workflow receives nil
      start_workflow(conn, MyWorkflow, nil, id: "wf-1", task_queue: "q")

  ## Options
    * `:id` — workflow ID (required)
    * `:task_queue` — task queue name (required)
    * `:timeout` — NIF call timeout in ms (default: #{@default_timeout})
  """
  @spec start_workflow(atom() | pid() | map(), module(), term(), keyword()) ::
          {:ok, workflow_handle()} | {:error, term()}
  def start_workflow(conn, workflow_module, args \\ nil, opts \\ [])

  def start_workflow(conn, workflow_module, args, opts) do
    # Guard against keyword-list args being confused with options.
    # If args looks like a keyword list and opts is empty, it's almost
    # certainly a misuse like: start_workflow(conn, Mod, id: "x", task_queue: "q")
    if is_list(args) and args != [] and Keyword.keyword?(args) and opts == [] do
      raise ArgumentError,
            "start_workflow/4 received a keyword list as args with no opts. " <>
              "If these are options, pass args explicitly: " <>
              "start_workflow(conn, module, nil, #{inspect(args)})"
    end

    args_list =
      case args do
        nil -> []
        list when is_list(list) -> list
        single -> [single]
      end

    start_workflow_impl(conn, workflow_module, args_list, opts)
  end

  defp start_workflow_impl(conn, workflow_module, args, opts) do
    workflow_id = Keyword.get_lazy(opts, :id, fn -> generate_workflow_id(workflow_module) end)

    task_queue =
      Keyword.get_lazy(opts, :task_queue, fn ->
        if function_exported?(workflow_module, :__workflow_defaults__, 0),
          do: Keyword.get(workflow_module.__workflow_defaults__(), :task_queue),
          else: nil
      end) || raise ArgumentError, "task_queue is required (set on module or pass as option)"

    timeout = Keyword.get(opts, :timeout, @default_timeout)

    workflow_type = workflow_module.__workflow_type__()

    Logger.info("Client.start_workflow",
      workflow_id: workflow_id,
      workflow_type: workflow_type,
      task_queue: task_queue,
      args_count: length(args)
    )

    with {:ok, client, namespace} <- resolve_connection(conn) do
      input_bytes = encode_args(args)
      request_id = generate_request_id()
      request_ref = request_ref()
      native = native_module()

      :ok =
        native.start_workflow(
          client,
          {namespace, workflow_id, workflow_type, task_queue, input_bytes, request_id,
           request_ref},
          self()
        )

      receive do
        {:start_workflow_result, ^request_ref, {:ok, run_id}} ->
          Logger.info("Client.start_workflow succeeded",
            workflow_id: workflow_id,
            run_id: run_id
          )

          {:ok, %Temporalex.WorkflowHandle{workflow_id: workflow_id, run_id: run_id, conn: conn}}

        {:start_workflow_result, ^request_ref, {:error, reason}} ->
          Logger.error("Client.start_workflow failed",
            workflow_id: workflow_id,
            error: reason
          )

          {:error, reason}
      after
        timeout ->
          Logger.error("Client.start_workflow timed out",
            workflow_id: workflow_id,
            timeout: timeout
          )

          {:error, :timeout}
      end
    end
  end

  @doc """
  Wait for a workflow to complete and return its result.

  Blocks until the workflow reaches a terminal state (completed, failed,
  cancelled, terminated, or timed out).

  Accepts either a workflow handle (from `start_workflow`) or a connection
  + workflow_id.

  ## Examples

      {:ok, handle} = start_workflow(conn, MyWorkflow, args, id: "wf-1", task_queue: "q")
      {:ok, result} = get_result(conn, handle)

      # Or by workflow ID
      {:ok, result} = get_result(conn, "wf-1")

  ## Options
    * `:run_id` — target a specific run (default: from handle or "")
    * `:timeout` — maximum wait time in ms (default: 60_000)
  """
  # get_result(handle) — handle carries its own connection
  def get_result(%Temporalex.WorkflowHandle{} = handle) do
    get_result_impl(handle.conn, handle.workflow_id, run_id: handle.run_id)
  end

  # get_result(handle, opts) or get_result(conn, handle_or_id)
  def get_result(%Temporalex.WorkflowHandle{} = handle, opts) when is_list(opts) do
    get_result_impl(
      handle.conn,
      handle.workflow_id,
      Keyword.put_new(opts, :run_id, handle.run_id)
    )
  end

  def get_result(conn, handle_or_id) do
    get_result(conn, handle_or_id, [])
  end

  # get_result(conn, handle_or_id, opts) — explicit connection
  def get_result(conn, %{workflow_id: wf_id, run_id: run_id}, opts) do
    get_result_impl(conn, wf_id, Keyword.put_new(opts, :run_id, run_id))
  end

  def get_result(conn, workflow_id, opts) when is_binary(workflow_id) do
    get_result_impl(conn, workflow_id, opts)
  end

  defp get_result_impl(conn, workflow_id, opts) do
    run_id = Keyword.get(opts, :run_id, "")
    timeout = Keyword.get(opts, :timeout, 60_000)

    Logger.info("Client.get_result", workflow_id: workflow_id, run_id: run_id)

    with {:ok, client, namespace} <- resolve_connection(conn) do
      request_ref = request_ref()
      native = native_module()

      :ok =
        native.get_workflow_result(
          client,
          {namespace, workflow_id, run_id, request_ref},
          self()
        )

      receive do
        {:get_result_result, ^request_ref, {:ok, result_bytes}} ->
          case decode_query_result(result_bytes) do
            {:ok, result} ->
              Logger.info("Client.get_result succeeded", workflow_id: workflow_id)
              {:ok, result}

            {:error, reason} ->
              {:error, {:decode_error, reason}}
          end

        {:get_result_result, ^request_ref, {:error, reason}} ->
          Logger.error("Client.get_result failed",
            workflow_id: workflow_id,
            error: reason
          )

          {:error, reason}
      after
        timeout ->
          Logger.error("Client.get_result timed out",
            workflow_id: workflow_id,
            timeout: timeout
          )

          {:error, :timeout}
      end
    end
  end

  @doc """
  Signal a running workflow.

  ## Options
    * `:run_id` — target a specific run (default: current run)
    * `:timeout` — NIF call timeout in ms (default: #{@default_timeout})
  """
  @spec signal_workflow(atom() | pid() | map(), String.t(), String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def signal_workflow(conn, workflow_id, signal_name, args \\ nil, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "")
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Logger.info("Client.signal_workflow",
      workflow_id: workflow_id,
      signal_name: signal_name,
      run_id: run_id
    )

    with {:ok, client, namespace} <- resolve_connection(conn) do
      input_bytes = encode_signal_args(args)
      request_id = generate_request_id()
      request_ref = request_ref()
      native = native_module()

      :ok =
        native.signal_workflow(
          client,
          {namespace, workflow_id, run_id, signal_name, input_bytes, request_id, request_ref},
          self()
        )

      receive do
        {:signal_workflow_result, ^request_ref, :ok} ->
          Logger.info("Client.signal_workflow succeeded",
            workflow_id: workflow_id,
            signal_name: signal_name
          )

          :ok

        {:signal_workflow_result, ^request_ref, {:error, reason}} ->
          Logger.error("Client.signal_workflow failed",
            workflow_id: workflow_id,
            signal_name: signal_name,
            error: reason
          )

          {:error, reason}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  @doc """
  Query a workflow's state.

  Returns `{:ok, result}` with the decoded query result.

  ## Options
    * `:run_id` — target a specific run (default: current run)
    * `:timeout` — NIF call timeout in ms (default: #{@default_timeout})
  """
  @spec query_workflow(atom() | pid() | map(), String.t(), String.t(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def query_workflow(conn, workflow_id, query_type, args \\ nil, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "")
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Logger.info("Client.query_workflow",
      workflow_id: workflow_id,
      query_type: query_type,
      run_id: run_id
    )

    with {:ok, client, namespace} <- resolve_connection(conn) do
      query_args_bytes = encode_signal_args(args)
      request_ref = request_ref()
      native = native_module()

      :ok =
        native.query_workflow(
          client,
          {namespace, workflow_id, run_id, query_type, query_args_bytes, request_ref},
          self()
        )

      receive do
        {:query_workflow_result, ^request_ref, {:ok, result_bytes}} ->
          case decode_query_result(result_bytes) do
            {:ok, result} ->
              Logger.info("Client.query_workflow succeeded",
                workflow_id: workflow_id,
                query_type: query_type
              )

              {:ok, result}

            {:error, reason} ->
              {:error, {:decode_error, reason}}
          end

        {:query_workflow_result, ^request_ref, {:error, reason}} ->
          Logger.error("Client.query_workflow failed",
            workflow_id: workflow_id,
            query_type: query_type,
            error: reason
          )

          {:error, reason}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  @doc """
  Request cancellation of a workflow.

  ## Options
    * `:run_id` — target a specific run (default: current run)
    * `:reason` — cancellation reason (default: "")
    * `:timeout` — NIF call timeout in ms (default: #{@default_timeout})
  """
  @spec cancel_workflow(atom() | pid() | map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def cancel_workflow(conn, workflow_id, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "")
    reason = Keyword.get(opts, :reason, "")
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Logger.info("Client.cancel_workflow",
      workflow_id: workflow_id,
      run_id: run_id,
      reason: reason
    )

    with {:ok, client, namespace} <- resolve_connection(conn) do
      request_id = generate_request_id()
      request_ref = request_ref()
      native = native_module()

      :ok =
        native.cancel_workflow(
          client,
          {namespace, workflow_id, run_id, reason, request_id, request_ref},
          self()
        )

      receive do
        {:cancel_workflow_result, ^request_ref, :ok} ->
          Logger.info("Client.cancel_workflow succeeded", workflow_id: workflow_id)
          :ok

        {:cancel_workflow_result, ^request_ref, {:error, reason}} ->
          Logger.error("Client.cancel_workflow failed",
            workflow_id: workflow_id,
            error: reason
          )

          {:error, reason}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  @doc """
  Terminate a workflow immediately (non-graceful).

  ## Options
    * `:run_id` — target a specific run (default: current run)
    * `:reason` — termination reason (default: "")
    * `:timeout` — NIF call timeout in ms (default: #{@default_timeout})
  """
  @spec terminate_workflow(atom() | pid() | map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def terminate_workflow(conn, workflow_id, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "")
    reason = Keyword.get(opts, :reason, "")
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Logger.info("Client.terminate_workflow",
      workflow_id: workflow_id,
      run_id: run_id,
      reason: reason
    )

    with {:ok, client, namespace} <- resolve_connection(conn) do
      request_ref = request_ref()
      native = native_module()

      :ok =
        native.terminate_workflow(
          client,
          {namespace, workflow_id, run_id, reason, request_ref},
          self()
        )

      receive do
        {:terminate_workflow_result, ^request_ref, :ok} ->
          Logger.info("Client.terminate_workflow succeeded", workflow_id: workflow_id)
          :ok

        {:terminate_workflow_result, ^request_ref, {:error, reason}} ->
          Logger.error("Client.terminate_workflow failed",
            workflow_id: workflow_id,
            error: reason
          )

          {:error, reason}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  @doc """
  Describe a workflow execution.

  Returns `{:ok, info}` where `info` is a map with string keys:
  `"workflow_id"`, `"run_id"`, `"workflow_type"`, `"status"`,
  `"history_length"`, `"start_time"`, `"task_queue"`, etc.

  ## Options
    * `:run_id` — target a specific run (default: latest)
    * `:timeout` — NIF call timeout in ms (default: #{@default_timeout})
  """
  @spec describe_workflow(atom() | pid() | map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def describe_workflow(conn, workflow_id, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "")
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, client, namespace} <- resolve_connection(conn) do
      request_ref = request_ref()
      native = native_module()

      :ok =
        native.describe_workflow(client, {namespace, workflow_id, run_id, request_ref}, self())

      receive do
        {:describe_workflow_result, ^request_ref, {:ok, info}} -> {:ok, info}
        {:describe_workflow_result, ^request_ref, {:error, reason}} -> {:error, reason}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  @doc """
  List workflow executions matching a query.

  Uses Temporal's visibility query language. Returns `{:ok, [info]}` where
  each `info` is a map with `"workflow_id"`, `"run_id"`, `"workflow_type"`, `"status"`.

  ## Examples

      # All running workflows
      list_workflows(conn, ~s(ExecutionStatus = "Running"))

      # Specific workflow type
      list_workflows(conn, ~s(WorkflowType = "ProcessOrder"))

  ## Options
    * `:page_size` — max results per page (default: 100)
    * `:timeout` — NIF call timeout in ms (default: #{@default_timeout})
  """
  @spec list_workflows(atom() | pid() | map(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_workflows(conn, query, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 100)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, client, namespace} <- resolve_connection(conn) do
      request_ref = request_ref()
      native = native_module()

      :ok = native.list_workflows(client, {namespace, query, page_size, request_ref}, self())

      receive do
        {:list_workflows_result, ^request_ref, {:ok, executions}} -> {:ok, executions}
        {:list_workflows_result, ^request_ref, {:error, reason}} -> {:error, reason}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  # --- Private helpers ---

  # Resolve connection to {client_resource, namespace}
  # Accepts: Connection name, Temporalex instance name, pid, or map
  defp resolve_connection(conn) when is_pid(conn) do
    case Temporalex.Connection.get(conn) do
      {:ok, %{client: client, namespace: namespace}} ->
        {:ok, client, namespace}

      {:error, reason} ->
        Logger.error("Client: failed to resolve connection PID", error: inspect(reason))
        {:error, {:connection_error, reason}}
    end
  catch
    :exit, reason ->
      Logger.error("Client: connection process unavailable", error: inspect(reason))
      {:error, {:connection_error, :not_alive}}
  end

  defp resolve_connection(conn) when is_atom(conn) do
    case Temporalex.Connection.get(conn) do
      {:ok, %{client: client, namespace: namespace}} ->
        {:ok, client, namespace}

      {:error, _} ->
        # Maybe it's an instance name — try derived connection name
        derived = Temporalex.connection_name(conn)

        case Temporalex.Connection.get(derived) do
          {:ok, %{client: client, namespace: namespace}} ->
            {:ok, client, namespace}

          {:error, reason} ->
            Logger.error("Client: failed to resolve connection", error: inspect(reason))
            {:error, {:connection_error, reason}}
        end
    end
  catch
    :exit, reason ->
      Logger.error("Client: connection process unavailable", error: inspect(reason))
      {:error, {:connection_error, :not_alive}}
  end

  defp resolve_connection(%{client: client, namespace: namespace}) do
    {:ok, client, namespace}
  end

  defp native_module do
    Application.get_env(:temporalex, :native_module, Temporalex.Native)
  end

  defp request_ref do
    System.unique_integer([:positive, :monotonic])
  end

  # Encode workflow arguments to protobuf Payloads bytes
  defp encode_args([]), do: <<>>

  defp encode_args(args) when is_list(args) do
    payloads = Converter.to_payloads(args)
    Protobuf.encode(%Payloads{payloads: payloads})
  end

  # Encode signal/query args (single value) to protobuf Payloads bytes
  defp encode_signal_args(nil), do: <<>>

  defp encode_signal_args(value) do
    payload = Converter.to_payload(value)
    Protobuf.encode(%Payloads{payloads: [payload]})
  end

  # Decode query result bytes back to Elixir term
  defp decode_query_result(<<>>), do: {:ok, nil}

  defp decode_query_result(bytes) when is_binary(bytes) do
    case Payloads.decode(bytes) do
      %Payloads{payloads: [first | _]} ->
        Converter.from_payload(first)

      %Payloads{payloads: []} ->
        {:ok, nil}

      _ ->
        {:error, "unexpected payload format in query result"}
    end
  end

  defp generate_workflow_id(workflow_module) do
    short_name =
      workflow_module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.replace("/", "-")

    "#{short_name}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp generate_request_id do
    import Bitwise
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format(
      "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c &&& 0x0FFF, (d &&& 0x3FFF) ||| 0x8000, e]
    )
    |> IO.iodata_to_binary()
  end
end
