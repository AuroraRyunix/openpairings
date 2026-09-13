defmodule PairingsEngine.Desktop.DataHome do
  @moduledoc """
  Where a Windows desktop install keeps its tournaments, and the one-time move
  that takes them out of reach of every installer.

  ## Why the data moved (2026-09-13)

  Until 0.62 the data lived in `%LOCALAPPDATA%\\OpenPairings`, and two
  different installers could delete that directory whole:

    * **Setup.exe packed as `--packId OpenPairings`** (0.53.x, built locally,
      never attached to a release). Velopack installs to
      `%LOCALAPPDATA%\\<packId>`, which made the data directory the install
      directory, and `Update.exe --uninstall` empties its install directory.
    * **Every `.msi` from 0.58.1 to 0.61.0.** vpk 1.2.0's WiX template sets
      the MSI property `RustAppId` to the pack *title* ("OpenPairings"), not
      the pack id, and its `CleanupDeferred` custom action deletes
      `%LOCALAPPDATA%\\<RustAppId>` on every `REMOVE=ALL` - an uninstall, and
      also the removal of the old product that a major upgrade performs.
      Read from the MSI tables and velopack's own `src/wix-dll/src/lib.rs` at
      tag 1.2.0; see `rel/windows/build_installer.ps1`.

  Already-installed MSIs carry that custom action in Windows' cached copy of
  the package, where nothing this project ships can reach it. The only
  complete protection is for the data not to be at that path, so it moves to
  `%LOCALAPPDATA%\\OpenPairingsData`, and backups to
  `%LOCALAPPDATA%\\OpenPairingsBackups` - neither a pack id nor a pack title
  any installer uses, and the build refuses to pack one that would.

  ## How it moves, and why it is crash-safe

  The move is **one directory rename**, `OpenPairings` -> `OpenPairingsData`,
  in the same parent. On NTFS that is a single journaled metadata operation:
  after a crash, a power cut or a kill, the directory has one name or the
  other, never half of each, and not a byte of the database is rewritten.
  That is strictly safer than copy-verify-switch, which has a window where two
  diverging copies exist. Nothing is ever deleted.

  The rename refuses when anything inside holds a file open (a running
  OpenPairings) or when `OpenPairingsData` already exists. Both leave
  everything where it was: this run reads the old location (the fallback),
  and the next start tries again.

  The one case a rename can never succeed is this program running from inside
  the old directory - an old-id install that updated itself to this version.
  Only then is the data copied instead: `VACUUM INTO` a staging directory,
  `PRAGMA integrity_check` on the copy, the row count of every table compared
  with the original, every other file compared byte for byte, and only then
  the staging directory renamed to `OpenPairingsData` - which is the commit
  point, and atomic for the same reason as above. The original is left
  exactly where it was.

  The same rename runs in three places, in this order of who gets there
  first: the `.msi` (`OpenPairings.exe --protect-data`, before it removes an
  older product), the launcher (before it opens its log), and here (for the
  portable `.bat` and the single-file binary, which have no launcher). They
  agree because each one is "rename if the new name is free, else leave it".
  """

  require Logger

  @legacy_name "OpenPairings"
  @home_name "OpenPairingsData"
  @backups_name "OpenPairingsBackups"

  # The staging directory's name, and a file written into it before anything
  # else - the two things `remove_staging/2` insists on before it will delete
  # a directory. See that function.
  @staging_prefix @home_name <> ".staging-"
  @staging_sentinel ".openpairings-staging"

  # What makes a directory worth moving: any one of these. A directory holding
  # only a launcher.log (an old launcher ran and nothing else did) or only
  # Velopack's program files (an old-id install that was never started) has no
  # tournaments in it, and moving program files for nothing is not free.
  @data_markers ["openpairings.db", "secret_key_base", "backups"]

  # Velopack's own layout in an install root. After an old-id install's
  # directory is renamed these sit inside the data directory, where they do
  # nothing; `tidy_program_files/1` moves them into one subfolder.
  @velopack_program_files [
    "current",
    "packages",
    "Update.exe",
    "OpenPairings.exe",
    ".msi-installed"
  ]
  @program_files_folder "old-program-files"

  @type layout :: %{legacy: Path.t(), home: Path.t(), backups: Path.t(), parent: Path.t()}

  @doc "The three directories, under one `%LOCALAPPDATA%`."
  @spec layout(Path.t()) :: layout()
  def layout(local_app_data) do
    parent = Path.expand(local_app_data)

    %{
      parent: parent,
      legacy: Path.join(parent, @legacy_name),
      home: Path.join(parent, @home_name),
      backups: Path.join(parent, @backups_name)
    }
  end

  @doc """
  Which directory to read, touching nothing. `config/runtime.exs` repeats this
  decision inline (it cannot call application modules), and
  `PairingsEngine.Desktop.DataHomeTest` holds the two together.
  """
  @spec choose(layout()) :: Path.t()
  def choose(%{legacy: legacy, home: home}) do
    cond do
      File.dir?(home) -> home
      has_data?(legacy) -> legacy
      true -> home
    end
  end

  @doc "Whether `dir` holds anything of an arbiter's."
  @spec has_data?(Path.t()) :: boolean()
  def has_data?(dir), do: Enum.any?(@data_markers, &File.exists?(Path.join(dir, &1)))

  @doc """
  Makes `layout.home` the data directory if it can, and says what happened.

  Options:

    * `:running_from` - the running release's root (`RELEASE_ROOT`). Only
      when it lies inside the old directory is a copy attempted; any other
      reason the rename fails is somebody else holding the files, and copying
      a database another process is writing to is how two versions of a
      tournament are made.

  Returns `{outcome, home}`, where `home` is the directory to use now:

    * `:already` - `OpenPairingsData` existed.
    * `:renamed` - moved by this call.
    * `:copied` - copied and verified by this call (see the moduledoc).
    * `:fresh` - nothing anywhere; `OpenPairingsData` created empty.
    * `{:fallback, reason}` - could not move; `home` is the old directory.
  """
  @spec secure(layout(), keyword()) :: {atom() | {:fallback, term()}, Path.t()}
  def secure(%{legacy: legacy, home: home} = layout, opts \\ []) do
    clean_stale_staging(layout)

    cond do
      File.dir?(home) ->
        {:already, home}

      has_data?(legacy) ->
        move(layout, opts)

      true ->
        File.mkdir_p!(home)
        {:fresh, home}
    end
  end

  defp move(%{legacy: legacy, home: home} = layout, opts) do
    case File.rename(legacy, home) do
      :ok ->
        Logger.warning("Moved the OpenPairings data directory from #{legacy} to #{home}.")
        {:renamed, home}

      {:error, reason} ->
        if inside?(opts[:running_from], legacy) do
          case copy_verify_switch(layout) do
            :ok ->
              {:copied, home}

            {:error, why} ->
              Logger.error("Could not copy the data directory to #{home}: #{why}")
              {{:fallback, why}, legacy}
          end
        else
          Logger.warning(
            "Could not move #{legacy} to #{home} (#{inspect(reason)}); " <>
              "using it where it is and trying again next start."
          )

          {{:fallback, reason}, legacy}
        end
    end
  end

  ## ---------- the copy, for the one case a rename cannot work ----------

  @doc false
  # Public for the test that drives it without having to run a release from
  # inside the directory it copies.
  @spec copy_verify_switch(layout()) :: :ok | {:error, String.t()}
  def copy_verify_switch(%{parent: parent} = layout) do
    staging =
      Path.join(parent, @staging_prefix <> Integer.to_string(System.unique_integer([:positive])))

    case do_copy_verify_switch(layout, staging) do
      :ok ->
        :ok

      {:error, _} = error ->
        # Nothing in it that is not still in the original; see
        # `remove_staging/2` for what has to be true before it is deleted.
        _ = remove_staging(layout, staging)
        error
    end
  end

  defp do_copy_verify_switch(%{legacy: legacy, home: home}, staging) do
    with :ok <- File.mkdir(staging),
         :ok <- File.write(Path.join(staging, @staging_sentinel), ""),
         :ok <- copy_database(legacy, staging),
         :ok <- copy_other_files(legacy, staging),
         :ok <- File.write(Path.join(staging, "MOVED-FROM.txt"), moved_from_note(legacy)),
         # The commit point. `home` does not exist (checked by the caller), so
         # this is a plain rename and cannot land half-way. The sentinel goes
         # with it and is removed after: a staging directory keeps it right
         # up to the rename, so every leftover is one `remove_staging/2` may
         # clean, and inside `home` the file is inert - that function refuses
         # the data directory by name and by path whatever it contains.
         :ok <- rename_dir(staging, home) do
      _ = File.rm(Path.join(home, @staging_sentinel))
      _ = File.write(Path.join(legacy, "DATA-MOVED.txt"), moved_to_note(home))
      Logger.warning("Copied the OpenPairings data directory from #{legacy} to #{home}.")
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp rename_dir(from, to) do
    case File.rename(from, to) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "could not rename the verified copy into place: #{inspect(reason)}"}
    end
  end

  @db "openpairings.db"
  @sqlite_side_files ["openpairings.db-wal", "openpairings.db-shm", "openpairings.db-journal"]

  defp copy_database(legacy, staging) do
    source = Path.join(legacy, @db)

    if File.exists?(source) do
      target = Path.join(staging, @db)

      with {:ok, conn} <- sqlite_open(source),
           result = vacuum_into(conn, target),
           :ok <- close_then(conn, result),
           :ok <- verify_copy(source, target) do
        :ok
      end
    else
      :ok
    end
  end

  defp vacuum_into(conn, target) do
    escaped = String.replace(target, "'", "''")

    case Exqlite.Sqlite3.execute(conn, "VACUUM INTO '" <> escaped <> "'") do
      :ok -> :ok
      {:error, reason} -> {:error, "VACUUM INTO failed: #{inspect(reason)}"}
    end
  end

  defp close_then(conn, result) do
    Exqlite.Sqlite3.close(conn)
    result
  end

  defp verify_copy(source, target) do
    with {:ok, copy} <- sqlite_open(target) do
      result =
        with :ok <- integrity_ok(copy),
             {:ok, copied} <- counts(copy),
             {:ok, orig} <- sqlite_open(source) do
          original = counts(orig)
          Exqlite.Sqlite3.close(orig)

          case original do
            {:ok, ^copied} -> :ok
            {:ok, other} -> {:error, "row counts differ: #{inspect(other)} vs #{inspect(copied)}"}
            error -> error
          end
        end

      Exqlite.Sqlite3.close(copy)
      result
    end
  end

  defp integrity_ok(conn) do
    case rows(conn, "PRAGMA integrity_check") do
      {:ok, [["ok"]]} -> :ok
      {:ok, other} -> {:error, "integrity_check on the copy: #{inspect(other)}"}
      error -> error
    end
  end

  defp counts(conn) do
    with {:ok, tables} <-
           rows(conn, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") do
      Enum.reduce_while(tables, {:ok, %{}}, fn [name], {:ok, acc} ->
        quoted = "\"" <> String.replace(name, "\"", "\"\"") <> "\""

        case rows(conn, "SELECT count(*) FROM " <> quoted) do
          {:ok, [[n]]} -> {:cont, {:ok, Map.put(acc, name, n)}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp rows(conn, sql) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, statement} ->
        try do
          case Exqlite.Sqlite3.fetch_all(conn, statement) do
            {:ok, rows} -> {:ok, rows}
            {:error, reason} -> {:error, "#{sql}: #{inspect(reason)}"}
          end
        after
          Exqlite.Sqlite3.release(conn, statement)
        end

      {:error, reason} ->
        {:error, "#{sql}: #{inspect(reason)}"}
    end
  end

  defp sqlite_open(path) do
    case Exqlite.Sqlite3.open(path) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, "could not open #{path}: #{inspect(reason)}"}
    end
  end

  # Everything else at the top of the old directory, recursively, byte for
  # byte - except the database and its side files (copied through SQLite
  # above), `backups` (moved to their own directory by `move_backups/1`),
  # Velopack's program files (they are what is running), and the launcher's
  # log (held open by the launcher, and worth nothing).
  defp copy_other_files(legacy, staging) do
    skip =
      MapSet.new(
        [@db, "backups", "launcher.log", "DATA-MOVED.txt"] ++
          @sqlite_side_files ++ @velopack_program_files
      )

    legacy
    |> File.ls!()
    |> Enum.reject(&MapSet.member?(skip, &1))
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case copy_tree(Path.join(legacy, name), Path.join(staging, name)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp copy_tree(from, to) do
    cond do
      File.dir?(from) ->
        File.mkdir_p!(to)

        from
        |> File.ls!()
        |> Enum.reduce_while(:ok, fn name, :ok ->
          case copy_tree(Path.join(from, name), Path.join(to, name)) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      true ->
        with :ok <- File.cp(from, to),
             true <- same_bytes?(from, to) || {:error, "#{from} did not copy identically"} do
          :ok
        end
    end
  end

  defp same_bytes?(a, b), do: digest(a) == digest(b)

  defp digest(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end

  defp moved_from_note(legacy) do
    """
    OpenPairings copied your tournaments here from
    #{legacy}
    on #{DateTime.utc_now() |> DateTime.truncate(:second)} UTC, so that no installer can remove them.
    The copy was checked before it was used. The original was left where it was.
    """
  end

  defp moved_to_note(home) do
    """
    OpenPairings no longer uses this folder. Your tournaments were copied to
    #{home}
    and checked there. This copy was left untouched and is no longer updated.
    """
  end

  ## ---------- staging leftovers ----------

  # A staging directory survives only a crash in the middle of
  # `copy_verify_switch/1`, and holds nothing that is not still in the
  # original. It is removed so the next attempt starts clean.
  defp clean_stale_staging(%{parent: parent} = layout) do
    case File.ls(parent) do
      {:ok, names} ->
        for name <- names, String.starts_with?(name, @staging_prefix) do
          _ = remove_staging(layout, Path.join(parent, name))
        end

        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Deletes a staging directory - and refuses, returning `{:error, :refused}`,
  for anything that is not unmistakably one.

  This is the only recursive delete in the data-directory code, so it carries
  the guard: the path must sit directly in `%LOCALAPPDATA%`, be named like a
  staging directory, still hold the sentinel file written before anything was
  copied into it (it is removed only just before the commit rename), and be
  none of - and contain none of - the old directory, the data directory or the
  backups directory. `PairingsEngine.Desktop.DataHomeTest` mutation-checks it.
  """
  @spec remove_staging(layout(), Path.t()) :: :ok | {:error, :refused}
  def remove_staging(layout, path) do
    if staging_removable?(layout, path) do
      File.rm_rf!(path)
      :ok
    else
      {:error, :refused}
    end
  end

  defp staging_removable?(%{parent: parent} = layout, path) do
    expanded = Path.expand(path)

    same_path?(Path.dirname(expanded), parent) and
      String.starts_with?(Path.basename(expanded), @staging_prefix) and
      File.regular?(Path.join(expanded, @staging_sentinel)) and
      not Enum.any?([layout.legacy, layout.home, layout.backups], fn protected ->
        same_path?(expanded, protected) or inside?(protected, expanded)
      end)
  end

  ## ---------- backups ----------

  @doc """
  Moves any `backups` folder left in the old directory or the data directory
  into `layout.backups`.

  A whole-folder rename when the destination does not exist yet; otherwise
  one rename per file that is not already there. Every step is a rename of
  its own, so a crash leaves each backup in one folder or the other and the
  next start finishes the job. A name already present in the destination is
  left alone in the source, never overwritten.
  """
  @spec move_backups(layout()) :: :ok
  def move_backups(%{legacy: legacy, home: home, backups: backups}) do
    for dir <- Enum.uniq([Path.join(home, "backups"), Path.join(legacy, "backups")]),
        File.dir?(dir) do
      if File.exists?(backups) do
        merge_into(dir, backups)
      else
        case File.rename(dir, backups) do
          :ok ->
            Logger.warning("Moved backups from #{dir} to #{backups}.")

          {:error, _} ->
            File.mkdir_p!(backups)
            merge_into(dir, backups)
        end
      end
    end

    File.mkdir_p!(backups)
    :ok
  end

  defp merge_into(from, to) do
    File.mkdir_p!(to)

    for name <- File.ls!(from), not File.exists?(Path.join(to, name)) do
      case File.rename(Path.join(from, name), Path.join(to, name)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not move backup #{name} to #{to}: #{inspect(reason)}")
      end
    end

    # Removes the source folder only if the moves emptied it - `rmdir` fails
    # on a non-empty directory, which is the point.
    _ = File.rmdir(from)
    :ok
  end

  ## ---------- an old-id install's program files ----------

  @doc """
  After an old-id install's directory became the data directory, its program
  files (Velopack's `current`, `packages`, `Update.exe`, the stub) sit beside
  the database doing nothing. Each is renamed into `old-program-files` - one
  rename each, never a delete - so a person looking in the folder sees their
  data and one clearly named folder, rather than what looks like an install.
  """
  @spec tidy_program_files(Path.t()) :: :ok
  def tidy_program_files(home) do
    present = Enum.filter(@velopack_program_files, &File.exists?(Path.join(home, &1)))

    # `current` and `Update.exe` together are Velopack's shape; either alone
    # is not enough to call this folder an install.
    if "current" in present and "Update.exe" in present do
      target = Path.join(home, @program_files_folder)
      File.mkdir_p!(target)

      for name <- present, not File.exists?(Path.join(target, name)) do
        _ = File.rename(Path.join(home, name), Path.join(target, name))
      end
    end

    :ok
  end

  ## ---------- paths ----------

  @doc false
  # Windows paths compare case-insensitively and with either separator.
  def same_path?(nil, _), do: false
  def same_path?(_, nil), do: false
  def same_path?(a, b), do: normal(a) == normal(b)

  @doc false
  # `child` is strictly inside `parent`.
  def inside?(nil, _), do: false
  def inside?(_, nil), do: false
  def inside?(child, parent), do: String.starts_with?(normal(child), normal(parent) <> "/")

  @doc false
  def normal(path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> Path.expand()
    |> String.trim_trailing("/")
    |> String.downcase()
  end
end
