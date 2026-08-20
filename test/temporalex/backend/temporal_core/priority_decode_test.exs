defmodule Temporalex.Backend.TemporalCore.PriorityDecodeTest do
  @moduledoc """
  That our history decoder surfaces a recorded `priority`.

  This exists to keep the canary in
  `test/temporalex/integration/priority_test.exs` honest. That canary asserts
  the server does *not* record priority, by observing that the
  WorkflowExecutionStarted event carries none — and a test of the form "the
  field is absent" passes just as happily when the observer is blind as when
  the field is genuinely missing.

  So this pins the observer: given a started event that *does* carry
  priority, our decode path must show it. With this passing, absence
  downstream is the server's answer, not ours.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Backend.TemporalCore.Codec
  alias Temporalex.Backend.TemporalCore.Proto.Schema

  @history :"temporal.api.history.v1.History"

  test "a started event's priority survives the decode path intact" do
    priority = %{priority_key: 2, fairness_key: "salon-4291", fairness_weight: 2.5}

    {:ok, bytes} =
      Schema.encode(
        %{
          events: [
            %{
              event_id: 1,
              attributes:
                {:workflow_execution_started_event_attributes,
                 %{workflow_type: "Probe", task_queue: %{name: "q"}, priority: priority}}
            }
          ]
        },
        @history
      )

    assert {:ok, [event]} = Codec.history_from_bytes(bytes)
    assert event.type == :workflow_execution_started

    assert Map.get(event.attributes, :priority) == priority,
           """
           the decoder dropped priority, which silently disarms the server-support
           canary in test/temporalex/integration/priority_test.exs — that canary
           would then pass by blindness. Most likely cause: priv/proto/temporal_core.binpb
           was regenerated from a proto tree without WorkflowExecutionStartedEventAttributes
           field 35.
           """
  end

  test "no priority on the wire decodes to no priority, not a zeroed one" do
    # The distinction the canary depends on: an unset submessage must come back
    # absent. If defaults ever start materialising `%{priority_key: 0}` here,
    # the canary's "is it nil" check stops meaning "the server said nothing".
    {:ok, bytes} =
      Schema.encode(
        %{
          events: [
            %{
              event_id: 1,
              attributes:
                {:workflow_execution_started_event_attributes,
                 %{workflow_type: "Probe", task_queue: %{name: "q"}}}
            }
          ]
        },
        @history
      )

    assert {:ok, [event]} = Codec.history_from_bytes(bytes)
    assert Map.get(event.attributes, :priority) == nil
  end
end
