defmodule PairingsEngine.BackupSwapTest do
  @moduledoc """
  The swap `mix pairings.backup --restore` prints, run as printed, against the
  situation the 2026-09-13 drill found it failing in.

  After a crash, an OOM kill or a stop that ran into systemd's timeout, the
  newest writes are in `pairings_engine.db-wal`, not in the database file.
  The task used to print two `mv`s that moved the database and left that WAL
  where it was - beside the restored file. SQLite pairs a database with
  whatever `-wal` carries its name and cannot tell it belongs to another
  file, so it read the OLD database back through the restored file's name,
  `integrity_check` said "ok", and the `before-restore` copy the output told
  the operator to keep was missing everything the WAL held (drill finding 1).

  So this test does not read the printed text for the right words - it runs
  it. Every indented line the task prints (the commands; the prose is not
  indented) goes through `bash` in a scratch copy of a crashed database
  directory, with `systemctl`, `chown`, `runuser` and `curl` replaced by
  shell functions that do nothing, and SQLite is then asked what it sees.
  The same test fails against the two `mv`s the task printed before.
  """
  use ExUnit.Case, async: false

  alias PairingsEngine.Backup

  # `bash` on the PATH, or - on Windows, where Git for Windows ships one and
  # does not put it on the PATH - the one beside `git`. Not WSL's
  # `System32\bash.exe`, which cannot see a Windows path.
  bash =
    case System.find_executable("bash") do
      path when is_binary(path) ->
        if path =~ ~r/system32/i, do: nil, else: path

      nil ->
        nil
    end ||
      with git when is_binary(git) <- System.find_executable("git"),
           candidate = Path.join([Path.dirname(Path.dirname(git)), "bin", "bash.exe"]),
           true <- File.exists?(candidate) do
        candidate
      else
        _ -> nil
      end

  @bash bash

  if is_nil(bash) do
    @moduletag skip: "no bash to run the printed swap with"
  end

  setup do
    # Expanded, so a Windows temp directory has forward slashes: the task
    # prints these paths into shell commands, and bash reads a backslash as an
    # escape. A server's paths are /var/lib/... and never had the problem.
    dir =
      System.tmp_dir!()
      |> Path.join("opbak-swap-#{System.unique_integer([:positive])}")
      |> Path.expand()

    File.mkdir_p!(Path.join(dir, "crashed"))
    File.mkdir_p!(Path.join(dir, "backups"))

    repo_config = Application.get_env(:pairings_engine, PairingsEngine.Repo)
    shell = Mix.shell()

    on_exit(fn ->
      Application.put_env(:pairings_engine, PairingsEngine.Repo, repo_config)
      Mix.shell(shell)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir, test_database: repo_config[:database]}
  end

  test "the printed swap moves the WAL with the database, so the restored data is what SQLite serves",
       %{dir: dir, test_database: test_database} do
    live = Path.join(dir, "pairings_engine.db")
    crashed = Path.join([dir, "crashed", "pairings_engine.db"])

    # A database with this app's schema and one tournament, backed up.
    build_database(test_database, live)
    execute(live, [insert_tournament(1, "In the backup")])
    {:ok, backup} = Backup.create(dir: Path.join(dir, "backups"), source: live)

    # Work after the backup, left in the WAL - which is where it is when the
    # service dies instead of stopping. The copies taken while the writer is
    # still open are what the disk holds after the kill.
    {:ok, writer} = Exqlite.Sqlite3.open(live)
    :ok = Exqlite.Sqlite3.execute(writer, "PRAGMA journal_mode = WAL")
    :ok = Exqlite.Sqlite3.execute(writer, "PRAGMA wal_autocheckpoint = 0")
    :ok = Exqlite.Sqlite3.execute(writer, insert_tournament(2, "Written after the backup"))
    :ok = Exqlite.Sqlite3.execute(writer, "DELETE FROM tournaments WHERE id = 1")

    for suffix <- ["", "-wal", "-shm"], File.exists?(live <> suffix) do
      File.cp(live <> suffix, crashed <> suffix)
    end

    :ok = Exqlite.Sqlite3.close(writer)

    # The scenario is real only if the newest writes are in a WAL. Not asked
    # of SQLite here: closing the last connection would checkpoint it away.
    assert File.stat!(crashed <> "-wal").size > 0

    # `--restore`, as an operator runs it, against the crashed directory.
    Application.put_env(
      :pairings_engine,
      PairingsEngine.Repo,
      Keyword.put(Application.get_env(:pairings_engine, PairingsEngine.Repo), :database, crashed)
    )

    Mix.shell(Mix.Shell.Process)
    Mix.Tasks.Pairings.Backup.run(["--restore", backup])

    {output, 0} = run_printed_commands(printed(), Path.dirname(crashed))

    # SQLite is the judge. The live name must now be the backup, and nothing
    # but the backup - not the old database read back through a stale WAL.
    served = names(crashed)

    assert served == ["In the backup"], """
    The restored database does not hold what the backup held: SQLite serves
    #{inspect(served)} under the live name. The swap left the old -wal beside
    it and SQLite read the old database back. bash said:

    #{output}
    """

    refute File.exists?(crashed <> "-wal")

    # And the copy kept "until you are sure" holds everything the WAL held.
    [before] =
      Path.join(dir, "crashed")
      |> File.ls!()
      |> Enum.filter(&(&1 =~ ~r/\Apairings_engine\.db\.before-restore[^.]*\z/))
      |> Enum.reject(&String.ends_with?(&1, ["-wal", "-shm"]))

    assert names(Path.join([dir, "crashed", before])) == ["Written after the backup"]
  end

  test "the printed swap migrates after moving the files and before starting" do
    text =
      Mix.Tasks.Pairings.Backup.swap_instructions(
        "/var/lib/pairingsengine/pairings_engine.db.restored",
        "/var/lib/pairingsengine/pairings_engine.db",
        "/apps/web/pairingsengine"
      )

    assert text =~ "for f in pairings_engine.db pairings_engine.db-wal pairings_engine.db-shm"
    assert text =~ "mv pairings_engine.db.restored pairings_engine.db"

    [before_start, _] = String.split(text, "systemctl start pairingsengine", parts: 2)
    [before_migrate, _] = String.split(before_start, "mix ecto.migrate", parts: 2)
    assert before_migrate =~ "mv pairings_engine.db.restored pairings_engine.db"

    # A backup no longer carries the operator token, so the restore sets it
    # again before the service starts - read from the results site's unit,
    # handed over in the environment the deploy uses, never on a command line.
    assert before_start =~ "OPENRESULTS_INGEST_TOKEN"
    assert before_start =~ "mix pairings.publishing --ensure"
    refute text =~ "--token"
  end

  test "--verify and --restore take a name exactly as --list prints it", %{dir: dir} do
    backups = Path.join(dir, "backups")
    live = Path.join(dir, "pairings_engine.db")
    build_database(Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database], live)
    {:ok, path} = Backup.create(dir: backups, source: live)

    previous = Application.get_env(:pairings_engine, :backup_dir)
    Application.put_env(:pairings_engine, :backup_dir, backups)

    try do
      assert Mix.Tasks.Pairings.Backup.resolve(Path.basename(path)) == path
      assert Mix.Tasks.Pairings.Backup.resolve(path) == path
      assert Mix.Tasks.Pairings.Backup.resolve("nope.opbak") == "nope.opbak"
    after
      if previous,
        do: Application.put_env(:pairings_engine, :backup_dir, previous),
        else: Application.delete_env(:pairings_engine, :backup_dir)
    end
  end

  # Everything the task printed, as one text.
  defp printed(acc \\ []) do
    receive do
      {:mix_shell, :info, [message]} -> printed([message | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  # The indented lines are the commands. The service manager, ownership, the
  # account switch and the health check are this test's to fake: a scratch
  # directory has no unit, no service account and nothing listening.
  defp run_printed_commands(text, cwd) do
    commands =
      text
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "  "))
      |> Enum.join("\n")

    script = """
    systemctl() { case "$1" in is-active) echo inactive ;; esac; }
    chown() { :; }
    runuser() { :; }
    curl() { echo 302; }
    #{commands}
    """

    System.cmd(@bash, ["-c", script], cd: cwd, stderr_to_stdout: true)
  end

  # This app's schema, from the test database, with no rows in it.
  defp build_database(test_database, path) do
    {:ok, conn} = Exqlite.Sqlite3.open(test_database)
    :ok = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{path}'")
    :ok = Exqlite.Sqlite3.close(conn)

    tables =
      query(
        path,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' " <>
          "AND name NOT LIKE '%_fts%' AND name <> 'schema_migrations'"
      )

    execute(path, for([table] <- tables, do: ~s(DELETE FROM "#{table}")))
  end

  defp insert_tournament(id, name) do
    """
    INSERT INTO tournaments (id, name, type, rounds_count, public_slug, tiebreaks, round_dates,
                             categories, category_rules, fide_id_ranges, officials, inserted_at, updated_at)
    VALUES (#{id}, '#{name}', 'swiss', 3, 'swap-#{id}', '[]', '[]', '[]', '{}', '[]', '{}',
            '2026-09-13 00:00:00', '2026-09-13 00:00:00')
    """
  end

  defp names(path),
    do: path |> query("SELECT name FROM tournaments ORDER BY id") |> List.flatten()

  defp execute(path, statements) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    Enum.each(statements, &(:ok = Exqlite.Sqlite3.execute(conn, &1)))
    :ok = Exqlite.Sqlite3.close(conn)
  end

  defp query(path, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, sql)
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, statement)
    :ok = Exqlite.Sqlite3.release(conn, statement)
    :ok = Exqlite.Sqlite3.close(conn)
    rows
  end
end
