defmodule Temporalex.Core.TraceGuard do
  @moduledoc """
  Per-executor workflow safe-mode tracing.

  The guard owns an OTP trace session and traces only executor-owned workflow
  runner processes. It keeps trace traffic out of the executor mailbox and
  reports compact violations back to the executor.
  """

  use GenServer

  @op_reply :temporalex_op_reply

  defmodule Violation do
    @moduledoc false

    defexception [:kind, :thread_id, :pid, :detail, :message]

    @impl Exception
    def exception(opts) do
      kind = Keyword.fetch!(opts, :kind)
      thread_id = Keyword.fetch!(opts, :thread_id)
      pid = Keyword.fetch!(opts, :pid)
      detail = Keyword.get(opts, :detail)

      %__MODULE__{
        kind: kind,
        thread_id: thread_id,
        pid: pid,
        detail: detail,
        message:
          "workflow safe mode violation in thread #{inspect(thread_id)}: " <>
            violation_message(kind, detail)
      }
    end

    defp violation_message(:unsafe_call, {module, function, arity}) do
      "unsafe call #{inspect(module)}.#{function}/#{arity}"
    end

    defp violation_message(:unexpected_send, %{destination: destination}) do
      "unexpected send to #{inspect(destination)}"
    end

    defp violation_message(:unexpected_receive, %{message: message}) do
      "unexpected receive #{inspect(message)}"
    end

    defp violation_message(kind, detail), do: "#{kind} #{inspect(detail)}"
  end

  defstruct executor: nil,
            session: nil,
            threads: %{},
            violation: nil,
            violation_reported?: false,
            unsafe_mfas: MapSet.new()

  @unsafe_mfas [
    {:erlang, :date, 0},
    {:erlang, :localtime, 0},
    {:erlang, :make_ref, 0},
    {:erlang, :monotonic_time, 0},
    {:erlang, :monotonic_time, 1},
    {:erlang, :now, 0},
    {:erlang, :open_port, 2},
    {:erlang, :port_command, 2},
    {:erlang, :port_command, 3},
    {:erlang, :send_after, 3},
    {:erlang, :send_after, 4},
    {:erlang, :spawn, 1},
    {:erlang, :spawn, 2},
    {:erlang, :spawn, 3},
    {:erlang, :spawn, 4},
    {:erlang, :spawn_link, 1},
    {:erlang, :spawn_link, 2},
    {:erlang, :spawn_link, 3},
    {:erlang, :spawn_link, 4},
    {:erlang, :spawn_monitor, 1},
    {:erlang, :spawn_monitor, 2},
    {:erlang, :spawn_monitor, 3},
    {:erlang, :spawn_monitor, 4},
    {:erlang, :start_timer, 3},
    {:erlang, :start_timer, 4},
    {:erlang, :system_time, 0},
    {:erlang, :system_time, 1},
    {:erlang, :time, 0},
    {:erlang, :unique_integer, 0},
    {:erlang, :unique_integer, 1},
    {:erlang, :universaltime, 0},
    {:crypto, :strong_rand_bytes, 1},
    {:persistent_term, :get, 0},
    {:persistent_term, :get, 1},
    {Application, :fetch_env, 2},
    {Application, :fetch_env!, 2},
    {Application, :get_all_env, 1},
    {Application, :get_env, 2},
    {Application, :get_env, 3},
    {Date, :utc_today, 0},
    {DateTime, :utc_now, 0},
    {DateTime, :utc_now, 1},
    {File, :cd, 1},
    {File, :cd, 2},
    {NaiveDateTime, :utc_now, 0},
    {NaiveDateTime, :utc_now, 1},
    {Path, :expand, 1},
    {Path, :expand, 2},
    {Path, :wildcard, 1},
    {Path, :wildcard, 2},
    {Process, :send, 2},
    {Process, :send, 3},
    {Process, :send_after, 3},
    {Process, :send_after, 4},
    {Process, :sleep, 1},
    {System, :cmd, 2},
    {System, :cmd, 3},
    {System, :cwd, 0},
    {System, :fetch_env, 1},
    {System, :fetch_env!, 1},
    {System, :find_executable, 1},
    {System, :get_env, 0},
    {System, :get_env, 1},
    {System, :get_env, 2},
    {System, :monotonic_time, 0},
    {System, :monotonic_time, 1},
    {System, :os_time, 0},
    {System, :os_time, 1},
    {System, :shell, 1},
    {System, :shell, 2},
    {System, :system_time, 0},
    {System, :system_time, 1},
    {System, :tmp_dir, 0},
    {System, :tmp_dir!, 0},
    {System, :unique_integer, 0},
    {System, :unique_integer, 1},
    {System, :user_home, 0},
    {System, :user_home!, 0},
    {Time, :utc_now, 0},
    {Time, :utc_now, 1},
    {:timer, :send_after, 2},
    {:timer, :send_after, 3},
    {:timer, :sleep, 1}
  ]

  @unsafe_export_modules [
    :dets,
    :ets,
    :mnesia,
    :os,
    :rand,
    :random,
    File,
    Port,
    Task,
    Task.Supervisor
  ]

  @runtime_modules [
    Temporalex.Workflow.API,
    Temporalex.Core.Context,
    Temporalex.Core.Op,
    Temporalex.Failure,
    Temporalex.Failure.ActivityError,
    Temporalex.Failure.ApplicationError,
    Temporalex.Failure.CancelledError,
    Temporalex.Failure.TimeoutError,
    Temporalex.Failure.TerminatedError
  ]

  def available? do
    Code.ensure_loaded?(:trace) and function_exported?(:trace, :session_create, 3)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def trace_thread(guard, pid, thread_id) when is_pid(guard) and is_pid(pid) do
    GenServer.call(guard, {:trace_thread, pid, thread_id})
  end

  def untrace_all(nil), do: :ok

  def untrace_all(guard) when is_pid(guard) do
    GenServer.call(guard, :untrace_all)
  end

  def checkpoint(nil, _pid), do: nil

  def checkpoint(guard, pid) when is_pid(guard) and is_pid(pid) do
    GenServer.call(guard, {:checkpoint, pid})
  end

  @impl GenServer
  def init(opts) do
    if available?() do
      preload_runtime_modules()

      session = :trace.session_create(:temporalex_trace_guard, self(), [])
      unsafe_mfas = unsafe_mfas() |> Enum.uniq()

      state = %__MODULE__{
        executor: Keyword.fetch!(opts, :executor),
        session: session,
        unsafe_mfas: MapSet.new(unsafe_mfas)
      }

      state =
        Enum.reduce(unsafe_mfas, state, fn mfa, acc ->
          install_call_trace(acc, mfa)
        end)

      {:ok, state}
    else
      {:stop, :trace_sessions_unavailable}
    end
  end

  @impl GenServer
  def handle_call({:trace_thread, pid, thread_id}, _from, state) do
    :trace.process(state.session, pid, true, [:send, :receive, :call, :arity])
    {:reply, :ok, %{state | threads: Map.put(state.threads, pid, thread_id)}}
  end

  def handle_call(:untrace_all, _from, state) do
    Enum.each(Map.keys(state.threads), fn pid ->
      untrace_process(state.session, pid)
    end)

    {:reply, :ok, %{state | threads: %{}}}
  end

  def handle_call({:checkpoint, pid}, _from, state) do
    state = drain_trace_messages(state)

    state =
      if Map.has_key?(state.threads, pid) do
        await_delivered(state, pid)
      else
        state
      end

    {:reply, state.violation, state}
  end

  @impl GenServer
  def handle_info({:trace_delivered, _pid, _ref}, state), do: {:noreply, state}

  def handle_info(message, state) do
    {:noreply, process_trace_message(state, message)}
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{session: session}) do
    if session do
      :trace.session_destroy(session)
    end

    :ok
  end

  defp await_delivered(state, pid) do
    ref = :trace.delivered(state.session, pid)
    receive_until_delivered(state, pid, ref)
  end

  defp receive_until_delivered(state, pid, ref) do
    receive do
      {:trace_delivered, ^pid, ^ref} ->
        state

      {:trace, _pid, _event, _detail} = message ->
        state
        |> process_trace_message(message)
        |> receive_until_delivered(pid, ref)

      {:trace, _pid, _event, _detail, _extra} = message ->
        state
        |> process_trace_message(message)
        |> receive_until_delivered(pid, ref)
    after
      100 ->
        state
    end
  end

  defp drain_trace_messages(state) do
    receive do
      {:trace_delivered, _pid, _ref} ->
        drain_trace_messages(state)

      {:trace, _pid, _event, _detail} = message ->
        state |> process_trace_message(message) |> drain_trace_messages()

      {:trace, _pid, _event, _detail, _extra} = message ->
        state |> process_trace_message(message) |> drain_trace_messages()
    after
      0 ->
        state
    end
  end

  defp process_trace_message(state, {:trace, pid, :call, {module, function, arity}}) do
    if MapSet.member?(state.unsafe_mfas, {module, function, arity}) do
      record_violation(state, pid, :unsafe_call, {module, function, arity})
    else
      state
    end
  end

  defp process_trace_message(state, {:trace, pid, :send, message, destination}) do
    thread_id = Map.get(state.threads, pid)

    if thread_id && allowed_send?(state, pid, thread_id, message, destination) do
      state
    else
      record_violation(state, pid, :unexpected_send, %{
        message: message,
        destination: destination
      })
    end
  end

  defp process_trace_message(state, {:trace, pid, :receive, message}) do
    thread_id = Map.get(state.threads, pid)

    if thread_id && allowed_receive?(pid, thread_id, message) do
      state
    else
      record_violation(state, pid, :unexpected_receive, %{message: message})
    end
  end

  defp process_trace_message(state, _message), do: state

  defp allowed_send?(state, pid, thread_id, message, destination) do
    cond do
      destination == state.executor ->
        workflow_op_call?(message, pid, thread_id) or thread_result?(message, thread_id)

      destination == :code_server ->
        code_server_call?(message, pid)

      true ->
        false
    end
  end

  defp code_server_call?({:code_call, pid, _request}, pid), do: true
  defp code_server_call?(_message, _pid), do: false

  defp workflow_op_call?(
         {:"$gen_call", {from_pid, _tag}, {:workflow_op, caller_thread_id, _op}},
         pid,
         thread_id
       ) do
    from_pid == pid and caller_thread_id == thread_id
  end

  defp workflow_op_call?(_message, _pid, _thread_id), do: false

  defp thread_result?({:temporalex_thread_completed, thread_id, _result}, thread_id), do: true
  defp thread_result?({:temporalex_thread_failed, thread_id, _reason}, thread_id), do: true
  defp thread_result?(_message, _thread_id), do: false

  defp allowed_receive?(_pid, thread_id, {:temporalex_run, thread_id}), do: true

  defp allowed_receive?(_pid, _thread_id, {_tag, {@op_reply, status, _value}})
       when status in [:ok, :error, :cancelled],
       do: true

  defp allowed_receive?(_pid, _thread_id, {:code_server, _response}), do: true

  defp allowed_receive?(_pid, _thread_id, _message), do: false

  defp record_violation(%__MODULE__{violation: %Violation{}} = state, _pid, _kind, _detail) do
    state
  end

  defp record_violation(state, pid, kind, detail) do
    violation =
      Violation.exception(
        kind: kind,
        thread_id: Map.get(state.threads, pid, :unknown),
        pid: pid,
        detail: detail
      )

    state = %{state | violation: violation}

    if state.violation_reported? do
      state
    else
      send(state.executor, {:trace_guard_violation, violation})
      %{state | violation_reported?: true}
    end
  end

  defp install_call_trace(state, {module, function, arity}) do
    :trace.function(state.session, {module, function, arity}, [], [])
    state
  end

  defp untrace_process(session, pid) do
    :trace.process(session, pid, false, [:send, :receive, :call])
  catch
    :error, :badarg -> :ok
  end

  defp unsafe_mfas do
    @unsafe_mfas ++ exported_mfas(@unsafe_export_modules)
  end

  defp exported_mfas(modules) do
    modules
    |> Enum.flat_map(fn module ->
      case Code.ensure_loaded(module) do
        {:module, ^module} ->
          module
          |> apply(:module_info, [:exports])
          |> Enum.reject(fn {function, _arity} -> function == :module_info end)
          |> Enum.map(fn {function, arity} -> {module, function, arity} end)

        _ ->
          []
      end
    end)
  end

  defp preload_runtime_modules do
    Enum.each(@runtime_modules, &Code.ensure_loaded/1)
  end
end
