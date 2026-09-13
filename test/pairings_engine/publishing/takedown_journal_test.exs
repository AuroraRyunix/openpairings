defmodule PairingsEngine.Publishing.TakedownJournalTest do
  @moduledoc """
  A restore must not undo a takedown (restore drill, finding 2): a tournament
  withdrawn from the results site after the backup came back online on its
  next change. `PairingsEngine.Publishing.TakedownJournal` keeps the
  takedowns outside the database and puts them back in force at boot.

  Three halves: what a takedown writes; that the boot replay switches exactly
  the right tournaments off and nothing else, once; and the whole thing
  against a real backup restored with `Backup.restore/1` and read by the
  app's own Repo, which is what a boot after a restore does.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query

  alias PairingsEngine.{Audit, Backup, Publishing, Repo, Tournaments}
  alias PairingsEngine.Publishing.{QueueEntry, TakedownJournal}
  alias PairingsEngine.Tournaments.Tournament

  # The replay says what it did at warning level, as it should at a boot.
  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "op-takedowns-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "pairings_engine-takedowns.jsonl")

    previous = Application.get_env(:pairings_engine, :takedown_journal)
    Application.put_env(:pairings_engine, :takedown_journal, file)

    on_exit(fn ->
      Application.put_env(:pairings_engine, :takedown_journal, previous)
      File.rm_rf(dir)
    end)

    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")

    {:ok, dir: dir, journal: file}
  end

  defp stub(fun), do: Req.Test.stub(PairingsEngine.PublishingTest, fun)

  defp published_tournament do
    t =
      Repo.insert!(%Tournament{
        name: "Journal Open",
        type: "swiss",
        rounds_count: 3,
        publish_to_openresults: true,
        public_slug: "jrnl-#{System.unique_integer([:positive])}"
      })

    stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
    {:ok, _} = Publishing.publish(t)
    Tournaments.get_tournament!(t.id)
  end

  defp lines(file) do
    file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  describe "a takedown is written down" do
    test "beside the database, one line, with the address and a fingerprint - never the key",
         %{journal: file} do
      t = published_tournament()
      stub(fn conn -> Req.Test.json(conn, %{"status" => "deleted"}) end)

      assert {:ok, _} = Publishing.take_down(t)

      assert [line] = lines(file)
      assert line["v"] == 1
      assert line["kind"] == "taken_down"
      assert line["tournament_id"] == t.id
      assert line["slug"] == t.public_slug
      assert line["key_sha256"] == TakedownJournal.fingerprint(t.openresults_key)
      assert {:ok, _, 0} = DateTime.from_iso8601(line["at"])

      refute File.read!(file) =~ t.openresults_key
    end

    test "moving to a new address and deleting for good are written as what they were", %{
      journal: file
    } do
      moved = published_tournament()
      retracted = published_tournament()
      stub(fn conn -> Req.Test.json(conn, %{"status" => "deleted", "ok" => true}) end)

      assert {:ok, _, _} = Publishing.rotate_address(moved)
      assert :ok = Publishing.retract(retracted)

      assert [%{"kind" => "moved", "slug" => moved_slug}, %{"kind" => "retracted"}] = lines(file)
      assert moved_slug == moved.public_slug
    end

    test "a takedown the results site refused writes nothing", %{journal: file} do
      t = published_tournament()
      stub(fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"error":"key_mismatch"})) end)

      assert {:error, _} = Publishing.take_down(t)
      refute File.exists?(file)
    end

    test "it lives beside the database unless configured, and can be switched off" do
      Application.delete_env(:pairings_engine, :takedown_journal)
      database = Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database]
      name = database |> Path.basename() |> Path.rootname()

      assert TakedownJournal.path() ==
               Path.join(Path.dirname(database), name <> "-takedowns.jsonl")

      Application.put_env(:pairings_engine, :takedown_journal, false)
      assert TakedownJournal.path() == nil
    end
  end

  describe "the boot replay" do
    test "switches off exactly the tournaments that still hold the claim a takedown retired - once",
         %{journal: file} do
      # The state a restored backup brings back: published, key and all, with
      # a publish waiting in the queue.
      withdrawn = published_tournament()
      :ok = Publishing.enqueue(withdrawn)

      # Taken down after the backup, then deliberately published again: its
      # key now is one minted since, so the line about the old one is history.
      republished = published_tournament()

      # Moved to a new address after the backup.
      moved = published_tournament()

      at = ~U[2026-09-13 10:02:11Z]
      TakedownJournal.record(withdrawn, :taken_down, now: at)

      TakedownJournal.record(%{republished | openresults_key: "the-key-before"}, :taken_down,
        now: at
      )

      File.write!(file, "{\"torn\": \n", [:append])
      TakedownJournal.record(moved, :moved, now: at)

      assert TakedownJournal.replay() == 2

      after_withdrawn = Tournaments.get_tournament!(withdrawn.id)
      refute after_withdrawn.publish_to_openresults
      assert after_withdrawn.openresults_key == nil
      assert after_withdrawn.public_slug == withdrawn.public_slug
      refute Repo.exists?(from q in QueueEntry, where: q.tournament_id == ^withdrawn.id)

      # Published again on purpose after the takedown: left alone.
      after_republished = Tournaments.get_tournament!(republished.id)
      assert after_republished.publish_to_openresults
      assert after_republished.openresults_key == republished.openresults_key

      # Moved: off, and at a new address, so turning publishing back on cannot
      # revive the one it moved away from.
      after_moved = Tournaments.get_tournament!(moved.id)
      refute after_moved.publish_to_openresults
      assert after_moved.openresults_key == nil
      refute after_moved.public_slug == moved.public_slug

      assert [%{details: %{"slug" => slug, "kind" => "taken_down"}}] =
               Audit.list_for_tournament(withdrawn.id, action: "openresults.kept_withdrawn")

      assert slug == withdrawn.public_slug

      assert [%{details: %{"kind" => "moved"}}] =
               Audit.list_for_tournament(moved.id, action: "openresults.kept_withdrawn")

      # Idempotent: the claims are gone, so the lines match nothing now.
      assert TakedownJournal.replay() == 0

      assert length(Audit.list_for_tournament(withdrawn.id, action: "openresults.kept_withdrawn")) ==
               1

      # And an arbiter turning publishing back on afterwards is not undone by
      # the next boot.
      {:ok, _} = Tournaments.set_publish_to_openresults(after_withdrawn, true)
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
      {:ok, _} = Publishing.publish(Tournaments.get_tournament!(withdrawn.id))

      assert TakedownJournal.replay() == 0
      assert Tournaments.get_tournament!(withdrawn.id).publish_to_openresults
    end

    test "no journal, an empty one, or a switched-off one: nothing happens", %{journal: file} do
      assert TakedownJournal.replay() == 0
      File.write!(file, "")
      assert TakedownJournal.replay() == 0
      assert TakedownJournal.replay(path: nil) == 0
    end
  end

  describe "a restored backup, booted" do
    setup %{dir: dir} do
      on_exit(fn ->
        database = Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database]
        for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> ".restored" <> suffix)
      end)

      Application.delete_env(:pairings_engine, :backup_passphrase)
      {:ok, backups: Path.join(dir, "backups")}
    end

    test "a tournament taken down after the backup stays off the results site", %{
      dir: dir,
      journal: file,
      backups: backups
    } do
      key = Publishing.generate_key()
      source = source_with_published_tournament(dir, key)

      # The backup: published, key, a queued publish.
      {:ok, backup} = Backup.create(dir: backups, source: source)

      # After it, the arbiter took the tournament down - which wrote the line.
      TakedownJournal.record(
        %Tournament{id: 1, public_slug: "drillopen001", openresults_key: key},
        :taken_down
      )

      assert [%{"slug" => "drillopen001"}] = lines(file)

      # The restore, and the boot's replay against the restored file, through
      # the app's own Repo.
      {:ok, restored} = Backup.restore(backup)

      repo =
        start_supervised!(%{
          id: :restored_repo,
          start:
            {PairingsEngine.Repo, :start_link,
             [[name: nil, database: restored, pool: DBConnection.ConnectionPool, pool_size: 1]]}
        })

      previous = Repo.put_dynamic_repo(repo)

      try do
        # Before the replay: exactly what the drill saw come back.
        assert %{publish_to_openresults: true, openresults_key: ^key} = Repo.get!(Tournament, 1)
        assert Repo.exists?(QueueEntry)

        assert TakedownJournal.replay() == 1

        assert %{publish_to_openresults: false, openresults_key: nil} = Repo.get!(Tournament, 1)
        refute Repo.exists?(QueueEntry)
        # Nothing left that the drain could send, nothing a change could enqueue.
        refute Publishing.published?(Repo.get!(Tournament, 1))

        assert [%{action: "openresults.kept_withdrawn", user_id: nil}] =
                 Audit.list_for_tournament(1, action: "openresults.kept_withdrawn")
      after
        Repo.put_dynamic_repo(previous)
      end
    end
  end

  defp source_with_published_tournament(dir, key) do
    path = Path.join(dir, "source.db")
    database = Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database]

    {:ok, conn} = Exqlite.Sqlite3.open(database)
    :ok = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{path}'")
    :ok = Exqlite.Sqlite3.close(conn)

    {:ok, conn} = Exqlite.Sqlite3.open(path)

    {:ok, statement} =
      Exqlite.Sqlite3.prepare(
        conn,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' " <>
          "AND name NOT LIKE '%_fts%' AND name <> 'schema_migrations'"
      )

    {:ok, tables} = Exqlite.Sqlite3.fetch_all(conn, statement)
    :ok = Exqlite.Sqlite3.release(conn, statement)

    for [table] <- tables, do: :ok = Exqlite.Sqlite3.execute(conn, ~s(DELETE FROM "#{table}"))

    stamp = "2026-09-13 00:00:00"

    for sql <- [
          """
          INSERT INTO tournaments (id, name, type, rounds_count, public_slug, openresults_key,
                                   publish_to_openresults, tiebreaks, round_dates, categories,
                                   category_rules, fide_id_ranges, officials, inserted_at, updated_at)
          VALUES (1, 'Drill Open', 'swiss', 3, 'drillopen001', '#{key}', 1, '[]', '[]', '[]', '{}',
                  '[]', '{}', '#{stamp}', '#{stamp}')
          """,
          "INSERT INTO publish_queue (tournament_id, attempts, inserted_at, updated_at) VALUES (1, 0, '#{stamp}', '#{stamp}')"
        ] do
      :ok = Exqlite.Sqlite3.execute(conn, sql)
    end

    :ok = Exqlite.Sqlite3.close(conn)
    path
  end
end
