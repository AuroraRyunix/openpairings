defmodule PairingsEngine.Kbsb.Sync do
  @moduledoc """
  Imports an uploaded Belgian national (KBSB/FRBE) rating-list file into the
  local `kbsb_players` table.

  Unlike `PairingsEngine.Fide.Sync`, which downloads its list over HTTP,
  there is no stable public bulk-download endpoint for the KBSB list (see
  docs/kbsb-sync.md for the research behind that decision), so this is
  triggered by an uploaded file's contents instead of a URL — there's no
  download/connect step, so no connect/receive timeouts or retry/backoff.
  Everything else mirrors the FIDE sync's hardening: watchdog, cancel,
  PubSub progress, `insert_all` with `:replace_all`, manual trigger only —
  this never runs at boot.

  Progress is broadcast on the "kbsb_sync" PubSub topic and queryable via
  `status/0`.
  """

  use GenServer
  require Logger
  alias PairingsEngine.{Repo, Kbsb}
  alias PairingsEngine.Kbsb.{KbsbPlayer, Parser}

  @topic "kbsb_sync"

  # Same backstop as the FIDE sync: if no progress update arrives for this
  # long (e.g. the import task wedges on a huge/malformed file), fail the
  # sync rather than leave the UI on "Parsing file…" forever.
  @watchdog_timeout_ms :timer.minutes(3)

  @insert_chunk_size 500

  defstruct status: :idle,
            progress: "",
            error: nil,
            imported_rows: 0,
            total_rows: 0,
            task_pid: nil,
            task_ref: nil,
            watchdog_timer: nil

  ## API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)

  @doc "Kicks off an import from the raw contents of an uploaded rating-list file."
  def start_import(binary) when is_binary(binary),
    do: GenServer.cast(__MODULE__, {:start_import, binary})

  def cancel_import, do: GenServer.cast(__MODULE__, :cancel_import)

  def status do
    GenServer.call(__MODULE__, :status)
    |> Map.from_struct()
    |> Map.drop([:task_pid, :task_ref, :watchdog_timer])
    |> Map.put(:player_count, Kbsb.player_count())
    |> Map.put(:last_sync, Kbsb.last_sync())
  end

  def topic, do: @topic

  ## GenServer

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:start_import, _binary}, %{status: :importing} = state) do
    {:noreply, state}
  end

  def handle_cast({:start_import, binary}, _state) do
    server = self()
    {pid, ref} = spawn_monitor(fn -> run_import(server, binary) end)

    state = %__MODULE__{
      status: :importing,
      progress: "Reading file…",
      task_pid: pid,
      task_ref: ref,
      watchdog_timer: schedule_watchdog()
    }

    {:noreply, broadcast(state)}
  end

  @impl true
  def handle_cast(:cancel_import, %{status: :importing, task_pid: pid, watchdog_timer: timer}) do
    cancel_watchdog(timer)
    if pid, do: Process.exit(pid, :kill)
    {:noreply, broadcast(%__MODULE__{status: :idle})}
  end

  def handle_cast(:cancel_import, state), do: {:noreply, state}

  # Progress/terminal updates from the running task. The task's locally-built
  # state structs don't know about task_pid/task_ref/watchdog_timer (those
  # are this GenServer's bookkeeping), so we carry them forward across busy
  # updates and clear them once the import reaches a terminal state.
  @impl true
  def handle_info({:sync_update, new_state}, state) do
    cancel_watchdog(state.watchdog_timer)

    if new_state.status in [:done, :error] do
      {:noreply, broadcast(%{new_state | task_pid: nil, task_ref: nil, watchdog_timer: nil})}
    else
      merged = %{
        new_state
        | task_pid: state.task_pid,
          task_ref: state.task_ref,
          watchdog_timer: schedule_watchdog()
      }

      {:noreply, broadcast(merged)}
    end
  end

  # Safety net for exits that bypass run_import's `rescue` (e.g. the task
  # being killed) — without this, a crashed task would leave the GenServer
  # stuck in :importing forever and the button would never re-enable.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state)
      when reason != :normal do
    cancel_watchdog(state.watchdog_timer)
    Logger.error("KBSB import task crashed: #{inspect(reason)}")

    new_state = %__MODULE__{
      status: :error,
      error: "Import crashed unexpectedly (#{inspect(reason)}). Please try again."
    }

    {:noreply, broadcast(new_state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # No progress broadcast for @watchdog_timeout_ms straight through importing:
  # something is stuck. Kill the task and fail cleanly so the UI recovers.
  def handle_info(:watchdog_timeout, %{status: :importing} = state) do
    Logger.error("KBSB import watchdog fired: no progress for #{@watchdog_timeout_ms}ms")
    if state.task_pid, do: Process.exit(state.task_pid, :kill)

    new_state = %__MODULE__{
      status: :error,
      error: "Import stalled with no progress. Please try again."
    }

    {:noreply, broadcast(new_state)}
  end

  def handle_info(:watchdog_timeout, state), do: {:noreply, state}

  defp schedule_watchdog, do: Process.send_after(self(), :watchdog_timeout, @watchdog_timeout_ms)

  defp cancel_watchdog(nil), do: :ok
  defp cancel_watchdog(timer), do: Process.cancel_timer(timer)

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(PairingsEngine.PubSub, @topic, {:kbsb_sync, state})
    state
  end

  defp update(server, state) do
    send(server, {:sync_update, state})
    state
  end

  ## The import job (runs in its own task)

  defp run_import(server, binary) do
    state = update(server, %__MODULE__{status: :importing, progress: "Parsing file…"})

    with {:ok, rows} <- Parser.parse(binary),
         {:ok, state} <- import_rows(server, rows, state) do
      Kbsb.put_last_sync()
      update(server, %{state | status: :done, progress: ""})
    else
      {:error, reason} ->
        Logger.error("KBSB import failed: #{inspect(reason)}")
        update(server, %__MODULE__{status: :error, error: format_error(reason)})
    end
  rescue
    e ->
      Logger.error("KBSB import crashed: #{Exception.message(e)}")
      update(server, %__MODULE__{status: :error, error: Exception.message(e)})
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  # `@doc false` and `def` (not `defp`) purely so tests can drive this
  # count-guard/transaction logic directly with synthetic already-parsed
  # rows, without going through `Parser.parse/1` — see
  # PairingsEngine.Kbsb.SyncTest. Not part of the module's intended public
  # API.
  @doc false
  def import_rows(server, rows, state) do
    total = length(rows)
    current_count = Repo.aggregate(KbsbPlayer, :count)

    cond do
      total == 0 ->
        {:error,
         "KBSB import produced zero usable player rows — the uploaded file may be corrupt " <>
           "or in an unexpected format. The existing #{current_count}-player cache was left " <>
           "untouched."}

      current_count > 0 and total < div(current_count, 2) ->
        {:error,
         "KBSB import only produced #{total} usable player rows, far fewer than the " <>
           "existing #{current_count}-player cache — the uploaded file may be corrupt or " <>
           "truncated. The existing cache was left untouched."}

      true ->
        do_import_rows(server, rows, total, state)
    end
  end

  defp do_import_rows(server, rows, total, state) do
    state =
      update(server, %{state | total_rows: total, progress: "Importing players… 0 of #{total}"})

    Repo.transaction(
      fn ->
        # Full replace: the imported list is authoritative for the rows it contains.
        Repo.query!("DELETE FROM kbsb_players")

        rows
        |> Stream.chunk_every(@insert_chunk_size)
        |> Stream.with_index(1)
        |> Enum.each(fn {chunk, i} ->
          Repo.insert_all(KbsbPlayer, chunk,
            on_conflict: :replace_all,
            conflict_target: :national_id
          )

          imported = min(i * @insert_chunk_size, total)

          update(server, %{
            state
            | imported_rows: imported,
              progress: "Importing players… #{imported} of #{total}"
          })
        end)
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, _} -> {:ok, %{state | imported_rows: total}}
      {:error, reason} -> {:error, reason}
    end
  end
end
