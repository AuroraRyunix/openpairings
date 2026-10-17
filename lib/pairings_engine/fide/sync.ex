defmodule PairingsEngine.Fide.Sync do
  @moduledoc """
  Downloads the combined FIDE rating list (TXT format, published monthly on
  ratings.fide.com) and loads it into the local fide_players table.

  Progress is broadcast on the "fide_sync" PubSub topic and queryable via
  `status/0`.

  The import that follows a successful download does not run inside one
  database transaction. SQLite allows exactly one writer for the whole
  database (not per table), and a transaction spanning the entire replace
  held that single write lock for minutes, with every other write in the
  app - an arbiter's round result included - queued behind it until
  `busy_timeout` refused it (see `PairingsEngine.BusyWrite`).

  So `do_import_list/4` builds the new list beside the old one: the rows in
  `fide_players_new` and the name index in `fide_players_fts_new`, both in
  2000-row chunks that each commit on their own, so the lock is free between
  one chunk and the next. Only when both are complete do they trade places
  with the live tables, by rename, in one short transaction. Until then every
  search reads the old list, whole.

  It used to delete the live rows first and refill them in place. A restart
  halfway - a deploy, say - then left half a list for weeks, and an arbiter
  search found a name in the index whose row was gone. A killed run now
  leaves only scratch tables, which the next run drops, and the boot check
  (`damage/0`) says so on the FIDE page in the meantime.
  """

  use GenServer
  require Logger
  alias PairingsEngine.{Repo, Fide, SafeError}
  alias PairingsEngine.Fide.{AutoSync, FidePlayer}

  @default_list_url "https://ratings.fide.com/download/players_list.zip"
  @topic "fide_sync"

  @doc """
  Where the rating-list zip is fetched from - FIDE directly by default,
  overridable with `FIDE_LIST_URL` (see `config/runtime.exs`).

  The override exists because ratings.fide.com blocks some hosting ranges
  outright, which strands a VPS deploy on a download that can never succeed
  no matter how often it retries. Pointing this at a mirror or a pass-through
  proxy is the only fix available from this side.

  Whatever it points at is trusted to the same degree FIDE is: the response
  is unpacked and loaded straight into `fide_players`. Only set it to
  something you control.
  """
  def list_url do
    Application.get_env(:pairings_engine, :fide, [])[:list_url] || @default_list_url
  end

  @doc """
  Host `list_url/0` points at, for the progress line - "FIDE" when it's the
  default, otherwise the actual hostname.

  Named rather than left as a constant "Contacting FIDE…" because
  `FIDE_LIST_URL` is read once at boot, from a `.env` in the service's
  working directory: an override that was mistyped, quoted, put in the wrong
  directory, or simply added without restarting is invisible from the UI, and
  looks identical to FIDE blocking the host - the same silent stall, for
  four different reasons. Showing the host it is actually dialling separates
  them at a glance.
  """
  def source_label do
    url = list_url()

    if url == @default_list_url do
      "FIDE"
    else
      case URI.parse(url) do
        %URI{host: host} when is_binary(host) -> host
        _ -> url
      end
    end
  end

  # Req timeouts: connect_options.timeout bounds the initial TCP/TLS handshake,
  # receive_timeout bounds how long we'll wait between chunks once streaming
  # (i.e. it's an inactivity window, not a total-transfer deadline).
  @connect_timeout_ms :timer.seconds(30)
  @receive_timeout_ms :timer.minutes(2)
  @max_download_attempts 3

  # The real list is ~41 MB. This is a generous ceiling that still bounds how
  # much a redirected, mirrored or misbehaving endpoint can stream into memory
  # here: once crossed, the download is abandoned mid-stream rather than pulled
  # to completion. The source is trusted (HTTPS, FIDE or whatever `list_url/0`
  # was pointed at), so this is a backstop, not a filter.
  @max_download_bytes 250_000_000

  # Backstop for the whole sync (download + unpack + import combined): if no
  # progress update arrives for this long, something is stuck (hung socket,
  # wedged connection pool, etc.) and we fail the sync rather than leave the
  # UI on "Contacting FIDE…" forever. Reset on every progress broadcast.
  @watchdog_timeout_ms :timer.minutes(3)

  # Header labels in file order - "ID Number" is one column despite the space.
  @header_labels [
    "ID Number",
    "Name",
    "Fed",
    "Sex",
    "Tit",
    "WTit",
    "OTit",
    "FOA",
    "SRtng",
    "SGm",
    "SK",
    "RRtng",
    "RGm",
    "Rk",
    "BRtng",
    "BGm",
    "BK",
    "B-day",
    "Flag"
  ]

  @field_labels %{
    fide_id: "ID Number",
    name: "Name",
    federation: "Fed",
    sex: "Sex",
    title: "Tit",
    standard_rating: "SRtng",
    rapid_rating: "RRtng",
    blitz_rating: "BRtng",
    birth_year: "B-day",
    flag: "Flag"
  }

  @numeric ~w(fide_id standard_rating rapid_rating blitz_rating birth_year)a

  # See `do_import_list/4`: the live search index, the scratch copy built
  # beside it, and the old copy waiting to be dropped once the scratch one
  # has been swapped into `@fts_table`'s place.
  @fts_table "fide_players_fts"
  @fts_scratch_table "fide_players_fts_new"
  @fts_retired_table "fide_players_fts_old"

  # The same trio for the rows themselves.
  @rows_table "fide_players"
  @rows_scratch_table "fide_players_new"
  @rows_retired_table "fide_players_old"

  @row_indexes [
    {"fide_players_name_index", "name COLLATE NOCASE"},
    {"fide_players_federation_index", "federation"}
  ]

  # Row-chunk size for both `fide_players` and the FTS scratch table built
  # beside it in `do_import_list/4` - one constant so the two stay in step.
  @import_chunk_size 2000

  defstruct status: :idle,
            progress: "",
            error: nil,
            loaded_bytes: 0,
            total_bytes: 0,
            imported_rows: 0,
            total_rows: 0,
            task_pid: nil,
            task_ref: nil,
            watchdog_timer: nil,
            damage: nil

  ## API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)

  def start_sync, do: GenServer.cast(__MODULE__, :start_sync)

  def cancel_sync, do: GenServer.cast(__MODULE__, :cancel_sync)

  def status do
    GenServer.call(__MODULE__, :status)
    |> Map.from_struct()
    |> Map.drop([:task_pid, :task_ref, :watchdog_timer])
    |> Map.put(:player_count, Fide.player_count())
    |> Map.put(:last_sync, Fide.last_sync())
  end

  def topic, do: @topic

  ## GenServer

  @impl true
  def init(state) do
    # Looked at after start-up, not during it: counting two tables of
    # 1.9 million rows is not something the supervision tree should wait for.
    {:ok, state, {:continue, :boot_check}}
  end

  @impl true
  def handle_continue(:boot_check, state) do
    if Application.get_env(:pairings_engine, :fide_boot_check, true) do
      {:noreply, boot_check(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:start_sync, %{status: s} = state) when s in [:downloading, :importing] do
    {:noreply, state}
  end

  def handle_cast(:start_sync, state) do
    server = self()
    {pid, ref} = spawn_monitor(fn -> run_sync(server) end)

    state = %__MODULE__{
      status: :downloading,
      damage: state.damage,
      progress: "Contacting #{source_label()}…",
      task_pid: pid,
      task_ref: ref,
      watchdog_timer: schedule_watchdog()
    }

    {:noreply, broadcast(state)}
  end

  @impl true
  def handle_cast(:cancel_sync, %{status: s, task_pid: pid, watchdog_timer: timer} = state)
      when s in [:downloading, :importing] do
    cancel_watchdog(timer)
    if pid, do: Process.exit(pid, :kill)
    {:noreply, broadcast(%__MODULE__{status: :idle, damage: state.damage})}
  end

  def handle_cast(:cancel_sync, state), do: {:noreply, state}

  # Progress/terminal updates from the running task. The task's locally-built
  # state structs don't know about task_pid/task_ref/watchdog_timer (those are
  # this GenServer's bookkeeping), so we carry them forward across busy
  # updates and clear them once the sync reaches a terminal state.
  @impl true
  def handle_info({:sync_update, new_state}, state) do
    cancel_watchdog(state.watchdog_timer)

    if new_state.status in [:done, :error] do
      # A finished sync is a whole new list: whatever was wrong with the old
      # one is gone. A failed one changed nothing, so the verdict stands.
      damage = if new_state.status == :done, do: nil, else: state.damage

      {:noreply,
       broadcast(%{
         new_state
         | task_pid: nil,
           task_ref: nil,
           watchdog_timer: nil,
           damage: damage
       })}
    else
      merged = %{
        new_state
        | task_pid: state.task_pid,
          task_ref: state.task_ref,
          watchdog_timer: schedule_watchdog(),
          damage: state.damage
      }

      {:noreply, broadcast(merged)}
    end
  end

  # Safety net for exits that bypass run_sync's `rescue` (e.g. the task being
  # killed, or an exit signal from the HTTP client) - without this, a crashed
  # task would leave the GenServer stuck in :downloading/:importing forever
  # and the "Update" button would never re-enable.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state)
      when reason != :normal do
    cancel_watchdog(state.watchdog_timer)
    # Only the exit's shape, never its terms - see PairingsEngine.SafeError.
    summary = SafeError.exit_summary(reason)
    Logger.error("FIDE sync task crashed: #{summary}")

    new_state = %__MODULE__{
      status: :error,
      damage: state.damage,
      error: "Sync crashed unexpectedly (#{summary}). Please try again."
    }

    {:noreply, broadcast(new_state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # No progress broadcast for @watchdog_timeout_ms straight through downloading
  # or importing: something is stuck. Kill the task and fail cleanly so the
  # UI recovers instead of hanging on "Contacting FIDE…" indefinitely.
  def handle_info(:watchdog_timeout, %{status: s} = state) when s in [:downloading, :importing] do
    Logger.error("FIDE sync watchdog fired: no progress for #{@watchdog_timeout_ms}ms")
    if state.task_pid, do: Process.exit(state.task_pid, :kill)

    new_state = %__MODULE__{
      status: :error,
      damage: state.damage,
      error:
        "Sync stalled with no progress - the FIDE server may be slow or unreachable. Please try again."
    }

    {:noreply, broadcast(new_state)}
  end

  def handle_info(:watchdog_timeout, state), do: {:noreply, state}

  defp schedule_watchdog, do: Process.send_after(self(), :watchdog_timeout, @watchdog_timeout_ms)

  defp cancel_watchdog(nil), do: :ok
  defp cancel_watchdog(timer), do: Process.cancel_timer(timer)

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(PairingsEngine.PubSub, @topic, {:fide_sync, state})
    # The download banner listens on its own topic, so a page that already
    # follows `@topic` is not told everything twice.
    PairingsEngine.Fide.AutoSync.notify()
    state
  end

  defp update(server, state) do
    send(server, {:sync_update, state})
    state
  end

  ## Interrupted runs

  @doc """
  Whether the local list looks like a sync was killed in the middle of it:
  `nil` when it looks fine, otherwise

    * `:interrupted` - a scratch table of a run that never finished is lying
      around. Since the swap design the live list is untouched by such a run,
      so this is a warning rather than a loss;
    * `:incomplete` - the row table holds well under the entries of the name
      index, which is what the old delete-then-refill import left behind when
      it was killed (894,000 rows against 1.9 million index entries).

  Reads only; counts two large tables, so it is run once at boot and not on
  every page.
  """
  @spec damage() :: nil | :interrupted | :incomplete
  def damage do
    %{rows: tables} =
      Repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?)",
        [@rows_scratch_table, @fts_scratch_table]
      )

    rows = Repo.aggregate(FidePlayer, :count)
    %{rows: [[indexed]]} = Repo.query!("SELECT count(*) FROM #{@fts_table}")

    cond do
      indexed > 0 and rows * 10 < indexed * 9 -> :incomplete
      tables != [] -> :interrupted
      true -> nil
    end
  end

  defp boot_check(state) do
    case damage() do
      nil ->
        state

      kind ->
        Logger.warning(
          "FIDE rating list looks damaged by an interrupted sync (#{kind}); " <>
            "a new sync repairs it."
        )

        state = %{state | damage: kind}
        resync_unasked()
        broadcast(state)
    end
  rescue
    # No database yet, a sandbox that was never checked out, a missing FTS
    # table: none of those are worth taking the sync server down for.
    e ->
      Logger.debug("FIDE boot check skipped: #{Exception.message(e)}")
      state
  catch
    :exit, _ -> state
  end

  # The existing daily look (`PairingsEngine.Fide.AutoSync`) would call a
  # month with an unchanged period "current" and never repair anything, so
  # the repair is started here - but only where that module would download
  # without asking (a hosted server, or a desktop set to :auto) and only
  # while auto-sync is on at all. Elsewhere it stays a button.
  defp resync_unasked do
    if Application.get_env(:pairings_engine, :fide_auto_sync, true) and
         AutoSync.enabled?() and AutoSync.download_unasked?() do
      GenServer.cast(self(), :start_sync)
    end
  end

  ## The sync job (runs in its own task)

  defp run_sync(server) do
    state = %__MODULE__{status: :downloading}

    with {:ok, zip, state} <- download(server, state),
         {:ok, text, state} <- unpack(server, zip, state),
         {:ok, state} <- import_list(server, text, state) do
      Fide.put_last_sync(downloaded_period())
      update(server, %{state | status: :done, progress: ""})
    else
      {:error, reason} ->
        Logger.error("FIDE sync failed: #{inspect(reason)}")
        update(server, %__MODULE__{status: :error, error: format_error(reason)})
    end
  rescue
    # An exception's message can quote whatever term it failed on - here
    # that could be a line of the downloaded list, names and birth years
    # included. Only the exception's type and where it was raised are
    # kept - see PairingsEngine.SafeError.
    e ->
      error = SafeError.crash_message("FIDE sync", e, __STACKTRACE__)
      update(server, %__MODULE__{status: :error, error: error})
  end

  defp format_error(%Req.TransportError{} = reason),
    do: "Download failed - #{describe_error(reason)}. Please try again."

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp describe_error(%Req.TransportError{reason: :timeout}), do: "connection timed out"
  defp describe_error(%Req.TransportError{reason: :closed}), do: "connection closed unexpectedly"

  defp describe_error(%Req.TransportError{reason: reason}),
    do: "network error (#{inspect(reason)})"

  defp retryable_error?(%Req.TransportError{}), do: true
  defp retryable_error?(_), do: false

  defp download(server, state) do
    into = build_into(server, state)
    do_download(server, state, into, 1)
  end

  # The into: fun runs in this task's process, so chunks and the byte count
  # are accumulated in the process dictionary. Progress is broadcast at most
  # once per megabyte to avoid flooding the LiveView.
  defp build_into(server, state) do
    fn {:data, data}, {req, resp} ->
      total = resp_content_length(resp)

      if Process.get(:sync_last_modified) == nil,
        do: Process.put(:sync_last_modified, response_last_modified(resp) || :none)

      Process.put(:sync_chunks, [data | Process.get(:sync_chunks)])
      loaded = Process.get(:sync_loaded) + byte_size(data)
      Process.put(:sync_loaded, loaded)

      cond do
        loaded > @max_download_bytes ->
          # Stop pulling; do_download/4 sees the truncated body isn't a valid
          # zip and reports a normal error.
          Process.put(:sync_download_aborted, true)
          {:halt, {req, resp}}

        loaded - Process.get(:sync_last_report) > 1_048_576 ->
          report_progress(server, state, loaded, total)
          {:cont, {req, resp}}

        true ->
          {:cont, {req, resp}}
      end
    end
  end

  defp report_progress(server, state, loaded, total) do
    Process.put(:sync_last_report, loaded)
    mb = Float.round(loaded / 1_048_576, 1)
    total_mb = if total > 0, do: " of #{Float.round(total / 1_048_576, 1)}", else: ""

    update(server, %{
      state
      | status: :downloading,
        loaded_bytes: loaded,
        total_bytes: total,
        progress: "Downloading rating list… #{mb}#{total_mb} MB"
    })
  end

  defp do_download(server, state, into, attempt) do
    Process.put(:sync_chunks, [])
    Process.put(:sync_loaded, 0)
    Process.put(:sync_last_report, 0)
    Process.put(:sync_download_aborted, false)
    Process.put(:sync_last_modified, nil)

    req_opts = [
      into: into,
      connect_options: [timeout: @connect_timeout_ms],
      # Inactivity window: streaming resets Finch's clock on every chunk, so
      # this bounds the gap between chunks, not the whole 41 MB transfer.
      receive_timeout: @receive_timeout_ms,
      retry: false
    ]

    case Req.get(list_url(), req_opts) do
      {:ok, %{status: 200}} ->
        if Process.get(:sync_download_aborted) do
          {:error,
           "Rating list exceeded #{div(@max_download_bytes, 1_000_000)} MB - download stopped."}
        else
          zip = Process.get(:sync_chunks) |> Enum.reverse() |> IO.iodata_to_binary()
          loaded = byte_size(zip)
          {:ok, zip, %{state | loaded_bytes: loaded, total_bytes: loaded}}
        end

      {:ok, %{status: status}} ->
        {:error, "FIDE server answered with HTTP status #{status}"}

      {:error, reason} ->
        if attempt < @max_download_attempts and retryable_error?(reason) do
          wait_ms = attempt * 3_000

          update(server, %{
            state
            | status: :downloading,
              progress:
                "Download interrupted (#{describe_error(reason)}) - retrying " <>
                  "(attempt #{attempt + 1}/#{@max_download_attempts})…"
          })

          Process.sleep(wait_ms)
          do_download(server, state, into, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  # The list's own date, when the server states one: the month it falls in is
  # the monthly list this download is (`Fide.list_period/0`).
  defp response_last_modified(resp) do
    case Req.Response.get_header(resp, "last-modified") do
      [value | _] -> Fide.parse_http_date(value)
      _ -> nil
    end
  end

  defp downloaded_period do
    case Process.get(:sync_last_modified) do
      %DateTime{} = at -> Fide.month_of(DateTime.to_date(at))
      _ -> nil
    end
  end

  defp resp_content_length(resp) do
    case Req.Response.get_header(resp, "content-length") do
      [len | _] -> String.to_integer(len)
      _ -> 0
    end
  end

  # `@max_download_bytes` bounds the COMPRESSED stream; nothing bounded what
  # it inflates to, and `:zip.extract(…, [:memory])` materialises the whole
  # thing at once. The real list unpacks to ~250 MB of Latin-1 text, so 2 GB
  # is a generous backstop rather than a filter - it exists so a pathological
  # archive (a zip bomb from a mirror or a redirected endpoint) fails the
  # sync instead of taking the node's memory with it. The check reads the
  # central directory's declared sizes via `:zip.list_dir/1` first, so it
  # refuses BEFORE inflating; the declared size is not trustworthy on its own,
  # but a bomb that lies about it still has to get past the compressed cap.
  # Overridable so tests can lower it without building a multi-gigabyte file.
  @default_max_unpacked_bytes 2_000_000_000

  defp max_unpacked_bytes do
    Application.get_env(:pairings_engine, :fide_max_unpacked_bytes, @default_max_unpacked_bytes)
  end

  defp unpack(server, zip, state) do
    state = update(server, %{state | status: :importing, progress: "Unpacking…"})

    with :ok <- check_unpacked_size(zip) do
      do_unpack(zip, state)
    end
  end

  # `@doc false` and `def` (not `defp`) purely so tests can drive the ceiling
  # with a small crafted zip and a lowered `:fide_max_unpacked_bytes`, without
  # a real download - same reasoning as `import_list/3` below. Not part of the
  # module's intended public API.
  @doc false
  def check_unpacked_size(zip) do
    case :zip.list_dir(zip) do
      {:ok, entries} ->
        # `list_dir/1` returns a `:zip_comment` record first, then one
        # `:zip_file` per entry whose third element is an Erlang
        # `:file_info` record - `elem(info, 1)` is its declared `size`.
        total =
          Enum.reduce(entries, 0, fn
            {:zip_file, _name, info, _comment, _offset, _comp_size}, acc ->
              acc + elem(info, 1)

            _other, acc ->
              acc
          end)

        if total > max_unpacked_bytes() do
          {:error,
           "The FIDE zip declares #{total} bytes of unpacked content, past the " <>
             "#{max_unpacked_bytes()}-byte limit"}
        else
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_unpack(zip, state) do
    case :zip.extract(zip, [:memory]) do
      {:ok, files} ->
        case Enum.find(files, fn {name, _} -> String.ends_with?(to_string(name), ".txt") end) do
          # Kept as raw Latin-1 bytes: fixed-width columns are byte offsets, so
          # converting to UTF-8 first would shift columns on accented names.
          # Each string field is converted after slicing (see parse_line/2).
          {_name, data} ->
            {:ok, data, state}

          nil ->
            {:error, "No .txt file found inside the FIDE zip"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `@doc false` and `def` (not `defp`) purely so tests can drive this
  # count-guard logic directly with synthetic FIDE-list text, without going
  # through the real HTTP download+unpack - see PairingsEngine.Fide.SyncTest.
  # Not part of the module's intended public API.
  @doc false
  def import_list(server, text, state) do
    # :binary.split, not String.split: the text is Latin-1, not valid UTF-8.
    [header | lines] = :binary.split(text, ["\r\n", "\n"], [:global])
    offsets = column_offsets(header)
    total = length(lines)
    state = update(server, %{state | total_rows: total})

    rows =
      lines
      |> Stream.reject(&(&1 in ["", "\r"]))
      |> Stream.map(&parse_line(&1, offsets))
      |> Stream.reject(&(is_nil(&1.fide_id) or &1.name in [nil, ""]))

    # Snapshot the cache size, and count how many usable rows this download
    # actually parsed, BEFORE writing anything. `do_import_list/4` no longer
    # runs inside one transaction (see the moduledoc), so there is nothing
    # left to roll back if the download turns out corrupt or truncated -
    # these two counts are everything the guard below needs, and both are
    # cheap to know up front. `rows` is a lazy Stream over `lines`, so
    # counting it here doesn't require materialising all ~1.9M parsed rows
    # at once; `do_import_list/4` re-runs the same pipeline a second time to
    # actually insert them.
    current_count = Repo.aggregate(FidePlayer, :count)
    valid_count = Enum.count(rows)

    cond do
      valid_count == 0 ->
        {:error,
         "FIDE import produced zero usable player rows - the downloaded file may be " <>
           "corrupt or truncated. The existing #{format_int(current_count)}-player " <>
           "cache was left untouched."}

      current_count > 0 and valid_count < div(current_count, 2) ->
        {:error,
         "FIDE import only produced #{format_int(valid_count)} usable player rows, far " <>
           "fewer than the existing #{format_int(current_count)}-player cache - the " <>
           "downloaded file may be corrupt or truncated. The existing cache was left " <>
           "untouched."}

      true ->
        do_import_list(server, rows, state, total)
    end
  end

  # The actual full replace, run only once the guard in `import_list/3` has
  # already decided the download is trustworthy. Each statement here commits
  # on its own (auto-committed, same as any SQLite statement outside an
  # explicit BEGIN) rather than the whole thing riding one transaction, so
  # the write lock is free again between an insert chunk and the next - see
  # the moduledoc for why that matters.
  #
  # Nothing live is touched until the very end. A scratch copy of the rows
  # (`fide_players_new`, same columns and indexes) and a scratch copy of the
  # name index (`fide_players_fts_new`) are built side by side, chunk for
  # chunk, while `fide_players` and `fide_players_fts` keep answering every
  # lookup with the old, complete list. Only when both are finished does one
  # short transaction rename all four tables into their new places and put
  # the FTS triggers back on the new row table; the retired pair is dropped
  # afterwards.
  #
  # This used to be `DELETE FROM fide_players` followed by a refill, which a
  # restart in the middle (a deploy, say) turned into a table holding half a
  # list until somebody noticed and ran another sync - in production, 894,000
  # rows against 1.9 million index entries, for weeks. A kill at any point
  # here now leaves the old list exactly as it was, plus some scratch tables
  # that the next run (and `damage/0` at boot) knows what to do with.
  #
  # Measured earlier (2026-09-12) against a synthetic 1.9M-row table: every
  # FTS chunk stayed under 100ms, the FTS rename swap took 13ms and dropping
  # the retired FTS table 134ms. The new retired row table is dropped the
  # same way, as one statement after the swap, and is cleanup rather than
  # something correctness depends on.
  defp do_import_list(server, rows, state, total) do
    # Leftovers of a killed run. A scratch pair from a run that never reached
    # the swap is half-built and was never live; a retired pair from a run
    # killed right after the swap is merely unreclaimed space. Either would
    # make the `CREATE` below fail, and neither is worth keeping, so all are
    # dropped before anything else starts. Dropping a table takes its indexes
    # along.
    drop_scratch_tables()

    # Captured before anything changes, from the live table. Read from
    # `sqlite_master` rather than written out here so an ordinary run puts
    # them back as the migration defined them; the built-in copies cover a
    # database that has none (an older killed run, see `fts_triggers/0`).
    triggers = fts_triggers()

    create_scratch_rows_table()

    Repo.query!("""
    CREATE VIRTUAL TABLE #{@fts_scratch_table} USING fts5(
      fide_id UNINDEXED,
      name,
      tokenize = 'unicode61 remove_diacritics 2'
    )
    """)

    imported =
      rows
      |> Stream.chunk_every(@import_chunk_size)
      |> Stream.with_index(1)
      |> Enum.reduce(0, fn {chunk, i}, acc ->
        Repo.insert_all({@rows_scratch_table, FidePlayer}, chunk,
          on_conflict: :replace_all,
          conflict_target: :fide_id
        )

        # Built alongside the rows, chunk for chunk, rather than one
        # `INSERT ... SELECT` after the fact once every row is in - that
        # one statement is exactly what used to cost 11.5s.
        insert_fts_chunk(chunk)

        # Real running total (not an i * 2000 approximation, which
        # overcounts on a partial final chunk).
        imported = acc + length(chunk)

        if rem(i, 25) == 0 do
          update(server, %{
            state
            | imported_rows: imported,
              progress: "Importing players… #{format_int(imported)} of ~#{format_int(total)}"
          })
        end

        imported
      end)

    update(server, %{
      state
      | imported_rows: imported,
        progress: "Switching to the new list…"
    })

    # The atomic switch. Any other connection sees either the complete old
    # pair or the complete new pair - never a missing name, never a mixture.
    # SQLite renames a virtual table's shadow storage along with it, so the
    # FTS pair moves rather than rebuilds.
    #
    # The triggers go first: they are attached to the table they were
    # created on, so a rename would carry them to the retired table, where
    # they would go on mirroring writes into whatever the FTS name pointed
    # at. Dropped before, recreated after, they end up on the new table
    # whatever `legacy_alter_table` is set to. No foreign key in the schema
    # points at `fide_players`, so there is nothing else for a rename to
    # rewrite. DDL is transactional in SQLite: a failure anywhere in here
    # rolls the lot back and the old list stays live.
    Repo.transaction(fn ->
      Enum.each(triggers, fn
        %{name: nil} -> :ok
        %{name: name} -> Repo.query!("DROP TRIGGER #{name}")
      end)

      Repo.query!("ALTER TABLE #{@rows_table} RENAME TO #{@rows_retired_table}")
      Repo.query!("ALTER TABLE #{@rows_scratch_table} RENAME TO #{@rows_table}")
      Repo.query!("ALTER TABLE #{@fts_table} RENAME TO #{@fts_retired_table}")
      Repo.query!("ALTER TABLE #{@fts_scratch_table} RENAME TO #{@fts_table}")

      Enum.each(triggers, fn %{sql: sql} -> Repo.query!(sql) end)
    end)

    # Cosmetic from here on: the swap already made the new list live. If a
    # hard kill lands before this runs, the cleanup at the top of the next
    # run drops them instead.
    drop_scratch_tables()

    {:ok, %{state | imported_rows: imported}}
  end

  defp drop_scratch_tables do
    for table <- [
          @fts_scratch_table,
          @fts_retired_table,
          @rows_scratch_table,
          @rows_retired_table
        ] do
      Repo.query!("DROP TABLE IF EXISTS #{table}")
    end

    :ok
  end

  # Same columns as the migration that created `fide_players`, and the same
  # two indexes as the migrations that added them. Index names are global in
  # SQLite and cannot be renamed, so the scratch copy cannot reuse the live
  # names while the live table still holds them: each run takes whichever of
  # `name` / `name_b` the live table is NOT using, and that name simply
  # stays with the table after the swap. The names carry no meaning to
  # anything but a migration that drops them by name.
  defp create_scratch_rows_table do
    Repo.query!("""
    CREATE TABLE #{@rows_scratch_table} (
      fide_id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      federation TEXT NOT NULL DEFAULT '',
      sex TEXT NOT NULL DEFAULT '',
      title TEXT NOT NULL DEFAULT '',
      standard_rating INTEGER,
      rapid_rating INTEGER,
      blitz_rating INTEGER,
      birth_year INTEGER,
      flag TEXT NOT NULL DEFAULT ''
    )
    """)

    %{rows: live} =
      Repo.query!("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?", [
        @rows_table
      ])

    live = List.flatten(live)

    for {base, columns} <- @row_indexes do
      name = if base in live, do: base <> "_b", else: base
      Repo.query!("CREATE INDEX #{name} ON #{@rows_scratch_table} (#{columns})")
    end

    :ok
  end

  # One multi-row `INSERT ... VALUES (?, ?), (?, ?), ...` per chunk - the
  # same shape `Repo.insert_all/3` above generates for `fide_players`.
  # `fide_players_fts_new` is a scratch virtual table, not part of the
  # persistent schema, so it has no Ecto schema module to insert through.
  defp insert_fts_chunk(chunk) do
    placeholders = chunk |> Enum.map(fn _row -> "(?, ?)" end) |> Enum.join(", ")
    params = Enum.flat_map(chunk, fn row -> [row.fide_id, row.name] end)

    Repo.query!(
      "INSERT INTO #{@fts_scratch_table}(fide_id, name) VALUES " <> placeholders,
      params
    )
  end

  # The `fide_players` triggers that maintain `fide_players_fts`, read back
  # from the schema so `import_list/3` can drop and restore them verbatim
  # without duplicating the migration's definitions here. Empty list (a no-op
  # on both sides) if the FTS migration hasn't run.
  # The last-resort copies of the three `fide_players_fts` triggers, kept
  # byte-for-byte as `20260726090000_create_fide_players_fts.exs` wrote them.
  #
  # Reading them back from `sqlite_master` is still the preferred source, so
  # an ordinary run restores exactly what the database had even if the
  # migration's definition later changes. But capture cannot be the ONLY
  # source. `do_import_list/4` drops these before its bulk load and recreates
  # them after, and there is no surrounding transaction any more: a hard kill
  # in between - `cancel_import/0` uses `Process.exit(pid, :kill)`, which no
  # `after` block survives - leaves them gone from `sqlite_master`. The next
  # run would then capture an empty list, drop nothing, and recreate nothing,
  # cementing the loss rather than repairing it. From that point every
  # single-row write to `fide_players` would leave the search index stale,
  # silently and permanently.
  @fts_trigger_fallback [
    """
    CREATE TRIGGER fide_players_fts_ai AFTER INSERT ON fide_players BEGIN
      INSERT INTO fide_players_fts(fide_id, name) VALUES (new.fide_id, new.name);
    END
    """,
    """
    CREATE TRIGGER fide_players_fts_ad AFTER DELETE ON fide_players BEGIN
      DELETE FROM fide_players_fts WHERE fide_id = old.fide_id;
    END
    """,
    """
    CREATE TRIGGER fide_players_fts_au AFTER UPDATE ON fide_players BEGIN
      DELETE FROM fide_players_fts WHERE fide_id = old.fide_id;
      INSERT INTO fide_players_fts(fide_id, name) VALUES (new.fide_id, new.name);
    END
    """
  ]

  @doc false
  # Exposed for `PairingsEngine.Fide.FtsTriggerRecoveryTest`, which checks
  # that a run killed between the drop and the recreate can still be
  # recovered from. Not part of the module's API.
  def fts_triggers_for_test, do: fts_triggers()

  defp fts_triggers do
    %{rows: rows} =
      Repo.query!("""
      SELECT name, sql FROM sqlite_master
      WHERE type = 'trigger' AND tbl_name = 'fide_players' AND sql IS NOT NULL
      ORDER BY name
      """)

    case rows do
      [] ->
        # Nothing to capture means a previous run was killed between the drop
        # and the recreate. Say so - this is the one moment the loss can be
        # noticed and undone.
        Logger.warning(
          "fide_players has no FTS triggers; a previous import was probably " <>
            "interrupted. Restoring them from the built-in definitions."
        )

        Enum.map(@fts_trigger_fallback, &%{name: nil, sql: &1})

      rows ->
        Enum.map(rows, fn [name, sql] -> %{name: name, sql: sql} end)
    end
  end

  # Column offsets are derived from the header line so a layout change
  # between months doesn't silently corrupt fields.
  defp column_offsets(header) do
    {starts, _} =
      Enum.reduce(@header_labels, {%{}, 0}, fn label, {acc, from} ->
        case :binary.match(header, label, scope: {from, byte_size(header) - from}) do
          {idx, len} -> {Map.put(acc, label, idx), idx + len}
          :nomatch -> raise "FIDE list header is missing the \"#{label}\" column"
        end
      end)

    for {field, label} <- @field_labels, into: %{} do
      next_label = next_label(label)
      start = Map.fetch!(starts, label)
      stop = if next_label, do: Map.fetch!(starts, next_label), else: :eol
      {field, {start, stop}}
    end
  end

  defp next_label(label) do
    idx = Enum.find_index(@header_labels, &(&1 == label))
    Enum.at(@header_labels, idx + 1)
  end

  defp parse_line(line, offsets) do
    for {field, {start, stop}} <- offsets, into: %{} do
      len = if stop == :eol, do: byte_size(line) - start, else: stop - start

      raw =
        if len > 0 and start < byte_size(line) do
          line
          |> binary_part(start, min(len, byte_size(line) - start))
          |> :unicode.characters_to_binary(:latin1, :utf8)
          |> String.trim()
        else
          ""
        end

      value =
        if field in @numeric do
          case Integer.parse(raw) do
            {n, _} -> n
            :error -> nil
          end
        else
          raw
        end

      {field, value}
    end
  end

  defp format_int(n),
    do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ".")
end
