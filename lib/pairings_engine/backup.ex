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
  enough to keep a month of.

  ## Why the file is a database rather than a dump

  A backup is only worth what its restore is worth. This produces a real SQLite
  file, so restoring is a verified copy rather than a replay of statements that
  may not apply cleanly to a schema that has moved on. `verify/1` opens a
  candidate and checks it before anything is put anywhere.

  ## Why restoring does not swap the live file

  Because a SQLite file cannot be replaced underneath an open connection pool
  without risking corruption of the thing you are trying to save.
  `restore/1` writes the recovered database *beside* the live one and returns
  the path. Stopping the service, swapping and starting again is three
  commands and cannot go wrong halfway.

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

  # The FTS5 index over `fide_players`. Emptied by deleting from the VIRTUAL
  # table, never from its `_content` / `_data` / `_docsize` shadows - deleting
  # from those leaves an index that is structurally broken rather than empty,
  # and the damage only shows up later as a search that returns nothing.
  #
  # Not `INSERT INTO fts(fts) VALUES('delete-all')`, which is the command for
  # this and does not apply here: it is only legal on a contentless or
  # external-content table, and this one owns its content. SQLite says so, and
  # the first version of this code ignored that error and shipped backups with
  # 113 MB of index still in them.
  @fts_tables ~w(fide_players_fts)

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
  Deletes all but the newest `keep`, returning how many went.

  Retention is a count rather than an age on purpose: a machine that has been
  switched off for a fortnight should still have its last backups when it comes
  back, and an age rule would have thrown them away.
  """
  @spec prune(keyword()) :: non_neg_integer()
  def prune(opts \\ []) do
    keep = Keyword.get(opts, :keep, retention())

    list(opts)
    |> Enum.drop(keep)
    |> Enum.map(& &1.path)
    |> Enum.reduce(0, fn path, gone ->
      case File.rm(path) do
        :ok -> gone + 1
        {:error, _} -> gone
      end
    end)
  end

  @doc """
  Unpacks `path` and checks it is a database this app could actually run on.

  Returns the tables it found, so a caller can say what is in the file rather
  than only whether it opened.
  """
  @spec verify(Path.t()) ::
          {:ok, %{tables: [String.t()], tournaments: non_neg_integer()}} | {:error, String.t()}
  def verify(path) do
    with {:ok, bytes} <- unpack(path) do
      tmp = Path.join(System.tmp_dir!(), "opbak-verify-#{System.unique_integer([:positive])}.db")

      try do
        with :ok <- File.write(tmp, bytes) |> normalise("could not stage the file"),
             {:ok, conn} <- open(tmp),
             {:ok, tables} <- tables(conn),
             :ok <- require_tables(tables),
             {:ok, count} <- scalar(conn, "SELECT COUNT(*) FROM tournaments") do
          Exqlite.Sqlite3.close(conn)
          {:ok, %{tables: tables, tournaments: count}}
        end
      after
        File.rm(tmp)
      end
    end
  end

  @doc """
  Recovers `path` to a file beside the live database and returns where.

  Deliberately does not swap it in - see the moduledoc. The caller is told the
  path and the three commands.
  """
  @spec restore(Path.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def restore(path) do
    with {:ok, _info} <- verify(path),
         {:ok, bytes} <- unpack(path) do
      target = database_path() <> ".restored"

      case File.write(target, bytes) do
        :ok -> {:ok, target}
        {:error, reason} -> {:error, "could not write #{target}: #{:file.format_error(reason)}"}
      end
    end
  end

  @doc "Where backups are kept."
  @spec directory() :: Path.t()
  def directory do
    Application.get_env(:pairings_engine, :backup_dir) ||
      Path.join(Path.dirname(database_path()), "backups")
  end

  @doc "How many are kept."
  @spec retention() :: pos_integer()
  def retention, do: Application.get_env(:pairings_engine, :backup_retention, 30)

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

    statements = drops ++ empty_fts ++ empty ++ recreate ++ ["VACUUM"]

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
    with {:ok, raw} <- File.read(path) |> normalise("could not read #{path}"),
         {:ok, header, payload} <- split(raw),
         {:ok, compressed} <- decrypt(header, payload) do
      if header["compressed"] do
        try do
          {:ok, :zlib.gunzip(compressed)}
        rescue
          _ -> {:error, "the backup is corrupt - it did not decompress"}
        end
      else
        {:ok, compressed}
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
        salt = Base.decode64!(crypto["salt"])
        iv = Base.decode64!(crypto["iv"])
        tag = Base.decode64!(crypto["tag"])
        iterations = crypto["iterations"] || @pbkdf2_iterations
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

  defp decrypt(_header, payload), do: {:ok, payload}

  defp summarise(path) do
    with {:ok, raw} <- File.read(path),
         [@magic, header, _] <- String.split(raw, "\n", parts: 3),
         {:ok, decoded} <- Jason.decode(header),
         {:ok, created_at, _} <- DateTime.from_iso8601(decoded["created_at"] || "") do
      %{
        path: path,
        size: byte_size(raw),
        created_at: created_at,
        encrypted: decoded["encrypted"] == true
      }
    else
      _ -> nil
    end
  end

  ## ---------- plumbing ----------

  defp open(path) do
    case Exqlite.Sqlite3.open(path) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, "could not open the database: #{inspect(reason)}"}
    end
  end

  defp tables(conn) do
    with {:ok, statement} <-
           Exqlite.Sqlite3.prepare(
             conn,
             "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
           ),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(conn, statement) do
      {:ok, Enum.map(rows, fn [name] -> name end)}
    else
      {:error, reason} -> {:error, "could not read the file's tables: #{inspect(reason)}"}
    end
  end

  defp trigger_sql(conn) do
    with {:ok, statement} <-
           Exqlite.Sqlite3.prepare(
             conn,
             "SELECT name, sql FROM sqlite_master WHERE type = 'trigger'"
           ),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(conn, statement) do
      {:ok, Enum.map(rows, fn [name, sql] -> {name, sql} end)}
    else
      _ -> {:ok, []}
    end
  end

  defp scalar(conn, sql) do
    with {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, sql),
         {:ok, [[value]]} <- Exqlite.Sqlite3.fetch_all(conn, statement) do
      {:ok, value}
    else
      _ -> {:error, "the file opened but did not answer a simple query"}
    end
  end

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
