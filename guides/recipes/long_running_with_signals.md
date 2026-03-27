# Recipe: Long-Running Workflows with Signals

## The Problem

You have a business process that waits for human input — an approval flow, a document review, or an order that needs manual confirmation before shipping. The workflow might wait for hours or days.

## The Implementation

```elixir
defmodule MyApp.Workflows.LoanApproval do
  use Temporalex.Workflow

  def run(%{"application_id" => app_id, "amount" => amount}) do
    # Step 1: Auto-checks
    set_state(%{status: "checking", application_id: app_id})
    {:ok, score} = execute_activity(MyApp.Activities.CreditCheck, %{application_id: app_id})

    if score > 700 and amount < 10_000 do
      # Auto-approve small loans with good credit
      {:ok, _} = execute_activity(MyApp.Activities.ApproveLoan, %{application_id: app_id})
      {:ok, %{status: "auto_approved", score: score}}
    else
      # Step 2: Wait for human review
      set_state(%{status: "pending_review", score: score, amount: amount})

      {:ok, decision} = wait_for_signal("review_decision")

      case decision do
        %{"approved" => true, "reviewer" => reviewer} ->
          set_state(%{status: "approved", reviewer: reviewer})
          {:ok, _} = execute_activity(MyApp.Activities.ApproveLoan, %{application_id: app_id})
          {:ok, %{status: "approved", reviewer: reviewer}}

        %{"approved" => false, "reason" => reason} ->
          set_state(%{status: "denied", reason: reason})
          {:ok, _} = execute_activity(MyApp.Activities.DenyLoan, %{
            application_id: app_id,
            reason: reason
          })
          {:ok, %{status: "denied", reason: reason}}
      end
    end
  end

  @impl Temporalex.Workflow
  def handle_query("status", _args, state) do
    {:reply, state}
  end
end
```

## Starting the Workflow

```elixir
{:ok, handle} = Temporalex.Client.start_workflow(conn,
  MyApp.Workflows.LoanApproval,
  %{application_id: "APP-001", amount: 50_000},
  id: "loan-APP-001",
  task_queue: "loans"
)
```

## Checking Status (from your UI)

```elixir
{:ok, status} = Temporalex.Client.query_workflow(conn, "loan-APP-001", "status")
# => %{status: "pending_review", score: 680, amount: 50000}
```

## Completing the Review (from your admin panel)

```elixir
Temporalex.Client.signal_workflow(conn, "loan-APP-001", "review_decision", %{
  approved: true,
  reviewer: "alice@bank.com"
})
```

The workflow wakes up, processes the approval, and completes.

## Adding a Timeout

Don't wait forever. Add a timeout by racing the signal against a timer:

```elixir
def run(%{"application_id" => app_id}) do
  # ... credit check ...

  set_state(%{status: "pending_review"})

  # Wait up to 7 days for review
  task = Task.async(fn -> wait_for_signal("review_decision") end)
  sleep(:timer.hours(24 * 7))

  # If we get here, the timer fired first
  {:ok, _} = execute_activity(MyApp.Activities.EscalateReview, %{application_id: app_id})
  {:ok, %{status: "escalated"}}
end
```

## Testing It

```elixir
test "auto-approves good credit small loans" do
  result = run_workflow(MyApp.Workflows.LoanApproval,
    %{"application_id" => "APP-1", "amount" => 5_000},
    activities: %{
      MyApp.Activities.CreditCheck => fn _ -> {:ok, 750} end,
      MyApp.Activities.ApproveLoan => fn _ -> {:ok, "approved"} end
    }
  )

  assert {:ok, %{status: "auto_approved"}} = result
end

test "waits for manual review on large loans" do
  result = run_workflow(MyApp.Workflows.LoanApproval,
    %{"application_id" => "APP-2", "amount" => 50_000},
    activities: %{
      MyApp.Activities.CreditCheck => fn _ -> {:ok, 680} end,
      MyApp.Activities.ApproveLoan => fn _ -> {:ok, "approved"} end
    },
    signals: [{"review_decision", %{"approved" => true, "reviewer" => "bob"}}]
  )

  assert {:ok, %{status: "approved", reviewer: "bob"}} = result
end
```
