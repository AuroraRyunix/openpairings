defmodule PairingsEngine.BackupTest do
  @moduledoc """
  Backups, and the half that matters: getting the data back.

  There were none until 2026-08-29. What is tested here is not "a file
  appeared" - that is easy and worthless - but that the file opens, that the
  tournament and its key are inside it, that a wrong passphrase is refused
  rather than half-applied, and that the rating tables come back **empty and
  present** rather than missing. That last one is the whole design: a restored
  database whose tables had been dropped would not match its own migration
  history, and the app would not boot.

  ## Why these tests build their own database

  A backup copies the database FILE. The sandbox keeps each test's rows inside
  an uncommitted transaction no other connection can see, so a tournament
  inserted the usual way would be invisible to the very code under test, and
  `unboxed_run` deadlocks against the connection the case already holds.

  So each test stamps out a real database from the test schema, writes rows
  into it directly, and backs that up through `create(source: ...)` - the same
  path production takes, with a source it can actually see.
  """
  use PairingsEngine.DataCase, async: false

  import Bitwise

  alias PairingsEngine.Backup

  setup do
    dir = Path.join(System.tmp_dir!(), "opbak-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf(dir)
      File.rm(live_database() <> ".restored")
    end)

    Application.delete_env(:pairings_engine, :backup_passphrase)
    on_exit(fn -> Application.delete_env(:pairings_engine, :backup_passphrase) end)

    {:ok, dir: dir}
  end

  defp live_database, do: Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database]

  # A real database with this app's real schema, stamped out of the test one so
  # `fide_players`, its FTS index and its triggers are all genuinely there -
  # they are what the stripping has to handle correctly.
  defp source(dir, sql \\ []) do
    path = Path.join(dir, "source-#{System.unique_integer([:positive])}.db")

    {:ok, conn} = Exqlite.Sqlite3.open(live_database())
    :ok = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{path}'")
    :ok = Exqlite.Sqlite3.close(conn)

    {:ok, conn} = Exqlite.Sqlite3.open(path)

    # The test database carries rows committed by other suites. A test that
    # asserts on what is inside a backup has to own the contents, so the copy
    # starts empty and each test puts in exactly what it means to.
    for table <- ~w(pairings rounds players tournaments fide_players) do
      :ok = Exqlite.Sqlite3.execute(conn, "DELETE FROM #{table}")
    end

    Enum.each(sql, &(:ok = Exqlite.Sqlite3.execute(conn, &1)))
    :ok = Exqlite.Sqlite3.close(conn)

    path
  end

  defp with_tournament(dir, name \\ "Backup Open") do
    source(dir, [
      """
      INSERT INTO tournaments (name, type, rounds_count, public_slug, openresults_key,
                               tiebreaks, round_dates, categories, category_rules,
                               fide_id_ranges, officials, inserted_at, updated_at)
      VALUES ('#{name}', 'swiss', 3, 'bak-#{System.unique_integer([:positive])}',
              'a-key-that-must-survive', '[]', '[]', '[]', '{}', '[]', '{}',
              '2026-08-29 00:00:00', '2026-08-29 00:00:00')
      """
    ])
  end

  defp rating_rows(path) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT COUNT(*) FROM fide_players")
    {:ok, [[count]]} = Exqlite.Sqlite3.fetch_all(conn, stmt)
    :ok = Exqlite.Sqlite3.close(conn)
    count
  end

  describe "creating one" do
    test "writes a file that verifies, with the tournament in it", %{dir: dir} do
      src = with_tournament(dir)

      assert {:ok, path} = Backup.create(dir: dir, source: src)
      assert File.exists?(path)
      assert Path.extname(path) == ".opbak"

      assert {:ok, info} = Backup.verify(path)
      assert info.tournaments == 1
      assert "tournaments" in info.tables
      assert "schema_migrations" in info.tables
    end

    test "the rating tables are present and empty, not dropped", %{dir: dir} do
      src =
        source(dir, [
          "INSERT INTO fide_players (fide_id, name) VALUES (1503014, 'Carlsen, Magnus')",
          "INSERT INTO fide_players (fide_id, name) VALUES (2503014, 'De Vos, Ilse')"
        ])

      assert rating_rows(src) == 2

      {:ok, path} = Backup.create(dir: dir, source: src)
      {:ok, info} = Backup.verify(path)

      # Present: `schema_migrations` still records the migrations that created
      # them, so a restored database missing them would not match its own
      # history and the app would refuse to start.
      assert "fide_players" in info.tables
      assert "fide_players_fts" in info.tables

      # And empty: 207 MB of the 219 is a downloaded copy of somebody else's
      # data, which a sync rebuilds.
      {:ok, restored} = Backup.restore(path)
      assert rating_rows(restored) == 0
    end

    test "and the FTS index is emptied through its own command, not corrupted", %{dir: dir} do
      src =
        source(dir, [
          "INSERT INTO fide_players (fide_id, name) VALUES (1503014, 'Carlsen, Magnus')"
        ])

      {:ok, path} = Backup.create(dir: dir, source: src)
      {:ok, restored} = Backup.restore(path)

      # Deleting from FTS5's shadow tables directly leaves an index that is
      # structurally broken rather than empty, and the failure shows up much
      # later as a search that returns nothing or raises.
      {:ok, conn} = Exqlite.Sqlite3.open(restored)

      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT COUNT(*) FROM fide_players_fts WHERE name MATCH 'x'"
        )

      assert {:ok, [[0]]} = Exqlite.Sqlite3.fetch_all(conn, stmt)

      # And it still accepts writes, so the next sync can fill it.
      assert :ok =
               Exqlite.Sqlite3.execute(
                 conn,
                 "INSERT INTO fide_players (fide_id, name) VALUES (999, 'After, Restore')"
               )

      :ok = Exqlite.Sqlite3.close(conn)
    end

    test "a second backup does not overwrite the first", %{dir: dir} do
      src = source(dir)

      {:ok, one} = Backup.create(dir: dir, source: src, stamp: ~U[2026-08-29 01:00:00Z])
      {:ok, two} = Backup.create(dir: dir, source: src, stamp: ~U[2026-08-29 02:00:00Z])

      refute one == two
      assert length(Backup.list(dir: dir)) == 2
    end

    test "listing is newest first and says whether each is encrypted", %{dir: dir} do
      src = source(dir)

      {:ok, _} = Backup.create(dir: dir, source: src, stamp: ~U[2026-08-01 00:00:00Z])
      {:ok, _} = Backup.create(dir: dir, source: src, stamp: ~U[2026-08-29 00:00:00Z])

      assert [newest, older] = Backup.list(dir: dir)
      assert DateTime.compare(newest.created_at, older.created_at) == :gt
      refute newest.encrypted
      assert newest.size > 0
    end

    test "sweeps stale staging files, so they cannot accumulate", %{dir: dir} do
      src = source(dir)

      # A staging copy is a whole database - 219 MB in production - so one left
      # behind per run would fill the disk the backups exist to protect.
      #
      # Deleting it immediately is attempted and deliberately not relied on: a
      # SQLite file can stay briefly locked after its handle is closed, and how
      # briefly is not something worth encoding as a sleep. What is guaranteed
      # is that the next run clears it.
      stale = Path.join(dir, "staging-from-a-crashed-run.db")
      File.write!(stale, "leftover")
      old = System.os_time(:second) - 3600
      File.touch!(stale, old)

      {:ok, _} = Backup.create(dir: dir, source: src)

      refute File.exists?(stale)
    end

    test "but leaves a fresh one alone, in case a run is in flight", %{dir: dir} do
      src = source(dir)

      # A manual backup during the scheduled one would otherwise have its
      # staging copy pulled out from under it.
      fresh = Path.join(dir, "staging-in-progress.db")
      File.write!(fresh, "someone else is using this")

      {:ok, _} = Backup.create(dir: dir, source: src)

      assert File.exists?(fresh)
    end
  end

  describe "restoring" do
    test "recovers beside the live database, never over it", %{dir: dir} do
      src = with_tournament(dir, "Recoverable Open")
      before = File.stat!(live_database()).size

      {:ok, path} = Backup.create(dir: dir, source: src)
      assert {:ok, restored} = Backup.restore(path)

      # A SQLite file cannot be swapped under an open connection pool without
      # risking the very thing being recovered.
      assert String.ends_with?(restored, ".restored")
      assert File.exists?(restored)
      assert File.stat!(live_database()).size == before
    end

    test "the recovered file really holds the tournament and its key", %{dir: dir} do
      src = with_tournament(dir, "Key Survivor")
      {:ok, path} = Backup.create(dir: dir, source: src)
      {:ok, restored} = Backup.restore(path)

      {:ok, conn} = Exqlite.Sqlite3.open(restored)

      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(conn, "SELECT name, openresults_key FROM tournaments")

      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      :ok = Exqlite.Sqlite3.close(conn)

      # The key is the point of the whole exercise: it is the only thing that
      # can withdraw a published tournament, and it exists nowhere else.
      assert [["Key Survivor", "a-key-that-must-survive"]] = rows
    end

    test "refuses a file that is not one of ours", %{dir: dir} do
      junk = Path.join(dir, "notes.opbak")
      File.write!(junk, "dear diary")

      assert {:error, message} = Backup.verify(junk)
      assert message =~ "not an OpenPairings backup"
    end

    test "refuses a truncated one rather than recovering half a database", %{dir: dir} do
      src = source(dir)
      {:ok, path} = Backup.create(dir: dir, source: src)

      raw = File.read!(path)
      File.write!(path, binary_part(raw, 0, div(byte_size(raw), 2)))

      assert {:error, _} = Backup.verify(path)
    end
  end

  describe "encryption" do
    setup do
      Application.put_env(:pairings_engine, :backup_passphrase, "correct horse battery staple")
      :ok
    end

    test "round-trips with the right passphrase", %{dir: dir} do
      src = with_tournament(dir, "Encrypted Open")

      {:ok, path} = Backup.create(dir: dir, source: src)
      assert Backup.encrypted?()
      assert [%{encrypted: true}] = Backup.list(dir: dir)

      assert {:ok, info} = Backup.verify(path)
      assert info.tournaments == 1
    end

    test "the file on disk does not contain the plaintext", %{dir: dir} do
      src = with_tournament(dir, "Secret Tournament Name")
      {:ok, path} = Backup.create(dir: dir, source: src)

      # The reason encryption is here at all: these files carry the email
      # addresses people gave the entry form.
      refute File.read!(path) =~ "Secret Tournament Name"
    end

    test "a wrong passphrase is refused, not partly applied", %{dir: dir} do
      src = source(dir)
      {:ok, path} = Backup.create(dir: dir, source: src)

      Application.put_env(:pairings_engine, :backup_passphrase, "not the one")

      assert {:error, message} = Backup.verify(path)
      assert message =~ "assphrase"
    end

    test "and so is a tampered one", %{dir: dir} do
      src = source(dir)
      {:ok, path} = Backup.create(dir: dir, source: src)

      raw = File.read!(path)

      # XOR rather than "write a zero". Writing <<0>> is a no-op whenever the
      # last byte already IS zero, which is one run in 256 - and a test that
      # passes 255 times out of 256 is worse than no test, because the failure
      # arrives months later looking like a real defect. Caught by exactly that
      # flake in a full-suite run.
      altered = binary_part(raw, 0, byte_size(raw) - 1) <> <<Bitwise.bxor(:binary.last(raw), 1)>>
      File.write!(path, altered)
      refute altered == raw

      # AES-GCM's tag is what makes this a refusal rather than a subtly wrong
      # database that opens perfectly well.
      assert {:error, _} = Backup.verify(path)
    end

    test "an encrypted backup cannot be read with no passphrase at all", %{dir: dir} do
      src = source(dir)
      {:ok, path} = Backup.create(dir: dir, source: src)

      Application.delete_env(:pairings_engine, :backup_passphrase)

      assert {:error, message} = Backup.verify(path)
      assert message =~ "PAIRINGS_BACKUP_PASSPHRASE"
    end
  end

  describe "retention" do
    test "keeps the newest and removes the rest", %{dir: dir} do
      src = source(dir)

      for day <- 1..5 do
        stamp = DateTime.new!(Date.new!(2026, 8, day), ~T[00:00:00])
        {:ok, _} = Backup.create(dir: dir, source: src, stamp: stamp)
      end

      assert length(Backup.list(dir: dir)) == 5
      assert Backup.prune(dir: dir, keep: 2) == 3

      remaining = Backup.list(dir: dir)
      assert length(remaining) == 2

      # The newest two, not any two.
      assert hd(remaining).created_at.day == 5
    end

    test "counting rather than ageing, so a machine that was off keeps its last one", %{dir: dir} do
      src = source(dir)
      {:ok, _} = Backup.create(dir: dir, source: src, stamp: ~U[2020-01-01 00:00:00Z])

      # Years old, and the only one there. An age rule would have thrown away
      # the last backup of a laptop that spent a season in a cupboard.
      assert Backup.prune(dir: dir, keep: 30) == 0
      assert length(Backup.list(dir: dir)) == 1
    end
  end
end
