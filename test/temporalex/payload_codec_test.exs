defmodule Temporalex.PayloadCodecTest do
  use ExUnit.Case, async: false

  alias Temporalex.Backend.TemporalCore.Codec
  alias Temporalex.Backend.TemporalCore.PayloadConverter
  alias Temporalex.Backend.TemporalCore.Proto.Schema
  alias Temporalex.Backend.Test, as: TestBackend
  alias Temporalex.Core.Activation
  alias Temporalex.Core.ActivityCompletion
  alias Temporalex.Core.Completion
  alias Temporalex.Core.Job
  alias Temporalex.Failure.ApplicationError

  defmodule JsonEncodingBackend do
    alias Temporalex.Backend.TemporalCore.Codec
    alias Temporalex.Backend.Test, as: TestBackend

    defdelegate start_client(opts, owner_pid), to: TestBackend
    defdelegate shutdown_client(state), to: TestBackend
    defdelegate start_worker(client_state, opts, owner_pid), to: TestBackend
    defdelegate shutdown_worker(state), to: TestBackend
    defdelegate record_activity_heartbeat(state, task_token, details), to: TestBackend

    def complete_workflow_activation(state, completion) do
      with {:ok, _bytes} <-
             Codec.workflow_completion_to_bytes(completion, task_queue: "q", payload_codec: :json) do
        TestBackend.complete_workflow_activation(state, completion)
      end
    end

    def complete_activity_task(state, completion) do
      with {:ok, _bytes} <- Codec.activity_completion_to_bytes(completion, payload_codec: :json) do
        TestBackend.complete_activity_task(state, completion)
      end
    end
  end

  defmodule Activities do
    use Temporalex.Activity

    defactivity(tagged(value), do: {:ok, {:tagged, value}})
  end

  defmodule TupleResultWorkflow do
    use Temporalex.Workflow

    def run(value), do: {:ok, {:tagged, value}}
  end

  defmodule MapResultWorkflow do
    use Temporalex.Workflow

    def run(value), do: {:ok, %{"value" => value}}
  end

  describe "decoding" do
    test "a :json codec refuses an ETF payload instead of decoding it" do
      payload = etf_payload(%{amount: 1})

      assert {:error, "refusing an ETF payload: payload_codec is :json, which never decodes ETF"} =
               PayloadConverter.with_codec(:json, fn ->
                 PayloadConverter.payload_to_term(payload)
               end)
    end

    test "ETF decoding refuses an atom this node has never seen, and does not create it" do
      name = "temporalex_unseen_#{System.unique_integer([:positive])}"

      payload = %{
        metadata: %{"encoding" => "binary/erlang-eterm"},
        data: <<131, 119, byte_size(name), name::binary>>
      }

      assert {:error, "payload is not ETF encoded, or names an atom this node does not know"} =
               PayloadConverter.with_codec(:etf, fn ->
                 PayloadConverter.payload_to_term(payload)
               end)

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "ETF decoding keeps structs, which is why :etf is only for trusted namespaces" do
      uri = URI.parse("https://example.com")

      assert {:ok, ^uri} =
               PayloadConverter.with_codec(:etf, fn ->
                 PayloadConverter.payload_to_term(etf_payload(uri))
               end)
    end

    test "an encoding temporalex never writes is refused by name under either codec" do
      payload = %{metadata: %{"encoding" => "json/protobuf"}, data: "{}"}

      for codec <- [:etf, :json] do
        assert {:error, ~s(unsupported payload encoding "json/protobuf")} =
                 PayloadConverter.with_codec(codec, fn ->
                   PayloadConverter.payload_to_term(payload)
                 end)
      end
    end

    test "an activation carrying an ETF payload does not decode on a :json worker" do
      {:ok, bytes} =
        Schema.encode(
          %{
            run_id: "run-1",
            jobs: [
              %{variant: {:signal_workflow, %{signal_name: "go", input: [etf_payload(:go)]}}}
            ]
          },
          :"coresdk.workflow_activation.WorkflowActivation"
        )

      assert {:error, "refusing an ETF payload" <> _} =
               Codec.workflow_activation_from_bytes(bytes)

      assert {:ok, %Activation{jobs: [%Job.SignalReceived{name: "go", args: [:go]}]}} =
               Codec.workflow_activation_from_bytes(bytes, payload_codec: :etf)
    end
  end

  describe "encoding" do
    test ":json refuses a tuple rather than falling back to ETF" do
      assert {:error, {:payload_conversion, "payload_codec :json cannot encode {:a, 1}"}} =
               PayloadConverter.with_codec(:json, fn ->
                 {:ok, PayloadConverter.term_to_payload({:a, 1})}
               end)
    end

    test ":json refuses a map key JSON has no form for, without raising" do
      assert {:error, {:payload_conversion, "payload_codec :json cannot encode {1}"}} =
               PayloadConverter.with_codec(:json, fn ->
                 {:ok, PayloadConverter.term_to_payload(%{{1} => 2})}
               end)
    end

    test "failure details the SDK adds always encode under :json, as their inspect string" do
      payload =
        PayloadConverter.with_codec(:json, fn ->
          PayloadConverter.failure_detail_payload({:executor_exit, :boom})
        end)

      assert {:ok, "{:executor_exit, :boom}"} =
               PayloadConverter.with_codec(:json, fn ->
                 PayloadConverter.payload_to_term(payload)
               end)
    end
  end

  describe "a value :json cannot encode, on a worker" do
    setup do
      name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
      client = Module.concat(__MODULE__, :"Client#{System.unique_integer([:positive])}")

      start_supervised!({Temporalex.Client, name: client, backend: JsonEncodingBackend})

      start_supervised!(
        {Temporalex.Worker,
         name: name,
         client: client,
         backend: JsonEncodingBackend,
         test_owner: self(),
         namespace: Temporalex.TestSupport.Namespace.name(),
         task_queue: "payload-codec-queue",
         workflows: [TupleResultWorkflow, MapResultWorkflow],
         activities: [Activities]}
      )

      %{worker: name}
    end

    test "fails that workflow task, and the worker keeps serving other runs", %{worker: worker} do
      start_run(worker, "run-tuple", TupleResultWorkflow, "x")

      assert %Completion{
               status: {:failed, ~s(payload_codec :json cannot encode {:tagged, "x"}), _opts}
             } = TestBackend.fetch_workflow_completion(worker, "run-tuple")

      start_run(worker, "run-map", MapResultWorkflow, "y")

      assert %Completion{status: {:ok, [_complete]}} =
               TestBackend.fetch_workflow_completion(worker, "run-map")
    end

    test "fails that activity as a non-retryable UnencodableActivityResult", %{worker: worker} do
      :ok =
        TestBackend.send_activity_task(worker, %Temporalex.Core.ActivityTask{
          task_token: "tok-tuple",
          activity_id: "act-1",
          activity_type: "#{inspect(Activities)}.tagged",
          input: ["x"],
          variant: :start
        })

      assert %ActivityCompletion{
               result:
                 {:error,
                  %ApplicationError{
                    type: "UnencodableActivityResult",
                    retryable?: false,
                    message: ~s(payload_codec :json cannot encode {:tagged, "x"})
                  }}
             } = TestBackend.fetch_activity_completion(worker, "tok-tuple")
    end
  end

  defp etf_payload(term),
    do: PayloadConverter.with_codec(:etf, fn -> PayloadConverter.term_to_payload(term) end)

  defp start_run(worker, run_id, workflow_module, input) do
    TestBackend.send_activation(worker, %Activation{
      run_id: run_id,
      timestamp: ~U[2026-11-27 12:00:00Z],
      jobs: [
        %Job.InitializeWorkflow{
          workflow_type: workflow_module.__workflow_type__(),
          workflow_id: "wf-#{run_id}",
          arguments: [input],
          workflow_info: %{},
          randomness_seed: 0
        }
      ]
    })
  end
end
