defmodule Temporalex.TestSupport.Namespace do
  @moduledoc false

  # External tests share one Temporal dev server, and several declare a FIXED
  # task queue (`use Temporalex.Workflow, queue: "surface-greet"` and friends)
  # that cannot be made unique per run: `use` options are evaluated at compile
  # time, so two runs of one build share the string, and RFC 0002's one-source
  # rule forbids a worker overriding a declared queue.
  #
  # Task queues are namespace-scoped, so the isolation goes one level up: each
  # run gets its own namespace, and identical queue names in different
  # namespaces never meet. Concurrent runs then cost nothing rather than
  # stealing each other's workflow tasks.

  @key {__MODULE__, :namespace}
  @fallback "default"

  @doc "The namespace for this run — set up once by test_helper.exs."
  def name, do: :persistent_term.get(@key, @fallback)

  @doc """
  Creates a namespace for this run and waits until it is usable.

  Falls back to `"default"` with a warning when the `temporal` CLI is absent:
  a lone developer without it should not be blocked, they just lose isolation
  (and so must not run two external suites at once).
  """
  def setup! do
    case System.find_executable("temporal") do
      nil ->
        warn_no_cli()
        @fallback

      cli ->
        namespace = "temporalex-test-#{System.system_time(:millisecond)}-#{System.pid()}"

        case create(cli, namespace) do
          :ok ->
            :persistent_term.put(@key, namespace)
            namespace

          {:error, output} ->
            IO.warn("""
            could not create the per-run test namespace #{namespace}, falling \
            back to #{@fallback}:

            #{output}
            """)

            @fallback
        end
    end
  end

  @doc """
  Creates an additional namespace and waits until it is usable.

  For tests that need a second namespace of their own — proving that identical
  task-queue names in different namespaces cannot reach each other.
  """
  def create!(namespace) do
    cli = System.find_executable("temporal") || raise "the `temporal` CLI is required"

    case create(cli, namespace) do
      :ok -> namespace
      {:error, output} -> raise "could not create namespace #{namespace}: #{output}"
    end
  end

  defp create(cli, namespace) do
    with {_out, 0} <-
           System.cmd(
             cli,
             ["operator", "namespace", "create", "--namespace", namespace] ++
               Temporalex.TestSupport.Server.cli_address_args(),
             stderr_to_stdout: true
           ),
         :ok <- await_usable(cli, namespace) do
      :ok
    else
      # Specific first: {output, status} would otherwise swallow {:error, _},
      # since both are two-tuples.
      {:error, _} = error -> error
      {output, _status} -> {:error, output}
    end
  end

  # A freshly registered namespace is not immediately usable — the server
  # caches its namespace registry — so poll rather than assume. This mirrors
  # the wait loop CI already runs for "default" before the suite starts.
  defp await_usable(cli, namespace, attempts \\ 30)

  defp await_usable(_cli, namespace, 0),
    do: {:error, "namespace #{namespace} never became usable"}

  defp await_usable(cli, namespace, attempts) do
    case System.cmd(
           cli,
           ["operator", "namespace", "describe", "--namespace", namespace] ++
             Temporalex.TestSupport.Server.cli_address_args(),
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      _ ->
        Process.sleep(500)
        await_usable(cli, namespace, attempts - 1)
    end
  end

  defp warn_no_cli do
    IO.warn("""
    the `temporal` CLI was not found, so external tests will run in the \
    #{@fallback} namespace without per-run isolation.

    Install it (https://temporal.io/setup/install-temporal-cli) or do not run \
    two external suites concurrently: several tests declare fixed task queues, \
    so concurrent runs in one namespace steal each other's workflow tasks and \
    produce failures that do not reproduce.
    """)
  end
end
