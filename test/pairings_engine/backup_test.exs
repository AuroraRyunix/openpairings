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

  defp rating_rows(path), do: index_rows(path, "fide_players")

  # Statements released before the close: a connection closed with one still
  # prepared stays open until it is garbage-collected, and on Windows the
  # `.restored` file it holds then survives this file's `on_exit` cleanup.
  defp index_rows(path, table) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT COUNT(*) FROM #{table}")
    {:ok, [[count]]} = Exqlite.Sqlite3.fetch_all(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
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
      :ok = Exqlite.Sqlite3.release(conn, stmt)

      # And it still accepts writes, so the next sync can fill it.
      assert :ok =
               Exqlite.Sqlite3.execute(
                 conn,
                 "INSERT INTO fide_players (fide_id, name) VALUES (999, 'After, Restore')"
               )

      :ok = Exqlite.Sqlite3.close(conn)
    end

    # `kbsb_players_fts` arrived a day after the list of indexes to empty was
    # written, and was never added to it. So a backup emptied the mirror and
    # shipped the index over it intact: a restore came up with no KBSB players
    # and ~36k of them still in the index, which is a search offering names
    # that are not there.
    test "the KBSB index is emptied too, not just the FIDE one", %{dir: dir} do
      src =
        source(dir, [
          "DELETE FROM kbsb_players",
          """
          INSERT INTO kbsb_players (national_id, last_name, first_name, club_name, federation)
          VALUES ('50001', 'De Vos', 'Ilse', 'KGSRL', 'BEL')
          """
        ])

      assert index_rows(src, "kbsb_players_fts") == 1

      {:ok, path} = Backup.create(dir: dir, source: src)
      {:ok, restored} = Backup.restore(path)

      assert index_rows(restored, "kbsb_players_fts") == 0
    end

    # The results site's master key - it overwrites and deletes any tournament
    # there, break-glass included - was in plain text in every production
    # backup (restore drill, finding 6). A restore sets it again instead.
    test "the OpenResults operator token is not in the file; the address is", %{dir: dir} do
      token = "operator-token-#{System.unique_integer([:positive])}-that-must-not-travel"

      src =
        source(dir, [
          "DELETE FROM meta",
          "INSERT INTO meta (key, value) VALUES ('openresults_token', '#{token}')",
          "INSERT INTO meta (key, value) VALUES ('openresults_endpoint', 'http://localhost:4004')"
        ])

      assert File.read!(src) =~ token

      {:ok, path} = Backup.create(dir: dir, source: src)

      # Not a byte of it in the database the file carries - the VACUUM after
      # the delete is what keeps it out of a free page.
      [_magic, _header, payload] = path |> File.read!() |> String.split("\n", parts: 3)
      refute :zlib.gunzip(payload) =~ token

      {:ok, restored} = Backup.restore(path)
      {:ok, conn} = Exqlite.Sqlite3.open(restored)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT key, value FROM meta ORDER BY key")
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      :ok = Exqlite.Sqlite3.release(conn, stmt)
      :ok = Exqlite.Sqlite3.close(conn)

      assert ["openresults_endpoint", "http://localhost:4004"] in rows
      refute Enum.any?(rows, fn [key, _] -> key == "openresults_token" end)
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
      :ok = Exqlite.Sqlite3.release(conn, stmt)
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

    # The header is read BEFORE the AEAD tag can be checked - it is what
    # derives the key the tag is checked with - so its iteration count is
    # attacker-controlled input on a `mix pairings.backup verify|restore`.
    # Absurdly low weakens the KDF; absurdly high wedges the command in a
    # PBKDF2 loop with no early exit and no cancel.
    for {label, iterations} <- [{"far too low", 1}, {"absurdly high", 5_000_000_000}] do
      test "a header asking for #{label} PBKDF2 iterations is refused", %{dir: dir} do
        src = source(dir)
        {:ok, path} = Backup.create(dir: dir, source: src)

        retamper_iterations(path, unquote(iterations))

        assert {:error, message} = Backup.verify(path)
        assert message =~ "PBKDF2 iterations"
      end
    end

    test "a header's own (legitimate) iteration count is still honoured", %{dir: dir} do
      src = with_tournament(dir, "Iterations Open")
      {:ok, path} = Backup.create(dir: dir, source: src)

      # Rewriting it to the same value proves the crafted-header helper
      # itself does not break an otherwise-good file.
      [_magic, header, _payload] = String.split(File.read!(path), "\n", parts: 3)
      current = Jason.decode!(header)["crypto"]["iterations"]
      retamper_iterations(path, current)

      assert {:ok, info} = Backup.verify(path)
      assert info.tournaments == 1
    end
  end

  # Rewrites only the `crypto.iterations` field of a backup's header, leaving
  # the ciphertext (and so its AEAD tag) untouched.
  defp retamper_iterations(path, iterations) do
    [magic, header, payload] = String.split(File.read!(path), "\n", parts: 3)

    header =
      header
      |> Jason.decode!()
      |> update_in(["crypto", "iterations"], fn _ -> iterations end)
      |> Jason.encode!()

    File.write!(path, magic <> "\n" <> header <> "\n" <> payload)
  end

  describe "retention" do
    # Retention is days since 2026-09-13 (restore drill, finding 10): it was a
    # count of files, every boot spent one, and "30" was a month only on a box
    # nobody restarted.
    test "keeps what is younger than the window and removes what is older", %{dir: dir} do
      src = source(dir)

      for day <- 1..5 do
        stamp = DateTime.new!(Date.new!(2026, 8, day), ~T[12:00:00])
        {:ok, _} = Backup.create(dir: dir, source: src, stamp: stamp)
      end

      # Three a day on the 5th - three deploys - count once each, not against
      # a number of files.
      for hour <- [13, 14] do
        stamp = DateTime.new!(~D[2026-08-05], Time.new!(hour, 0, 0))
        {:ok, _} = Backup.create(dir: dir, source: src, stamp: stamp)
      end

      assert length(Backup.list(dir: dir)) == 7

      # Two days, seen from the 5th at 18:00: the 4th at noon is 30 hours old
      # and stays, the 3rd at noon is 54 hours old and goes.
      assert Backup.prune(dir: dir, days: 2, now: ~U[2026-08-05 18:00:00Z]) == 3

      assert Backup.list(dir: dir) |> Enum.map(&{&1.created_at.day, &1.created_at.hour}) ==
               [{5, 14}, {5, 13}, {5, 12}, {4, 12}]
    end

    test "the newest is kept however old, so a machine that was off keeps its last one", %{
      dir: dir
    } do
      src = source(dir)
      {:ok, _} = Backup.create(dir: dir, source: src, stamp: ~U[2020-01-01 00:00:00Z])
      {:ok, _} = Backup.create(dir: dir, source: src, stamp: ~U[2020-01-02 00:00:00Z])

      # Years old, both of them. An age rule alone would have thrown away the
      # last backup of a laptop that spent a season in a cupboard.
      assert Backup.prune(dir: dir, days: 30, now: ~U[2026-09-13 00:00:00Z]) == 1
      assert [%{created_at: ~U[2020-01-02 00:00:00Z]}] = Backup.list(dir: dir)
    end

    for days <- [0, -1, -3] do
      test "a window of #{days} days still never removes the newest", %{dir: dir} do
        src = source(dir)

        for day <- 1..4 do
          stamp = DateTime.new!(Date.new!(2026, 9, day), ~T[02:00:00])
          {:ok, _} = Backup.create(dir: dir, source: src, stamp: stamp)
        end

        # `Enum.drop(list, 0)` deleted every backup, the one just written
        # included, and a negative count dropped from the other end - keeping
        # the OLDEST and deleting the newest (drill finding 9). Below one is
        # one day now.
        Backup.prune(dir: dir, days: unquote(days), now: ~U[2026-09-04 12:00:00Z])

        assert [%{created_at: newest}] = Backup.list(dir: dir)
        assert newest.day == 4
      end
    end

    test "a configured retention below one day reads as one" do
      previous = Application.get_env(:pairings_engine, :backup_retention)

      try do
        for {set, read} <- [{0, 1}, {-5, 1}, {14, 14}, {"thirty", 30}] do
          Application.put_env(:pairings_engine, :backup_retention, set)
          assert Backup.retention() == read
        end
      after
        if previous,
          do: Application.put_env(:pairings_engine, :backup_retention, previous),
          else: Application.delete_env(:pairings_engine, :backup_retention)
      end
    end

    test "BACKUP_RETENTION that is not a whole number of days, at least one, stops the boot" do
      runtime = Path.expand("../../config/runtime.exs", __DIR__)

      data_dir =
        Path.join(System.tmp_dir!(), "opbak-runtime-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(data_dir) end)

      read = fn value ->
        with_env(
          %{
            "OPENPAIRINGS_LOCAL" => "1",
            "OPENPAIRINGS_DATA_DIR" => data_dir,
            "BACKUP_RETENTION" => value
          },
          fn -> Config.Reader.read!(runtime, env: :prod) end
        )
      end

      assert read.("14")[:pairings_engine][:backup_retention] == 14

      # Not "": on Windows setting a variable to nothing deletes it.
      for bad <- ["0", "-1", "30d", "1.5"] do
        assert_raise RuntimeError, ~r/BACKUP_RETENTION/, fn -> read.(bad) end
      end
    end
  end

  describe "the scheduler's first run" do
    @interval :timer.hours(24)

    test "is a few minutes after boot when there is no backup, or the newest is a day old" do
      assert Backup.Scheduler.first_delay(nil, @interval) == :timer.minutes(5)
      assert Backup.Scheduler.first_delay(:timer.hours(25), @interval) == :timer.minutes(5)
      assert Backup.Scheduler.first_delay(@interval, @interval) == :timer.minutes(5)
    end

    test "waits for the newest to come due, so a restart does not spend a backup" do
      # Written two hours ago: the next is due in twenty-two.
      assert Backup.Scheduler.first_delay(:timer.hours(2), @interval) == :timer.hours(22)
      # Just written: a full interval, and never more.
      assert Backup.Scheduler.first_delay(0, @interval) == @interval
      # Due in a minute: the few minutes after boot still come first.
      assert Backup.Scheduler.first_delay(@interval - :timer.minutes(1), @interval) ==
               :timer.minutes(5)
    end

    test "reads the newest backup's age from its header, never below zero", %{dir: dir} do
      src = source(dir)
      assert Backup.newest_age_ms(dir: dir) == nil

      {:ok, _} = Backup.create(dir: dir, source: src, stamp: ~U[2026-09-13 10:00:00Z])
      {:ok, _} = Backup.create(dir: dir, source: src, stamp: ~U[2026-09-12 10:00:00Z])

      assert Backup.newest_age_ms(dir: dir, now: ~U[2026-09-13 12:00:00Z]) == :timer.hours(2)
      # A clock that stepped back makes the newest look written in the future.
      assert Backup.newest_age_ms(dir: dir, now: ~U[2026-09-13 09:00:00Z]) == 0
    end
  end

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end
end
