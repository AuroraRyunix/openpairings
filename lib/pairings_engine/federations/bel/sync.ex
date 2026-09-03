defmodule PairingsEngine.Federations.BEL.Sync do
  @moduledoc """
  Imports an uploaded Belgian national (KBSB/FRBE) rating-list file into the
  local `kbsb_players` table.

  Unlike `PairingsEngine.Fide.Sync`, which downloads its list over HTTP,
  there is no stable public bulk-download endpoint for the KBSB list (see
  docs/kbsb-sync.md for the research behind that decision), so this is
  triggered by an uploaded file's contents instead of a URL - there's no
  download/connect step, so no connect/receive timeouts or retry/backoff.
  Everything else mirrors the FIDE sync's hardening: watchdog, cancel,
  PubSub progress, `insert_all` with `:replace_all`, manual trigger only -
  this never runs at boot.

  Progress is broadcast on the "kbsb_sync" PubSub topic and queryable via
  `status/0`.
  """

  use GenServer
  require Logger
  alias PairingsEngine.Repo
  alias PairingsEngine.Federations.BEL.{Api, Member, Members, Parser}

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

  @doc """
  Kicks off an import from the KBSB data platform's roster API instead of an
  uploaded file (see `PairingsEngine.Federations.BEL.Api`). Same GenServer, same
  status, same progress topic, same count guards and same full-replace
  transaction - only the source of the rows differs, so the two can never
  disagree about what a valid import is.
  """
  def start_api_import, do: GenServer.cast(__MODULE__, :start_api_import)

  def cancel_import, do: GenServer.cast(__MODULE__, :cancel_import)

  def status do
    GenServer.call(__MODULE__, :status)
    |> Map.from_struct()
    |> Map.drop([:task_pid, :task_ref, :watchdog_timer])
    |> Map.put(:player_count, Members.player_count())
    |> Map.put(:last_sync, Members.last_sync())
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
  def handle_cast(:start_api_import, %{status: :importing} = state), do: {:noreply, state}

  def handle_cast(:start_api_import, _state) do
    server = self()
    {pid, ref} = spawn_monitor(fn -> run_api_import(server) end)

    state = %__MODULE__{
      status: :importing,
      progress: "Contacting the KBSB data platform…",
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
  # being killed) - without this, a crashed task would leave the GenServer
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
      Members.put_last_sync()
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

  # Mirrors run_import/2 exactly, differing only in where the rows come
  # from. Each page reports progress, which also resets the watchdog - a
  # slow network stays alive as long as it is still moving, and only a
  # genuinely wedged walk trips it.
  defp run_api_import(server) do
    state =
      update(server, %__MODULE__{
        status: :importing,
        progress: "Contacting the KBSB data platform…"
      })

    on_progress = fn count ->
      update(server, %{state | progress: "Downloading players… #{count}"})
    end

    with {:ok, rows} <- Api.fetch_all(on_progress),
         {:ok, state} <- import_rows(server, rows, state) do
      Members.put_last_sync()
      update(server, %{state | status: :done, progress: ""})
    else
      {:error, reason} ->
        Logger.error("KBSB API import failed: #{inspect(reason)}")
        update(server, %__MODULE__{status: :error, error: format_error(reason)})
    end
  rescue
    e ->
      Logger.error("KBSB API import crashed: #{Exception.message(e)}")
      update(server, %__MODULE__{status: :error, error: Exception.message(e)})
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  # `@doc false` and `def` (not `defp`) purely so tests can drive this
  # count-guard/transaction logic directly with synthetic already-parsed
  # rows, without going through `Parser.parse/1` - see
  # PairingsEngine.Federations.BEL.SyncTest. Not part of the module's intended public
  # API.
  @doc false
  def import_rows(server, rows, state) do
    total = length(rows)
    current_count = Repo.aggregate(Member, :count)

    cond do
      total == 0 ->
        {:error,
         "KBSB import produced zero usable player rows - the uploaded file may be corrupt " <>
           "or in an unexpected format. The existing #{current_count}-player cache was left " <>
           "untouched."}

      current_count > 0 and total < div(current_count, 2) ->
        {:error,
         "KBSB import only produced #{total} usable player rows, far fewer than the " <>
           "existing #{current_count}-player cache - the uploaded file may be corrupt or " <>
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
        #
        # Clear the FTS index FIRST, in one statement. The delete trigger on
        # `kbsb_players` runs
        #
        #     DELETE FROM kbsb_players_fts WHERE national_id = old.national_id
        #
        # and `kbsb_players_fts` is an FTS5 virtual table, which cannot carry
        # an index - so that WHERE is a full scan of the index, once per
        # deleted row. Deleting the whole roster was therefore quadratic.
        # Emptying the index up front leaves each trigger scanning an empty
        # table instead of a full one.
        #
        # Measured (2026-09-03): 1k/2k/4k rows took 141/538/2136 ms before -
        # four times the cost for twice the rows - and 3.8/8.4/14.7 ms after.
        # Extrapolated to the current ~36k roster the old path needed about
        # 171 s, against a 180 s watchdog: that is why this started FAILING
        # at "Importing players... 0 of N" rather than merely being slow. It
        # had been getting slower with every new member for weeks.
        Repo.query!("DELETE FROM kbsb_players_fts")
        Repo.query!("DELETE FROM kbsb_players")

        rows
        |> Stream.chunk_every(@insert_chunk_size)
        |> Stream.with_index(1)
        |> Enum.each(fn {chunk, i} ->
          Repo.insert_all(Member, chunk,
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
