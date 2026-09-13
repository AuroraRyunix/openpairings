defmodule PairingsEngine.BackupRestoreTest do
  @moduledoc """
  The restore drill of 2026-09-13 (`docs/restore-drill-2026-09-13.md`), kept.

  `PairingsEngine.BackupTest` proves the file is written and the tournament
  and its key are inside. These prove the promises that justify it, against
  the app itself rather than against raw SQL:

    * the rating tables are emptied and NOT dropped, so the restored file's
      `schema_migrations` matches the code - asked of `Ecto.Migrator`, the
      same question a boot would ask;
    * everything else comes back table for table, row for row;
    * the app's own Repo and contexts read the restored file;
    * a file `verify/1` refuses leaves nothing beside the live database.

  Sources are built from the test database's schema for the reason the other
  file gives: a backup copies the database FILE, and the sandbox keeps a
  test's rows where no other connection can see them.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Backup

  # A downloaded copy of somebody else's data, and the index over it: emptied
  # on the way out by design. Every other table must come back whole.
  @rating_tables ~w(fide_players kbsb_players)

  setup do
    dir = Path.join(System.tmp_dir!(), "opbak-drill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # verify/1 stages its copy in the temp directory and, on Windows, cannot
    # always delete it again (the drill found hundreds of them - see the drill
    # document, finding "verify leaves a decrypted copy"). Point the temp
    # directory at this test's own, which is removed below, so these tests do
    # not add to the pile while that is open.
    previous_tmp = System.get_env("TMPDIR")
    System.put_env("TMPDIR", dir)

    on_exit(fn ->
      if previous_tmp,
        do: System.put_env("TMPDIR", previous_tmp),
        else: System.delete_env("TMPDIR")

      File.rm_rf(dir)
      for suffix <- ["", "-wal", "-shm"], do: File.rm(live_database() <> ".restored" <> suffix)
    end)

    Application.delete_env(:pairings_engine, :backup_passphrase)
    on_exit(fn -> Application.delete_env(:pairings_engine, :backup_passphrase) end)

    {:ok, dir: dir}
  end

  defp live_database, do: Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database]

  defp query(path, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    {:ok, st} = Exqlite.Sqlite3.prepare(conn, sql)
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, st)
    :ok = Exqlite.Sqlite3.release(conn, st)
    :ok = Exqlite.Sqlite3.close(conn)
    rows
  end

  # Today's schema, emptied of whatever other suites committed, then an
  # installation's worth of rows: a user, a published tournament with a key,
  # players, a round with a result, an audit row, a machine setting, and the
  # rating lists the backup is supposed to leave behind.
  defp source(dir) do
    path = Path.join(dir, "source-#{System.unique_integer([:positive])}.db")

    {:ok, conn} = Exqlite.Sqlite3.open(live_database())
    :ok = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{path}'")
    :ok = Exqlite.Sqlite3.close(conn)

    for [table] <-
          query(
            path,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' " <>
              "AND name NOT LIKE '%_fts%' AND name <> 'schema_migrations'"
          ) do
      {:ok, conn} = Exqlite.Sqlite3.open(path)
      :ok = Exqlite.Sqlite3.execute(conn, "DELETE FROM \"#{table}\"")
      :ok = Exqlite.Sqlite3.close(conn)
    end

    stamp = "2026-09-13 00:00:00"
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    for sql <- [
          "INSERT INTO users (id, email, role, inserted_at, updated_at) VALUES (1, 'arbiter@example.org', 'admin', '#{stamp}', '#{stamp}')",
          """
          INSERT INTO tournaments (id, name, type, rounds_count, public_slug, openresults_key, publish_to_openresults,
                                   user_id, tiebreaks, round_dates, categories, category_rules, fide_id_ranges,
                                   officials, inserted_at, updated_at)
          VALUES (1, 'Drill Open', 'swiss', 3, 'drillopen001', 'the-key-that-withdraws-it', 1, 1, '["BH"]',
                  '["2026-09-13","2026-09-14","2026-09-15"]', '[]', '{}', '[]', '{}', '#{stamp}', '#{stamp}')
          """,
          "INSERT INTO players (id, tournament_id, name, inserted_at, updated_at) VALUES (1, 1, 'Drill, Anna', '#{stamp}', '#{stamp}')",
          "INSERT INTO players (id, tournament_id, name, inserted_at, updated_at) VALUES (2, 1, 'Drill, Bert', '#{stamp}', '#{stamp}')",
          "INSERT INTO rounds (id, tournament_id, number) VALUES (1, 1, 1)",
          "INSERT INTO pairings (round_id, board, white_player_id, black_player_id, result) VALUES (1, 1, 1, 2, '1-0')",
          """
          INSERT INTO audit_logs (tournament_id, user_id, action, details, inserted_at)
          VALUES (1, 1, 'pairing.result_entered', '{}', '#{stamp}')
          """,
          "INSERT INTO meta (key, value) VALUES ('site_notice', 'restore drill')",
          "INSERT INTO fide_players (fide_id, name) VALUES (1503014, 'Carlsen, Magnus')",
          "INSERT INTO kbsb_players (national_id, last_name) VALUES ('50001', 'De Vos')"
        ] do
      :ok = Exqlite.Sqlite3.execute(conn, sql)
    end

    :ok = Exqlite.Sqlite3.close(conn)
    path
  end

  defp table_counts(path) do
    for [table] <-
          query(
            path,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' " <>
              "AND name NOT LIKE '%_fts%'"
          ),
        into: %{} do
      [[count]] = query(path, "SELECT COUNT(*) FROM \"#{table}\"")
      {table, count}
    end
  end

  defp migration_files do
    Application.app_dir(:pairings_engine, "priv/repo/migrations")
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/\A\d+_\w+\.exs\z/, &1))
  end

  test "the restored file matches its source table for table, the rating lists aside", %{dir: dir} do
    src = source(dir)
    {:ok, path} = Backup.create(dir: dir, source: src)
    {:ok, restored} = Backup.restore(path)

    before = table_counts(src)
    after_restore = table_counts(restored)

    assert Map.keys(after_restore) == Map.keys(before)

    for table <- @rating_tables do
      assert before[table] == 1
      assert after_restore[table] == 0
    end

    assert Map.drop(after_restore, @rating_tables) == Map.drop(before, @rating_tables)
    assert before["tournaments"] == 1 and before["pairings"] == 1 and before["audit_logs"] == 1
  end

  test "the app's own Repo opens it: every migration up, the key and the results readable", %{
    dir: dir
  } do
    {:ok, path} = Backup.create(dir: dir, source: source(dir))
    {:ok, restored} = Backup.restore(path)

    repo =
      start_supervised!(%{
        id: :restored_repo,
        start:
          {PairingsEngine.Repo, :start_link,
           [[name: nil, database: restored, pool: DBConnection.ConnectionPool, pool_size: 1]]}
      })

    previous = PairingsEngine.Repo.put_dynamic_repo(repo)

    try do
      # The promise the moduledoc makes about emptying rather than dropping:
      # the file's history is the code's history, so nothing is pending and
      # nothing is unknown.
      migrations = Ecto.Migrator.migrations(PairingsEngine.Repo)
      assert length(migrations) == length(migration_files())
      assert Enum.all?(migrations, fn {status, _version, _name} -> status == :up end)

      tournament = PairingsEngine.Tournaments.get_tournament!(1)
      assert tournament.name == "Drill Open"

      # The one thing that can withdraw the published copy - the reason the
      # backup exists - comes back usable, not just present.
      assert PairingsEngine.Publishing.published?(tournament)
      assert tournament.openresults_key == "the-key-that-withdraws-it"

      assert [%{result: "1-0"}] = PairingsEngine.Repo.all(PairingsEngine.Tournaments.Pairing)
      assert PairingsEngine.Repo.aggregate(PairingsEngine.Fide.FidePlayer, :count) == 0
    after
      PairingsEngine.Repo.put_dynamic_repo(previous)
    end
  end

  describe "a refused file writes nothing beside the live database" do
    test "truncated, damaged, foreign or empty", %{dir: dir} do
      {:ok, good} = Backup.create(dir: dir, source: source(dir))
      raw = File.read!(good)
      [magic, header, payload] = String.split(raw, "\n", parts: 3)

      candidates = %{
        "truncated" => binary_part(raw, 0, div(byte_size(raw), 2)),
        "tail cut" => binary_part(raw, 0, byte_size(raw) - 6),
        "bit flipped" => flip_middle(raw),
        "header damaged" =>
          magic <> "\n" <> String.replace(header, "true", "tru") <> "\n" <> payload,
        "not a database inside" =>
          magic <> "\n" <> header <> "\n" <> :zlib.gzip(:crypto.strong_rand_bytes(8192)),
        "an OpenResults backup" => "ORBAK1\n" <> header <> "\n" <> payload,
        "empty" => ""
      }

      for {label, bytes} <- candidates do
        path = Path.join(dir, "#{String.replace(label, " ", "-")}.opbak")
        File.write!(path, bytes)
        File.rm(live_database() <> ".restored")

        assert {:error, _} = Backup.verify(path), "#{label}: verify accepted it"
        assert {:error, _} = Backup.restore(path), "#{label}: restore accepted it"
        refute File.exists?(live_database() <> ".restored"), "#{label}: something was written"
      end
    end
  end

  defp flip_middle(raw) do
    at = div(byte_size(raw), 2)
    <<head::binary-size(^at), byte, tail::binary>> = raw
    head <> <<Bitwise.bxor(byte, 0x10)>> <> tail
  end
end
