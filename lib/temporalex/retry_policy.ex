defmodule Temporalex.RetryPolicy do
  @moduledoc """
  Retry policy configuration for Temporal activities and workflows.

  Wraps `Temporal.Api.Common.V1.RetryPolicy` with sensible defaults.
  All interval fields are in milliseconds.
  """

  @type t :: %__MODULE__{
          max_attempts: non_neg_integer(),
          initial_interval: pos_integer(),
          backoff_coefficient: float(),
          maximum_interval: pos_integer() | nil,
          non_retryable_error_types: [String.t()]
        }

  @enforce_keys []
  defstruct max_attempts: 0,
            initial_interval: 1_000,
            backoff_coefficient: 2.0,
            maximum_interval: nil,
            non_retryable_error_types: []

  @doc "Build a RetryPolicy from a keyword list."
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    struct!(__MODULE__, opts)
  end

  @doc "Normalize either a keyword list or an existing struct into a RetryPolicy."
  @spec from_opts(t() | keyword()) :: t()
  def from_opts(%__MODULE__{} = policy), do: policy
  def from_opts(opts) when is_list(opts), do: new(opts)

  @doc "Convert to a `Temporal.Api.Common.V1.RetryPolicy` proto struct."
  @spec to_proto(t()) :: Temporal.Api.Common.V1.RetryPolicy.t()
  def to_proto(%__MODULE__{} = p) do
    %Temporal.Api.Common.V1.RetryPolicy{
      maximum_attempts: p.max_attempts,
      initial_interval: ms_to_duration(p.initial_interval),
      backoff_coefficient: p.backoff_coefficient,
      maximum_interval: if(p.maximum_interval, do: ms_to_duration(p.maximum_interval)),
      non_retryable_error_types: p.non_retryable_error_types
    }
  end

  # Convert milliseconds to a Google.Protobuf.Duration.
  @spec ms_to_duration(pos_integer()) :: Google.Protobuf.Duration.t()
  defp ms_to_duration(ms) do
    %Google.Protobuf.Duration{
      seconds: div(ms, 1000),
      nanos: rem(ms, 1000) * 1_000_000
    }
  end
end
