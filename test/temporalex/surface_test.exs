defmodule Temporalex.SurfaceTest do
  @moduledoc """
  RFC 0002 surface tests that need no Temporal server.

  Builders are inert (P6), so everything up to the terminal verb — id and
  input derivation, chain steps, option validation, the workflow-context
  guard, and worker queue derivation — is assertable on plain data.
  """

  use ExUnit.Case, async: true

  alias Temporalex.Start

  defmodule Booking do
    use Temporalex.Workflow, queue: "bookings"

    defmodule Record do
      defstruct [:id]
    end

    @impl true
    def id(%Record{id: pk}), do: "booking-#{pk}"
    def id(pk) when is_integer(pk), do: "booking-#{pk}"

    @impl true
    def input(%Record{id: pk}), do: pk
    def input(pk), do: pk

    @impl true
    def run(booking_id), do: {:ok, booking_id}
  end

  defmodule Anonymous do
    use Temporalex.Workflow, queue: "anonymous"

    @impl true
    def id(_), do: :generate

    @impl true
    def run(input), do: {:ok, input}
  end

  defmodule NoId do
    use Temporalex.Workflow, queue: "no-id"

    @impl true
    def run(input), do: {:ok, input}
  end

  defmodule Renamed do
    use Temporalex.Workflow, queue: "renamed", name: "booking.v1", client: MyApp.Payments

    @impl true
    def id(pk), do: "renamed-#{pk}"

    @impl true
    def run(input), do: {:ok, input}
  end

  defmodule Legacy do
    use Temporalex.Workflow

    @impl true
    def run(input), do: {:ok, input}
  end

  describe "new/2 — pure data" do
    test "derives id and input from the module, queue and client from use" do
      start = Booking.new(%Booking.Record{id: 42})

      assert %Start{
               workflow: Booking,
               id: "booking-42",
               input: 42,
               queue: "bookings",
               client: nil,
               timeout: nil,
               opts: []
             } = start
    end

    test "id/1 clauses cover every shape callers hold" do
      assert Booking.new(7).id == "booking-7"
      assert Booking.new(%Booking.Record{id: 7}).id == "booking-7"
    end

    test "call-site id: overrides id/1" do
      assert Booking.new(7, id: "override").id == "override"
    end

    # :generate stays a sentinel until the terminal verb, so a reused %Start{}
    # draws a fresh id per start instead of attaching to its first one.
    test "id: :generate stays a sentinel in the built start" do
      assert Booking.new(7, id: :generate).id == :generate
    end

    test "a module opting out via id/1 -> :generate builds the sentinel" do
      assert Anonymous.new(1).id == :generate
    end

    test "no id/1 and no id: raises with instructions" do
      error = assert_raise ArgumentError, fn -> NoId.new(1) end
      assert Exception.message(error) =~ "define id/1 on"
      assert Exception.message(error) =~ "idempotency key"
      assert Exception.message(error) =~ ":generate"
    end

    test "a bad id/1 return raises instructively at new, not at the terminal verb" do
      defmodule BadId do
        use Temporalex.Workflow, queue: "bad-id"
        def id(_), do: 42
        def run(input), do: {:ok, input}
      end

      error = assert_raise ArgumentError, fn -> BadId.new(1) end
      assert Exception.message(error) =~ "must return a String.t() or :generate"
    end

    test "unknown options raise rather than silently doing nothing" do
      error = assert_raise ArgumentError, fn -> Booking.new(7, tiemout: 5_000) end
      assert Exception.message(error) =~ ":tiemout"
    end

    test "use name: and client: land on the module" do
      assert Renamed.__workflow_type__() == "booking.v1"
      assert Renamed.new(1).client == MyApp.Payments
    end
  end

  describe "chain steps — inert transformations" do
    setup do
      {:ok, start: Booking.new(42)}
    end

    test "resolution overrides", %{start: start} do
      start =
        start
        |> Temporalex.id("elsewhere")
        |> Temporalex.queue("other-queue")
        |> Temporalex.client(MyApp.Other)
        |> Temporalex.input(%{richer: true})
        |> Temporalex.timeout(5_000)

      assert %Start{
               id: "elsewhere",
               queue: "other-queue",
               client: MyApp.Other,
               input: %{richer: true},
               timeout: 5_000
             } = start
    end

    test "policy steps accumulate into pass-through options", %{start: start} do
      opts =
        start
        |> Temporalex.retry(max_attempts: 3)
        |> Temporalex.priority(2)
        |> Temporalex.fairness("salon-9", 2.5)
        |> Temporalex.cron("0 9 * * *")
        |> Temporalex.run_timeout(60_000)
        |> Temporalex.execution_timeout(120_000)
        |> Map.fetch!(:opts)

      assert opts[:retry_policy] == [max_attempts: 3]
      assert opts[:priority][:priority_key] == 2
      assert opts[:priority][:fairness_key] == "salon-9"
      assert opts[:priority][:fairness_weight] == 2.5
      assert opts[:cron_schedule] == "0 9 * * *"
      assert opts[:run_timeout] == 60_000
      assert opts[:execution_timeout] == 120_000
    end

    test "index and headers merge with string keys", %{start: start} do
      opts =
        start
        |> Temporalex.index(salon_id: "salon-9")
        |> Temporalex.index(%{"channel" => "web"})
        |> Temporalex.headers(traceparent: "00-abc-1-01")
        |> Map.fetch!(:opts)

      assert opts[:search_attributes] == %{"salon_id" => "salon-9", "channel" => "web"}
      assert opts[:headers] == %{"traceparent" => "00-abc-1-01"}
    end

    test "keyword spellings on new/2 land identically" do
      chained = Booking.new(42) |> Temporalex.retry(max_attempts: 3)
      keyworded = Booking.new(42, retry_policy: [max_attempts: 3])

      assert chained.opts[:retry_policy] == keyworded.opts[:retry_policy]
    end
  end

  describe "the workflow-context guard" do
    setup do
      Process.put(Temporalex.Workflow.API.context_key(), :fake_workflow_context)
      on_exit(fn -> Process.delete(Temporalex.Workflow.API.context_key()) end)
      :ok
    end

    test "every generated running verb refuses inside workflow code" do
      for call <- [
            fn -> Booking.start!(1) end,
            fn -> Booking.start(1) end,
            fn -> Booking.execute!(1) end,
            fn -> Booking.execute(1) end,
            fn -> Booking.signal!(1, "s") end,
            fn -> Booking.signal(1, "s") end,
            fn -> Booking.query!(1, "q") end,
            fn -> Booking.query(1, "q") end
          ] do
        error = assert_raise RuntimeError, call
        assert Exception.message(error) =~ "inside workflow code"
        assert Exception.message(error) =~ "execute_child_workflow"
      end
    end

    test "new/2 stays legal — it is pure data" do
      assert %Start{} = Booking.new(1)
    end

    # The chain form must be refused identically — new |> Temporalex.start!()
    # inside workflow code is the same replay nondeterminism as the short form.
    test "the chain's terminal verbs refuse too" do
      start = Booking.new(1)

      for call <- [
            fn -> Temporalex.start(start) end,
            fn -> Temporalex.start!(start) end,
            fn -> Temporalex.execute(start) end,
            fn -> Temporalex.execute!(start) end
          ] do
        error = assert_raise RuntimeError, call
        assert Exception.message(error) =~ "inside workflow code"
      end
    end

    test "await refuses too" do
      handle = %Temporalex.Client.Handle{client: C, workflow_id: "x", workflow_type: "T"}
      assert_raise RuntimeError, ~r/inside workflow code/, fn -> Temporalex.await(handle) end
    end
  end

  describe "modules without queue:" do
    test "gain no call-side surface" do
      refute function_exported?(Legacy, :new, 2)
      refute function_exported?(Legacy, :start!, 2)
      refute function_exported?(Legacy, :execute!, 2)
    end

    test "still declare their type and a nil queue" do
      assert Legacy.__workflow_type__() == inspect(Legacy)
      assert Legacy.__queue__() == nil
    end
  end

  describe "Worker.resolve!/1 — queue derivation" do
    test "derives the queue and a name from one declared queue" do
      resolved = Temporalex.Worker.resolve!(workflows: [Booking], client: MyClient)

      assert resolved[:task_queue] == "bookings"
      assert resolved[:name] == Module.concat(Temporalex.Worker, "bookings")
      assert resolved[:client] == MyClient
    end

    test "modules without a declaration ride along on the derived queue" do
      resolved = Temporalex.Worker.resolve!(workflows: [Booking, Legacy], name: W)
      assert resolved[:task_queue] == "bookings"
    end

    test "explicit task_queue: wins" do
      resolved = Temporalex.Worker.resolve!(workflows: [Booking], task_queue: "override", name: W)
      assert resolved[:task_queue] == "override"
    end

    test "disagreeing declarations raise, listing the modules" do
      error =
        assert_raise ArgumentError, fn ->
          Temporalex.Worker.resolve!(workflows: [Booking, Anonymous], name: W)
        end

      assert Exception.message(error) =~ "disagree"
      assert Exception.message(error) =~ "Booking"
      assert Exception.message(error) =~ "Anonymous"
    end

    test "no declaration anywhere keeps the legacy fallback and requires a name" do
      resolved = Temporalex.Worker.resolve!(workflows: [Legacy], name: W, client: C)
      refute Keyword.has_key?(resolved, :task_queue)

      assert_raise ArgumentError, ~r/needs a :name/, fn ->
        Temporalex.Worker.resolve!(workflows: [Legacy])
      end
    end

    test "client defaults to the default client" do
      assert Temporalex.Worker.resolve!(workflows: [Booking])[:client] ==
               Temporalex.default_client()
    end
  end

  describe "the silent-drop allowlist (RFC 0002 §10)" do
    test "every Start pass-through option survives the backend allowlist" do
      passthrough = Temporalex.Start.__passthrough_opts__()
      allowlist = Temporalex.Backend.TemporalCore.__native_start_opt_keys__()

      assert passthrough -- allowlist == [],
             "options accepted by the surface but silently dropped by " <>
               "native_start_opts/1: #{inspect(passthrough -- allowlist)} — " <>
               "add them to @native_start_opt_keys or they reach neither the " <>
               "NIF nor an error"
    end
  end

  describe "addressing" do
    test "resolve_address! goes through id/1" do
      assert Start.resolve_address!(Booking, 42) == "booking-42"
      assert Start.resolve_address!(Booking, %Booking.Record{id: 42}) == "booking-42"
    end

    test "a :generate module cannot be addressed by key" do
      error = assert_raise ArgumentError, fn -> Start.resolve_address!(Anonymous, 1) end
      assert Exception.message(error) =~ "cannot be addressed"
    end

    test "a module without id/1 cannot be addressed" do
      assert_raise ArgumentError, ~r/define id\/1/, fn ->
        Start.resolve_address!(NoId, 1)
      end
    end
  end
end
