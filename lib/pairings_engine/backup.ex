defmodule PairingsEngine.Backup do
  @moduledoc """
  Backups of everything that cannot be rebuilt.

  Until 2026-08-29 there were none. Seventeen tournaments, their results, the
  registration queue and every OpenResults key lived on one SQLite file on one
  machine, and the keys are the only thing that can withdraw a published
  tournament - lose the file and an arbiter cannot take their own event off the
  public web.

  ## What is in a backup, and what is deliberately not

  The database is 219 MB and **207 MB of that is the FIDE and KBSB rating
  lists**, which are downloaded copies of somebody else's data. Backing them up
  nightly would be a fifth of a gigabyte a day to preserve something a sync
  rebuilds in minutes.

  So the rating tables are **emptied, not dropped**. That distinction is
  load-bearing: `schema_migrations` still records the migrations that created
  them, so a restored database whose tables were dropped would not match its
  own migration history and the app would not boot. An empty table is a valid
  table, and the next sync fills it.

  What is left - tournaments, players, rounds, pairings, results, snapshots,
  registrations, keys, audit log, settings - is about 12 MB, which is small
  enough to keep a month of: `prune/1` keeps 30 days by default.

  ## The two keys that are deliberately left out

  A desktop copy publishing without a token holds an installation key of its
  own (`PairingsEngine.Publishing.Installation`), and every `meta` row
  belonging to it is deleted from the copy before it is written. Tournament
  keys stay in, on purpose: a rebuilt laptop has to be able to manage what
  it published. An installation key is the opposite case - it IS the
  machine, as far as the results site is concerned, so a backup restored on
  another computer would make that computer this installation, and a backup
  is made precisely so it can leave. The contract
  (`docs/public-publishing.md` in OpenResults) says a restore never carries
  it. The price is that restoring onto the same machine does not bring it
  back either: that machine registers again, and the operator moves all of
  its tournaments across in one step (`Moderation.transfer_all/3` there) -
  the same move a dead laptop needs.

  **The OpenResults operator token** (`meta`, `openresults_token`) goes too,
  since 2026-09-13. It is the results site's master key - it publishes to,
  overwrites and deletes ANY tournament there, break-glass included - and the
  restore drill found it in plain text in every production backup, which
  Connections hands to any administrator who asks and the deploy never
  encrypts. A backup needs no copy of it: the operator holds it in the
  results site's own environment, the deploy writes it again on every run
  (`mix pairings.publishing --ensure`), and a restore now ends by setting it
  again (`docs/deployment.md`, "Restoring a backup"). Until then a restored
  hosted copy publishes nothing, and says so on Connections. The address it
  publishes to stays in: it is not a secret, and it is half of what the
  token has to be re-entered beside.

  ## Why the file is a database rather than a dump

  A backup is only worth what its restore is worth. This produces a real SQLite
  file, so restoring is a verified copy rather than a replay of statements that
  may not apply cleanly to a schema that has moved on. `verify/1` opens a
  candidate and checks it before anything is put anywhere.

  ## Why restoring does not swap the live file

  Because a SQLite file cannot be replaced underneath an open connection pool
  without risking corruption of the thing you are trying to save.
  `restore/1` writes the recovered database *beside* the live one and returns
  the path. The swap is the operator's, and it is more than the three
  commands this once claimed - `docs/deployment.md`, "Restoring a backup", is
  the procedure, and the 2026-09-13 drill (`docs/restore-drill-2026-09-13.md`)
  is why each step is there:

    * the live database's `-wal` and `-shm` files move WITH it. SQLite pairs a
      database with whatever `-wal` sits beside it and has no way to tell that
      one belongs to a different file: the drill put a restored database next
      to the old one's WAL and SQLite read the OLD database back under the
      restored file's name, with the integrity check saying "ok".
    * `mix ecto.migrate` runs before the start. `mix phx.server` does not
      migrate, and a backup older than the code used to boot, answer HTTP
      and fail every tournament page; a production run now refuses to start
      on it instead (`PairingsEngine.Application`).

  ## What verify/1 checks

  That the file is ours, that it decrypts and decompresses, that the tables no
  version of this app has run without are there, and that every page of the
  database reads back - `PRAGMA integrity_check`. The last one was missing
  until the drill: a backup of a database with one damaged table verified,
  restored, and failed its first query against that table.

  ## Encryption

  Opt-in, via `PAIRINGS_BACKUP_PASSPHRASE`. It matters because these files
  carry the one piece of personal data in the system - the email addresses
  people gave the entry form - so a backup left on a laptop or copied to a USB
  stick is worth encrypting. AES-256-GCM with a PBKDF2 key; the tag is checked
  on the way back, so a corrupted or tampered file fails loudly rather than
  restoring something subtly wrong.

  Without a passphrase the file is plain, and the moduledoc says so in one
  place so nobody has to guess: **an unencrypted backup contains player email
  addresses.**
  """

  require Logger

  @magic "OPBAK1"
  @cipher :aes_256_gcm
  @pbkdf2_iterations 210_000
  @key_bytes 32
  @salt_bytes 16
  @iv_bytes 12

  # Emptied on the way out. Everything here is a downloaded copy of an
  # external dataset that a sync rebuilds - see the moduledoc for why they are
  # emptied rather than dropped.
  @reproducible ~w(fide_players kbsb_players)

  # The FTS5 index over each of the two tables above. Emptied by deleting from
  # the VIRTUAL table, never from its `_content` / `_data` / `_docsize`
  # shadows - deleting from those leaves an index that is structurally broken
  # rather than empty, and the damage only shows up later as a search that
  # returns nothing.
  #
  # Not `INSERT INTO fts(fts) VALUES('delete-all')`, which is the command for
  # this and does not apply here: it is only legal on a contentless or
  # external-content table, and these own their content. SQLite says so, and
  # the first version of this code ignored that error and shipped backups with
  # 113 MB of index still in them.
  #
  # One entry per line above, one per table here: `kbsb_players_fts` arrived a
  # day after this was written and was not added, so every backup shipped that
  # index intact while emptying the table under it - and a restore left
  # `kbsb_players` empty with ~36k rows still in the index, which is a KBSB
  # search that answers with names no longer in the mirror.
  @fts_tables ~w(fide_players_fts kbsb_players_fts)

  @doc """
  Writes a backup and returns its path.

  Runs `VACUUM INTO` first, which is the only way to take a consistent copy of
  a database that is being written to - a plain file copy of a WAL database can
  catch it mid-transaction.
  """
  @spec create(keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def create(opts \\ []) do
    dir = Keyword.get(opts, :dir, directory())
    source = Keyword.get(opts, :source, database_path())
    stamp = Keyword.get_lazy(opts, :stamp, fn -> DateTime.utc_now() end)

    with :ok <- File.mkdir_p(dir) |> normalise("could not create #{dir}"),
         :ok <- sweep_staging(dir),
         {:ok, staged} <- vacuum_into(source, dir),
         :ok <- strip(staged),
         {:ok, bytes} <- File.read(staged) |> normalise("could not read the staged copy") do
      discard(staged)
      write_envelope(dir, stamp, bytes)
    end
  end

  # A staging copy is a whole database - 219 MB here - so one left behind on
  # every run would fill the disk the backups exist to protect.
  #
  # Removing it immediately is attempted and NOT relied on: a SQLite file can
  # stay briefly locked after the handle holding it is closed, and how briefly
  # is not something to encode as a sleep. `sweep_staging/1` at the start of
  # the next run is what actually guarantees they cannot accumulate, so the
  # worst case is one stale file until the next backup rather than one per run
  # forever.
  defp discard(path) do
    File.rm(path)
    :ok
  end

  # Anything left by a run that crashed, was killed mid-copy, or could not
  # delete its own staging file. Age-gated so a backup running concurrently
  # with this one - which should not happen, but a manual run during the timer
  # would do it - does not have its staging copy pulled out from under it.
  @stale_after_ms :timer.minutes(30)

  defp sweep_staging(dir) do
    now = System.os_time(:millisecond)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, "staging-"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.each(fn path ->
          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime}} when now - mtime * 1000 > @stale_after_ms ->
              if File.rm(path) == :ok do
                Logger.info("Backup removed a stale staging file: #{Path.basename(path)}")
              end

            _ ->
              :ok
          end
        end)

        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc "Every backup on disk, newest first."
  @spec list(keyword()) :: [%{path: Path.t(), size: non_neg_integer(), created_at: DateTime.t()}]
  def list(opts \\ []) do
    dir = Keyword.get(opts, :dir, directory())

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".opbak"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.map(&summarise/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

      {:error, _} ->
        []
    end
  end

  @doc """
  Deletes every backup older than the retention window, except the newest,
  and returns how many went.

  **Retention is an age, in days** (`BACKUP_RETENTION`, 30 by default): a
  backup is kept while it was written less than that many days ago, by the
  time in its own header. Until 2026-09-13 it was a count of files, and every
  boot and every "take one now" spent one, so "30" was a month only on a box
  nobody restarted - a week of deploys was a week of backups (restore drill,
  finding 10). `PairingsEngine.Backup.Scheduler` no longer writes one at a
  boot that already has a recent one, so the window holds about one a day
  plus whatever was taken by hand.

  **The newest is always kept**, whatever its age and whatever `:days` says.
  That is what the count used to guarantee and what an age alone would not: a
  laptop that spent a season in a cupboard comes back with its last backup,
  not with an empty directory. `:days` below one is treated as one - a count
  of 0 used to delete every backup including the one just written, and a
  negative count deleted the newest (finding 9); `config/runtime.exs` refuses
  such a value at boot.

  `opts`: `:days` (default `retention/0`), `:now` for tests, `:dir`.
  """
  @spec prune(keyword()) :: non_neg_integer()
  def prune(opts \\ []) do
    days = opts |> Keyword.get(:days, retention()) |> at_least_one()
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cutoff = DateTime.add(now, -days * 86_400, :second)

    case list(opts) do
      [] ->
        0

      [_newest | older] ->
        older
        |> Enum.filter(&(DateTime.compare(&1.created_at, cutoff) != :gt))
        |> Enum.reduce(0, fn backup, gone ->
          case File.rm(backup.path) do
            :ok -> gone + 1
            {:error, _} -> gone
          end
        end)
    end
  end

  @doc """
  How old the newest backup is, in milliseconds, or `nil` when there is none.
  Never negative: a backup stamped in the future (a clock that stepped back)
  counts as just written.
  """
  @spec newest_age_ms(keyword()) :: non_neg_integer() | nil
  def newest_age_ms(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case list(opts) do
      [] -> nil
      [newest | _] -> max(DateTime.diff(now, newest.created_at, :millisecond), 0)
    end
  end

  @doc """
  Unpacks `path` and checks it is a database this app could actually run on.

  Returns the tables it found, so a caller can say what is in the file rather
  than only whether it opened.

  The check runs on a staging copy in the temp directory, and that copy is the
  whole database - decrypted, for an encrypted backup - so it is deleted on
  every path out, refusals included. It used to survive both: a refusal after
  the file opened never closed its connection, and on Windows even an
  accepted file stayed behind, because the connection was closed with its
  prepared statements still alive and SQLite kept the file open until the
  garbage collector finalised them. The 2026-09-13 drill counted 977 of them,
  303 MB, in one workstation's temp directory.
  """
  @spec verify(Path.t()) ::
          {:ok, %{tables: [String.t()], tournaments: non_neg_integer()}} | {:error, String.t()}
  def verify(path) do
    with {:ok, bytes} <- unpack(path) do
      tmp = Path.join(System.tmp_dir!(), "opbak-verify-#{System.unique_integer([:positive])}.db")

      try do
        with :ok <- File.write(tmp, bytes) |> normalise("could not stage the file") do
          inspect_database(tmp)
        end
      after
        File.rm(tmp)
      end
    end
  end

  defp inspect_database(path) do
    with {:ok, conn} <- open(path) do
      try do
        with {:ok, tables} <- tables(conn),
             :ok <- require_tables(tables),
             :ok <- integrity(conn),
             {:ok, count} <- scalar(conn, "SELECT COUNT(*) FROM tournaments") do
          {:ok, %{tables: tables, tournaments: count}}
        end
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  end

  @doc """
  Recovers `path` to a file beside the live database and returns where.

  Deliberately does not swap it in - see the moduledoc. `mix pairings.backup
  --restore` prints the rest of the procedure with this machine's paths.

  Two things are changed in the copy before it is handed over:

    * **every sign-in is ended** - `users_tokens` is emptied: sessions,
      unused sign-in links, email-change links. A restore brings back the
      rows as they were at the backup, and that includes sessions somebody
      had signed out of, or that a password change had ended since - the
      drill found one valid again, for any browser still holding its cookie.
      Nobody can be signed in by a session the restore resurrected; everyone
      signs in again. Passwords and roles are NOT journalled anywhere, so
      those come back as the backup had them - the procedure says to
      re-apply them.
    * **a marker** in `meta` (`restored_from_backup`): when the backup was
      written and when it was restored, so the app can tell a restored
      database from one that never was (`restored_from/0`).

  And it is switched to WAL, on one connection. `VACUUM INTO` writes a
  rollback-journal database, and the first boot on one had every pooled
  connection trying to make that switch at once: the losers logged "database
  is locked", on exactly the boot an operator is watching most closely.

  `opts` exists for tests: `:database` is the live database the copy goes
  beside, which is otherwise the configured one; `:now`, the restore's time.
  """
  @spec restore(Path.t(), keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def restore(path, opts \\ []) do
    with {:ok, _info} <- verify(path),
         {:ok, bytes, header} <- unpack_with_header(path) do
      target = Keyword.get_lazy(opts, :database, &database_path/0) <> ".restored"
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

      # A `-wal` left beside an earlier `.restored` - somebody opened it to
      # look - would be read into the fresh copy the moment it is opened.
      Enum.each(["-wal", "-shm"], &File.rm(target <> &1))

      with :ok <- File.write(target, bytes) |> normalise("could not write #{target}"),
           :ok <- prepare_restored(target, header, now),
           :ok <- to_wal(target) do
        {:ok, target}
      end
    end
  end

  @restored_marker "restored_from_backup"

  @doc "The `meta` key `restore/1` marks a restored database with."
  def restored_marker, do: @restored_marker

  @doc """
  Whether the running database came out of `restore/1`, and from when:
  `%{backup_created_at: DateTime.t() | nil, restored_at: DateTime.t() | nil}`,
  or `nil` for a database that was never restored. Read through the Repo, so
  it is the live database's answer, not a file's.
  """
  @spec restored_from() ::
          %{backup_created_at: DateTime.t() | nil, restored_at: DateTime.t() | nil} | nil
  def restored_from do
    with value when is_binary(value) <- PairingsEngine.Meta.get(@restored_marker),
         {:ok, %{} = marker} <- Jason.decode(value) do
      %{
        backup_created_at: parse_time(marker["backup_created_at"]),
        restored_at: parse_time(marker["restored_at"])
      }
    else
      _ -> nil
    end
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp prepare_restored(path, header, now) do
    marker =
      Jason.encode!(%{
        "backup_created_at" => header["created_at"],
        "restored_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

    with {:ok, conn} <- open(path) do
      try do
        with {:ok, tables} <- tables(conn),
             :ok <-
               if("users_tokens" in tables, do: run(conn, "DELETE FROM users_tokens"), else: :ok) do
          if "meta" in tables, do: put_meta(conn, @restored_marker, marker), else: :ok
        end
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  end

  defp run(conn, sql) do
    case Exqlite.Sqlite3.execute(conn, sql) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not prepare the restored copy: #{reason_text(reason)}"}
    end
  end

  defp put_meta(conn, key, value) do
    sql =
      "INSERT INTO meta (key, value) VALUES (?1, ?2) " <>
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value"

    with {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Exqlite.Sqlite3.bind(statement, [key, value]),
             :done <- Exqlite.Sqlite3.step(conn, statement) do
          :ok
        else
          {:error, reason} ->
            {:error, "could not mark the restored copy: #{reason_text(reason)}"}

          other ->
            {:error, "could not mark the restored copy: #{inspect(other)}"}
        end
      after
        Exqlite.Sqlite3.release(conn, statement)
      end
    end
  end

  defp to_wal(path) do
    with {:ok, conn} <- open(path) do
      result = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode = WAL")
      Exqlite.Sqlite3.close(conn)

      case result do
        :ok -> :ok
        {:error, reason} -> {:error, "could not switch #{path} to WAL: #{reason_text(reason)}"}
      end
    end
  end

  @doc "Where backups are kept."
  @spec directory() :: Path.t()
  def directory do
    Application.get_env(:pairings_engine, :backup_dir) ||
      Path.join(Path.dirname(database_path()), "backups")
  end

  @doc "How many days a backup is kept - never fewer than one, see `prune/1`."
  @spec retention() :: pos_integer()
  def retention do
    case Application.get_env(:pairings_engine, :backup_retention, 30) do
      n when is_integer(n) -> at_least_one(n)
      _not_a_number -> 30
    end
  end

  defp at_least_one(n) when is_integer(n), do: max(n, 1)

  @doc "Whether backups are written encrypted."
  @spec encrypted?() :: boolean()
  def encrypted?, do: not is_nil(passphrase())

  ## ---------- making one ----------

  defp vacuum_into(source, dir) do
    staged = Path.join(dir, "staging-#{System.unique_integer([:positive])}.db")

    # `VACUUM INTO` is the documented way to take a consistent copy while the
    # database is in use. A `File.cp` of a WAL database can catch it between a
    # commit and its checkpoint and produce a file that opens and is wrong.
    #
    # It needs room for a whole copy - 219 MB here - before anything is
    # stripped. There is no portable way to ask how much disk is free without
    # dragging in `:os_mon` for one call, so instead the failure is made safe:
    # a staging file is removed on any error, so a backup that runs out of
    # space costs a failed run rather than leaving a fifth of a gigabyte behind
    # on the disk it was meant to be protecting.
    # On its OWN connection rather than through `Repo`, for two reasons: a
    # backup should not borrow a pooled connection the application is using to
    # pair a round, and `VACUUM` cannot run inside a transaction, which a
    # pooled connection may well be in.
    with {:ok, conn} <- open(source) do
      result = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '" <> escape(staged) <> "'")
      Exqlite.Sqlite3.close(conn)

      case result do
        :ok ->
          {:ok, staged}

        {:error, reason} ->
          File.rm(staged)
          {:error, "could not copy the database: " <> to_string(reason)}
      end
    end
  end

  # SQLite has no placeholder for VACUUM INTO's target, so the path is
  # interpolated. It comes from configuration rather than from a request, but
  # doubling the quote costs nothing and means a directory with an apostrophe
  # in its name fails to back up rather than failing to parse.
  defp escape(path), do: String.replace(path, "'", "''")

  defp strip(staged) do
    with {:ok, conn} <- open(staged) do
      result = do_strip(conn)
      Exqlite.Sqlite3.close(conn)
      result
    end
  end

  defp do_strip(conn) do
    {:ok, triggers} = trigger_sql(conn)

    # Triggers first: `fide_players` has AFTER DELETE triggers that would fire
    # 1.9 million times and take longer than the rest of the backup put
    # together. Recreated below, because a restored database needs them for the
    # next sync to maintain the index.
    drops = Enum.map(triggers, fn {name, _sql} -> "DROP TRIGGER IF EXISTS #{name}" end)
    empty_fts = Enum.map(@fts_tables, &"DELETE FROM #{&1}")
    empty = Enum.map(@reproducible, &"DELETE FROM #{&1}")
    recreate = for {_name, sql} <- triggers, is_binary(sql), do: sql

    # Before the VACUUM, which is what makes the deleted rows actually gone
    # from the file rather than sitting in a free page. See the moduledoc.
    custody = [installation_strip_sql(), "DELETE FROM meta WHERE key = 'openresults_token'"]

    statements = drops ++ empty_fts ++ empty ++ recreate ++ custody ++ ["VACUUM"]

    # Every failure is reported, none ignored. The first version of this ran
    # `Enum.each` over the statements and threw the return values away, so an
    # FTS command that SQLite rejected outright produced a backup that looked
    # fine and still carried the whole index.
    Enum.reduce_while(statements, :ok, fn sql, :ok ->
      case Exqlite.Sqlite3.execute(conn, sql) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "could not strip the rating lists (#{summarise_sql(sql)}): #{reason}"}}
      end
    end)
  rescue
    error -> {:error, "could not strip the rating lists: #{Exception.message(error)}"}
  end

  # Every `meta` row belonging to this installation's own results-site key -
  # by prefix, so a record added to `Publishing.Installation` later is
  # stripped without anybody remembering to list it here. `_` is a LIKE
  # wildcard, hence the escape.
  defp installation_strip_sql do
    prefix = PairingsEngine.Publishing.Installation.meta_prefix() |> String.replace("_", "\\_")
    "DELETE FROM meta WHERE key LIKE '#{prefix}%' ESCAPE '\\'"
  end

  # Enough of the statement to identify which one failed, without putting a
  # whole trigger body in an error message.
  defp summarise_sql(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.slice(0, 60)

  defp write_envelope(dir, stamp, bytes) do
    compressed = :zlib.gzip(bytes)
    {payload, crypto} = encrypt(compressed)

    header =
      Jason.encode!(%{
        "app" => "openpairings",
        "version" => 1,
        "created_at" => stamp |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "compressed" => true,
        "encrypted" => crypto != nil,
        "emptied" => @reproducible,
        "plain_bytes" => byte_size(bytes),
        "crypto" => crypto
      })

    path = Path.join(dir, "openpairings-#{file_stamp(stamp)}.opbak")

    case File.write(path, @magic <> "\n" <> header <> "\n" <> payload) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp encrypt(payload) do
    case passphrase() do
      nil ->
        {payload, nil}

      secret ->
        salt = :crypto.strong_rand_bytes(@salt_bytes)
        iv = :crypto.strong_rand_bytes(@iv_bytes)
        key = :crypto.pbkdf2_hmac(:sha256, secret, salt, @pbkdf2_iterations, @key_bytes)

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(@cipher, key, iv, payload, @magic, true)

        {ciphertext,
         %{
           "cipher" => "aes-256-gcm",
           "kdf" => "pbkdf2-sha256",
           "iterations" => @pbkdf2_iterations,
           "salt" => Base.encode64(salt),
           "iv" => Base.encode64(iv),
           "tag" => Base.encode64(tag)
         }}
    end
  end

  ## ---------- reading one ----------

  defp unpack(path) do
    with {:ok, bytes, _header} <- unpack_with_header(path), do: {:ok, bytes}
  end

  defp unpack_with_header(path) do
    with {:ok, raw} <- File.read(path) |> normalise("could not read #{path}"),
         {:ok, header, payload} <- split(raw),
         {:ok, compressed} <- decrypt(header, payload) do
      if header["compressed"] do
        try do
          {:ok, :zlib.gunzip(compressed), header}
        rescue
          _ -> {:error, "the backup is corrupt - it did not decompress"}
        end
      else
        {:ok, compressed, header}
      end
    end
  end

  defp split(raw) do
    case String.split(raw, "\n", parts: 3) do
      [@magic, header, payload] ->
        case Jason.decode(header) do
          {:ok, decoded} -> {:ok, decoded, payload}
          {:error, _} -> {:error, "the backup's header is unreadable"}
        end

      _ ->
        {:error, "that is not an OpenPairings backup"}
    end
  end

  defp decrypt(%{"encrypted" => true, "crypto" => crypto}, payload) when is_map(crypto) do
    case passphrase() do
      nil ->
        {:error,
         "this backup is encrypted and no passphrase is configured - set " <>
           "PAIRINGS_BACKUP_PASSPHRASE to the one it was written with"}

      secret ->
        with {:ok, iterations} <- checked_iterations(crypto["iterations"]) do
          salt = Base.decode64!(crypto["salt"])
          iv = Base.decode64!(crypto["iv"])
          tag = Base.decode64!(crypto["tag"])
          key = :crypto.pbkdf2_hmac(:sha256, secret, salt, iterations, @key_bytes)

          # `:error` here means the tag did not check out: a wrong passphrase, a
          # truncated download, or a tampered file. All three deserve the same
          # refusal, and none of them should produce a partly-decrypted database.
          case :crypto.crypto_one_time_aead(@cipher, key, iv, payload, @magic, tag, false) do
            :error ->
              {:error, "wrong passphrase, or the backup has been altered since it was written"}

            plain ->
              {:ok, plain}
          end
        end
    end
  end

  defp decrypt(_header, payload), do: {:ok, payload}

  # The iteration count comes out of the backup file's own header, which is
  # not authenticated - it is read *before* the AEAD tag is checked, because
  # it is what derives the key the tag is checked with. An absurdly low count
  # would weaken a passphrase this file was never actually written with; an
  # absurdly high one turns `restore`/`verify` into a wedge (PBKDF2 has no
  # early exit, and there is no cancel). So bound it either way. The range is
  # deliberately wide - it has to keep accepting every count this app has
  # ever written (@pbkdf2_iterations, 210_000) and leave room for it to rise.
  @min_pbkdf2_iterations 10_000
  @max_pbkdf2_iterations 2_000_000

  defp checked_iterations(nil), do: {:ok, @pbkdf2_iterations}

  defp checked_iterations(n)
       when is_integer(n) and n >= @min_pbkdf2_iterations and n <= @max_pbkdf2_iterations,
       do: {:ok, n}

  defp checked_iterations(n) do
    {:error,
     "this backup's header asks for #{inspect(n)} PBKDF2 iterations, which is outside " <>
       "the accepted range (#{@min_pbkdf2_iterations}-#{@max_pbkdf2_iterations}) - " <>
       "the file is corrupt or has been tampered with"}
  end

  # The first lines only, and the size from the file system: listing used to
  # read every backup whole to find a header of a few hundred bytes, and the
  # scheduler now lists at boot to decide whether one is due.
  @head_bytes 16_384

  defp summarise(path) do
    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, head} <- read_head(path),
         [@magic, header, _] <- String.split(head, "\n", parts: 3),
         {:ok, decoded} <- Jason.decode(header),
         {:ok, created_at, _} <- DateTime.from_iso8601(decoded["created_at"] || "") do
      %{
        path: path,
        size: size,
        created_at: created_at,
        encrypted: decoded["encrypted"] == true
      }
    else
      _ -> nil
    end
  end

  defp read_head(path) do
    File.open(path, [:read, :binary], fn device ->
      case IO.binread(device, @head_bytes) do
        data when is_binary(data) -> data
        _eof_or_error -> ""
      end
    end)
  end

  ## ---------- plumbing ----------

  defp open(path) do
    case Exqlite.Sqlite3.open(path) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, "could not open the database: #{reason_text(reason)}"}
    end
  end

  # Every statement is released before its rows are returned. A connection
  # closed with a statement still prepared is not closed: SQLite defers it
  # until the statement is finalised, which here meant until the garbage
  # collector got round to it - and until then the file stayed open, so on
  # Windows neither `verify/1`'s staging copy nor `create/1`'s could be
  # deleted.
  defp rows(conn, sql) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, statement} ->
        try do
          Exqlite.Sqlite3.fetch_all(conn, statement)
        after
          Exqlite.Sqlite3.release(conn, statement)
        end

      {:error, _} = error ->
        error
    end
  end

  defp tables(conn) do
    case rows(conn, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [name] -> name end)}
      {:error, reason} -> {:error, "could not read the file's tables: #{reason_text(reason)}"}
    end
  end

  defp trigger_sql(conn) do
    case rows(conn, "SELECT name, sql FROM sqlite_master WHERE type = 'trigger'") do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [name, sql] -> {name, sql} end)}
      _ -> {:ok, []}
    end
  end

  defp scalar(conn, sql) do
    case rows(conn, sql) do
      {:ok, [[value]]} -> {:ok, value}
      _ -> {:error, "the file opened but did not answer a simple query"}
    end
  end

  # Every page, not the handful the checks around it touch: the drill's
  # damaged `pairings` and `audit_logs` tables passed them all.
  # `integrity_check` is the thorough form - it also cross-checks every index
  # - and it only ever runs from the command line or a download's check, on a
  # file somebody is about to trust.
  defp integrity(conn) do
    case rows(conn, "PRAGMA integrity_check") do
      {:ok, [["ok"]]} ->
        :ok

      {:ok, problems} ->
        first = problems |> List.flatten() |> Enum.take(3) |> Enum.join("; ")

        {:error,
         "the database inside fails its integrity check (#{first}) - restoring it would " <>
           "put a damaged database live; try an older backup"}

      {:error, reason} ->
        {:error,
         "the database inside could not be read through (#{reason_text(reason)}) - restoring " <>
           "it would put a damaged database live; try an older backup"}
    end
  end

  # SQLite's messages arrive as binaries that are not always printable - the
  # drill's damaged file produced `<<109, 97, 108, 102, ...>>` where
  # "malformed" was meant.
  defp reason_text(reason) when is_binary(reason) do
    text = String.replace(reason, <<0>>, "")
    if String.printable?(text), do: text, else: inspect(reason)
  end

  defp reason_text(reason), do: inspect(reason)

  # The tables whose absence means this is not a database this app could run
  # on. Not the full list on purpose - a backup from a slightly older schema
  # should still restore, and demanding every table would refuse exactly the
  # backups somebody reaches for in an emergency.
  @required ~w(tournaments players rounds pairings schema_migrations)

  defp require_tables(tables) do
    case Enum.reject(@required, &(&1 in tables)) do
      [] ->
        :ok

      missing ->
        {:error, "that file is missing #{Enum.join(missing, ", ")} - it is not one of ours"}
    end
  end

  defp database_path do
    Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database] || "pairings_engine.db"
  end

  defp passphrase do
    case Application.get_env(:pairings_engine, :backup_passphrase) do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> nil
    end
  end

  defp file_stamp(stamp) do
    stamp
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(":", "-")
  end

  defp normalise(:ok, _message), do: :ok
  defp normalise({:ok, value}, _message), do: {:ok, value}

  defp normalise({:error, reason}, message),
    do: {:error, "#{message}: #{:file.format_error(reason)}"}
end
