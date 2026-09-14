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

  Like the FIDE sync, the actual replace in `do_import_rows/4` does not run
  inside one database transaction. SQLite allows exactly one writer for the
  whole database, and holding that lock for as long as the roster takes to
  reload used to queue every other write in the app behind it - see
  `PairingsEngine.Fide.Sync`'s moduledoc for the full story, which applies
  here unchanged. Each statement in `do_import_rows/4` commits on its own
  instead.
  """

  use GenServer
  require Logger
  import Ecto.Query, only: [from: 2]
  alias PairingsEngine.Repo
  alias PairingsEngine.Federations.BEL.{Clubs, Http, Member, Members, Parser, SqliteFile}

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

  @doc """
  Kicks off an import from the raw contents of an uploaded rating-list
  file - the older delimited-text format
  (`PairingsEngine.Federations.BEL.Parser`), a bare `players.sqlite`, or
  the whole monthly zip KBSB publishes (both handled by
  `PairingsEngine.Federations.BEL.SqliteFile`), auto-detected by content.
  """
  def start_import(binary) when is_binary(binary),
    do: GenServer.cast(__MODULE__, {:start_import, binary})

  @doc """
  Kicks off an import from KBSB's public monthly rating-list URL (see
  `PairingsEngine.Federations.BEL.Http` and
  `PairingsEngine.Federations.BEL.Settings`) instead of an uploaded file.
  Same GenServer, same status, same progress topic, same count guards and
  same full-replace import - only the source of the rows differs, so the
  two can never disagree about what a valid import is.
  """
  def start_http_import, do: GenServer.cast(__MODULE__, :start_http_import)

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
  def handle_cast(:start_http_import, %{status: :importing} = state), do: {:noreply, state}

  def handle_cast(:start_http_import, _state) do
    server = self()
    {pid, ref} = spawn_monitor(fn -> run_http_import(server) end)

    state = %__MODULE__{
      status: :importing,
      progress: "Contacting the KBSB website…",
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
    # Only the exit's shape, never its terms - see crashed/4.
    summary = if is_atom(reason), do: inspect(reason), else: "abnormal exit"
    Logger.error("KBSB import task crashed: #{summary}")

    new_state = %__MODULE__{
      status: :error,
      error: "Import crashed unexpectedly (#{summary}). Please try again."
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

    result =
      cond do
        SqliteFile.zip?(binary) or SqliteFile.sqlite?(binary) ->
          with {:ok, %{rows: raw_rows, clubs: zip_clubs}} <- SqliteFile.read(binary) do
            # An upload has no network expectation at all (see the
            # moduledoc), so the separate "club names URL" is not fetched
            # here - only the zip's own `clubs` table (if any) and whatever
            # names are already on file from a previous HTTP sync.
            club_names = Clubs.resolve(zip_clubs, nil)
            {:ok, Enum.map(raw_rows, &SqliteFile.to_member_row(&1, club_names))}
          end

        true ->
          Parser.parse(binary)
      end

    with {:ok, rows} <- result,
         {:ok, state} <- import_rows(server, rows, state) do
      Members.put_last_sync()
      update(server, %{state | status: :done, progress: ""})
    else
      {:error, reason} ->
        Logger.error("KBSB import failed: #{inspect(reason)}")
        update(server, %__MODULE__{status: :error, error: format_error(reason)})
    end
  rescue
    e -> crashed(server, "KBSB import", e, __STACKTRACE__)
  end

  # Mirrors run_import/2, differing in where the rows (and any bundled club
  # names) come from: KBSB's public monthly zip instead of an uploaded file
  # or the removed API/relay sources. `:unchanged` (an unmodified players
  # file - see `Http.fetch_players/1`) leaves the existing table exactly as
  # it was and only bumps `last_sync`, matching the removed results-site
  # source's handling of its own ETag.
  defp run_http_import(server) do
    state =
      update(server, %__MODULE__{
        status: :importing,
        progress: "Contacting the KBSB website…"
      })

    on_progress = fn message -> update(server, %{state | progress: message}) end

    case Http.fetch_players(on_progress) do
      # `month_label` only comes back from a {YYYYMM} template; the default
      # fixed URL has no month to name. Matching it as required made every
      # sync from the fixed URL fall through to a CaseClauseError.
      {:ok, %{rows: raw_rows, clubs: zip_clubs} = fetched} ->
        club_names = resolve_club_names(zip_clubs, on_progress)
        rows = Enum.map(raw_rows, &SqliteFile.to_member_row(&1, club_names))

        case import_rows(server, rows, state) do
          {:ok, state} ->
            Members.put_last_sync()

            if month_label = Map.get(fetched, :month_label),
              do: Members.put_source_month(month_label)

            update(server, %{state | status: :done, progress: ""})

          {:error, reason} ->
            Logger.error("KBSB HTTP import failed: #{inspect(reason)}")
            update(server, %__MODULE__{status: :error, error: format_error(reason)})
        end

      :unchanged ->
        Members.put_last_sync()

        update(server, %{
          state
          | status: :done,
            progress: "",
            imported_rows: Members.player_count()
        })

      {:error, reason} ->
        Logger.error("KBSB HTTP import failed: #{inspect(reason)}")
        update(server, %__MODULE__{status: :error, error: format_error(reason)})
    end
  rescue
    e -> crashed(server, "KBSB HTTP import", e, __STACKTRACE__)
  end

  # An exception's message can quote whatever term it failed on - here that
  # was the whole downloaded roster, names and birth years, printed on the
  # page and in the log. Only the exception's type and where it was raised
  # are kept.
  defp crashed(server, what, exception, stacktrace) do
    kind = inspect(exception.__struct__)

    Logger.error("#{what} crashed: #{kind}
" <> Exception.format_stacktrace(Enum.take(stacktrace, 5)))

    update(server, %__MODULE__{
      status: :error,
      error: "The import failed unexpectedly (#{kind}). Please try again, or report it."
    })
  end

  # The club-names URL is a second, independent, optional file - see
  # `PairingsEngine.Federations.BEL.Clubs`'s moduledoc for the full
  # precedence. A failure to reach IT specifically is not a reason to fail
  # the whole players import: the players list is the one thing this sync
  # exists for, and a club-names hiccup degrades to "show the number"
  # rather than aborting an otherwise-good import.
  defp resolve_club_names(zip_clubs, on_progress) do
    url_clubs =
      case Http.fetch_clubs_file(on_progress) do
        {:ok, map} -> map
        _not_configured_unchanged_or_error -> nil
      end

    Clubs.resolve(zip_clubs, url_clubs)
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
    rows = keep_ratings_when_list_has_none(rows)
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

  # KBSB's monthly file carried no national ratings at all in July and August
  # 2026 (every `Elo` NULL; the April file had about 19,000). A full replace
  # from such a file would wipe every stored rating. When a list has no rating
  # on ANY row, each player keeps the rating already stored for their
  # national ID; everything else - names, clubs, membership - still comes from
  # the new list. A list with even one rating is taken as authoritative.
  @doc false
  def keep_ratings_when_list_has_none(rows) do
    if rows != [] and Enum.all?(rows, &is_nil(Map.get(&1, :national_rating))) do
      stored =
        from(m in Member,
          where: not is_nil(m.national_rating),
          select: {m.national_id, m.national_rating}
        )
        |> Repo.all()
        |> Map.new()

      if map_size(stored) > 0 do
        Logger.warning(
          "KBSB list has no national ratings on any row; kept #{map_size(stored)} stored ratings"
        )
      end

      Enum.map(rows, &Map.put(&1, :national_rating, Map.get(stored, &1.national_id)))
    else
      rows
    end
  end

  defp do_import_rows(server, rows, total, state) do
    state =
      update(server, %{state | total_rows: total, progress: "Importing players… 0 of #{total}"})

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
    #
    # None of this runs inside a transaction any more (see the moduledoc):
    # each statement commits and frees SQLite's write lock the moment it
    # runs, instead of holding it for the whole roster. The trade-off is
    # that a lookup landing between the two DELETEs below and the last
    # insert chunk sees a roster that is empty or only partly reloaded, and
    # a hard kill (cancel_import, or the watchdog) partway through leaves it
    # that way until the next import finishes. Accepted: `import_rows/3`'s
    # guards have already run and passed by the time any of this executes,
    # so what follows is known-good data, and a stale/incomplete READ is a
    # far smaller failure than every write in the app - an arbiter entering
    # a result included - queuing behind a multi-minute transaction the way
    # it used to. SQLite still guarantees each statement below is atomic to
    # any other connection, so a concurrent lookup only ever sees a real,
    # fully-committed count, never a torn row.
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

    {:ok, %{state | imported_rows: total}}
  end
end
