defmodule PairingsEngine.Fide.Sync do
  @moduledoc """
  Downloads the combined FIDE rating list (TXT format, published monthly on
  ratings.fide.com) and loads it into the local fide_players table.

  Progress is broadcast on the "fide_sync" PubSub topic and queryable via
  `status/0`.
  """

  use GenServer
  require Logger
  alias PairingsEngine.{Repo, Fide}
  alias PairingsEngine.Fide.FidePlayer

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

  defstruct status: :idle,
            progress: "",
            error: nil,
            loaded_bytes: 0,
            total_bytes: 0,
            imported_rows: 0,
            total_rows: 0,
            task_pid: nil,
            task_ref: nil,
            watchdog_timer: nil

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
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:start_sync, %{status: s} = state) when s in [:downloading, :importing] do
    {:noreply, state}
  end

  def handle_cast(:start_sync, _state) do
    server = self()
    {pid, ref} = spawn_monitor(fn -> run_sync(server) end)

    state = %__MODULE__{
      status: :downloading,
      progress: "Contacting #{source_label()}…",
      task_pid: pid,
      task_ref: ref,
      watchdog_timer: schedule_watchdog()
    }

    {:noreply, broadcast(state)}
  end

  @impl true
  def handle_cast(:cancel_sync, %{status: s, task_pid: pid, watchdog_timer: timer})
      when s in [:downloading, :importing] do
    cancel_watchdog(timer)
    if pid, do: Process.exit(pid, :kill)
    {:noreply, broadcast(%__MODULE__{status: :idle})}
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

  # Safety net for exits that bypass run_sync's `rescue` (e.g. the task being
  # killed, or an exit signal from the HTTP client) - without this, a crashed
  # task would leave the GenServer stuck in :downloading/:importing forever
  # and the "Update" button would never re-enable.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state)
      when reason != :normal do
    cancel_watchdog(state.watchdog_timer)
    Logger.error("FIDE sync task crashed: #{inspect(reason)}")

    new_state = %__MODULE__{
      status: :error,
      error: "Sync crashed unexpectedly (#{inspect(reason)}). Please try again."
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
    state
  end

  defp update(server, state) do
    send(server, {:sync_update, state})
    state
  end

  ## The sync job (runs in its own task)

  defp run_sync(server) do
    state = %__MODULE__{status: :downloading}

    with {:ok, zip, state} <- download(server, state),
         {:ok, text, state} <- unpack(server, zip, state),
         {:ok, state} <- import_list(server, text, state) do
      Fide.put_last_sync()
      update(server, %{state | status: :done, progress: ""})
    else
      {:error, reason} ->
        Logger.error("FIDE sync failed: #{inspect(reason)}")
        update(server, %__MODULE__{status: :error, error: format_error(reason)})
    end
  rescue
    e ->
      Logger.error("FIDE sync crashed: #{Exception.message(e)}")
      update(server, %__MODULE__{status: :error, error: Exception.message(e)})
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

  defp resp_content_length(resp) do
    case Req.Response.get_header(resp, "content-length") do
      [len | _] -> String.to_integer(len)
      _ -> 0
    end
  end

  defp unpack(server, zip, state) do
    state = update(server, %{state | status: :importing, progress: "Unpacking…"})

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
  # transaction/count-guard logic directly with synthetic FIDE-list text,
  # without going through the real HTTP download+unpack - see
  # PairingsEngine.Fide.SyncTest. Not part of the module's intended public API.
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

    # Snapshot the cache size *before* the transaction touches anything, so
    # a corrupt/truncated download that still parses a valid header but
    # yields few/no usable data rows can be detected and rolled back rather
    # than silently wiping the whole local cache - see the guard below.
    current_count = Repo.aggregate(FidePlayer, :count)

    Repo.transaction(
      fn ->
        # The `fide_players_fts` triggers are per-row, and the delete/update
        # ones look the doomed row up with `WHERE fide_id = ?` on a column the
        # FTS5 table declares UNINDEXED - so each firing scans the whole index.
        # Fine for the ad-hoc single-row writes they exist for; quadratic for
        # this full replace, which fires them ~1.9M times and never finishes.
        # Suspend them, do the bulk work set-based, then put them back.
        #
        # Safe because it all rides the surrounding transaction: SQLite makes
        # DDL transactional, so a rollback (including the guards below)
        # restores the triggers along with the rows. They're captured from
        # `sqlite_master` rather than written out here, so they always go back
        # exactly as the migration defined them, even if that changes.
        triggers = fts_triggers()
        Enum.each(triggers, fn %{name: name} -> Repo.query!("DROP TRIGGER #{name}") end)

        # Full replace: the monthly list is authoritative (players do get removed).
        Repo.query!("DELETE FROM fide_players")
        Repo.query!("DELETE FROM fide_players_fts")

        imported =
          rows
          |> Stream.chunk_every(2000)
          |> Stream.with_index(1)
          |> Enum.reduce(0, fn {chunk, i}, acc ->
            Repo.insert_all(FidePlayer, chunk,
              on_conflict: :replace_all,
              conflict_target: :fide_id
            )

            # Real running total (not an i * 2000 approximation, which
            # overcounts on a partial final chunk) - also what the
            # zero-row/big-drop guard below checks.
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

        cond do
          imported == 0 ->
            Repo.rollback(
              "FIDE import produced zero usable player rows - the downloaded file may be " <>
                "corrupt or truncated. The existing #{format_int(current_count)}-player " <>
                "cache was left untouched."
            )

          current_count > 0 and imported < div(current_count, 2) ->
            Repo.rollback(
              "FIDE import only produced #{format_int(imported)} usable player rows, far " <>
                "fewer than the existing #{format_int(current_count)}-player cache - the " <>
                "downloaded file may be corrupt or truncated. The existing cache was left " <>
                "untouched."
            )

          true ->
            # Only worth rebuilding the index once the import is known good -
            # the guards above roll back, which would throw this away anyway.
            update(server, %{
              state
              | imported_rows: imported,
                progress: "Rebuilding the name index…"
            })

            Repo.query!(
              "INSERT INTO fide_players_fts(fide_id, name) SELECT fide_id, name FROM fide_players"
            )

            Enum.each(triggers, fn %{sql: sql} -> Repo.query!(sql) end)

            imported
        end
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, imported} -> {:ok, %{state | imported_rows: imported}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The `fide_players` triggers that maintain `fide_players_fts`, read back
  # from the schema so `import_list/3` can drop and restore them verbatim
  # without duplicating the migration's definitions here. Empty list (a no-op
  # on both sides) if the FTS migration hasn't run.
  defp fts_triggers do
    %{rows: rows} =
      Repo.query!("""
      SELECT name, sql FROM sqlite_master
      WHERE type = 'trigger' AND tbl_name = 'fide_players' AND sql IS NOT NULL
      ORDER BY name
      """)

    Enum.map(rows, fn [name, sql] -> %{name: name, sql: sql} end)
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
