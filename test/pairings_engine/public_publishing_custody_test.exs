defmodule PairingsEngine.PublicPublishingCustodyTest do
  @moduledoc """
  Where an installation key must never be: a backup, an export, a hand-off
  file, a restore point, a TRF. OpenResults' contract ("OpenPairings
  desktop", step 3) - never written into a backup or export, never carried
  by a restore onto another machine.

  Stricter than a tournament's `openresults_key`, which a backup carries on
  purpose (`PairingsEngine.Backup`'s moduledoc), so the two are asserted side
  by side: the backup keeps the tournament key and loses the installation's.

  ## Why the backup half builds its own database

  For the reason `BackupTest` gives: a backup copies the database FILE, and a
  row inserted through the sandbox is invisible to it. So a real database is
  stamped out of the test schema and the rows are written into it directly.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{
    Backup,
    Handoff,
    Publishing,
    Repo,
    Snapshots,
    TournamentExport,
    Tournaments,
    TrfExport
  }

  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.PublicServerStub, as: Server
  alias PairingsEngine.Publishing.Installation
  alias PairingsEngine.Tournaments.Player

  setup do
    previous = Application.get_env(:pairings_engine, :local_mode)
    Application.put_env(:pairings_engine, :local_mode, true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end
    end)

    Publishing.put_endpoint(nil)
    Publishing.put_token(nil)
    :ok
  end

  describe "a backup" do
    setup do
      dir = Path.join(System.tmp_dir!(), "opbak-custody-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn ->
        File.rm_rf(dir)
        File.rm(live_database() <> ".restored")
      end)

      Application.delete_env(:pairings_engine, :backup_passphrase)
      {:ok, dir: dir}
    end

    defp live_database, do: Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database]

    defp source_with_installation(dir) do
      path = Path.join(dir, "source.db")

      {:ok, conn} = Exqlite.Sqlite3.open(live_database())
      :ok = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{path}'")
      :ok = Exqlite.Sqlite3.close(conn)

      {:ok, conn} = Exqlite.Sqlite3.open(path)

      for table <- ~w(pairings rounds players tournaments fide_players meta) do
        :ok = Exqlite.Sqlite3.execute(conn, "DELETE FROM #{table}")
      end

      prefix = Installation.meta_prefix()

      rows = [
        {"openresults_endpoint", "https://openresults.zerotwo.cloud"},
        {prefix <> "key", Server.key()},
        {prefix <> "id", Server.installation_id()},
        {prefix <> "server", "https://openresults.zerotwo.cloud"},
        {prefix <> "consent", ~s({"server":"https://openresults.zerotwo.cloud"})},
        {prefix <> "state", ~s({"status":403,"code":"address_blocked"})}
      ]

      for {key, value} <- rows do
        :ok =
          Exqlite.Sqlite3.execute(
            conn,
            "INSERT INTO meta (key, value) VALUES ('#{key}', '#{value}')"
          )
      end

      :ok =
        Exqlite.Sqlite3.execute(conn, """
        INSERT INTO tournaments (name, type, rounds_count, public_slug, openresults_key,
                                 tiebreaks, round_dates, categories, category_rules,
                                 fide_id_ranges, officials, inserted_at, updated_at)
        VALUES ('Custody Open', 'swiss', 3, 'Mint3dSlug12', 'a-tournament-key-that-stays',
                '[]', '[]', '[]', '{}', '[]', '{}',
                '2026-09-12 00:00:00', '2026-09-12 00:00:00')
        """)

      :ok = Exqlite.Sqlite3.close(conn)
      path
    end

    defp meta_keys(path) do
      {:ok, conn} = Exqlite.Sqlite3.open(path)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT key FROM meta ORDER BY key")
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      :ok = Exqlite.Sqlite3.close(conn)
      Enum.map(rows, fn [key] -> key end)
    end

    test "leaves every installation record out - not a byte of the key in the file", %{dir: dir} do
      src = source_with_installation(dir)
      assert File.read!(src) =~ Server.key()

      assert {:ok, backup} = Backup.create(dir: dir, source: src)

      # The file as written: header, then the gzipped database.
      [_magic, _header, payload] = backup |> File.read!() |> String.split("\n", parts: 3)
      database = :zlib.gunzip(payload)

      refute database =~ Server.key()
      refute database =~ "orik_"
      refute database =~ Server.installation_id()
    end

    test "restored anywhere, it is not this installation - and it still manages its tournaments",
         %{dir: dir} do
      src = source_with_installation(dir)
      assert {:ok, backup} = Backup.create(dir: dir, source: src)
      assert {:ok, restored} = Backup.restore(backup)

      keys = meta_keys(restored)
      refute Enum.any?(keys, &String.starts_with?(&1, Installation.meta_prefix()))
      # What is not the installation's comes back as it was.
      assert "openresults_endpoint" in keys

      {:ok, conn} = Exqlite.Sqlite3.open(restored)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT openresults_key FROM tournaments")
      {:ok, [[tournament_key]]} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      :ok = Exqlite.Sqlite3.close(conn)

      assert tournament_key == "a-tournament-key-that-stays"
    end
  end

  describe "everything else that leaves the machine" do
    setup do
      user =
        Repo.insert!(%User{
          email: "custody#{System.unique_integer([:positive])}@example.com",
          confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
        })

      scope = Scope.for_user(user)

      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Custody Open",
          "type" => "swiss",
          "rounds_count" => "3"
        })

      Repo.insert!(%Player{tournament_id: tournament.id, name: "A", pairing_number: 1})

      # Registered and published through the real requests, so the key is
      # genuinely in this database and the tournament has a key of its own.
      Server.install(self())
      {:ok, info} = Installation.server_info()
      Installation.give_consent(info)
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)
      assert {1, 0} = Publishing.drain()
      assert Installation.key() == Server.key()

      {:ok, scope: scope, tournament: Tournaments.get_tournament!(tournament.id)}
    end

    defp clean!(data) do
      text = if is_binary(data), do: data, else: Jason.encode!(data)
      refute text =~ Server.key()
      refute text =~ "orik_"
      text
    end

    test "a tournament export, and the export of everything", %{scope: scope, tournament: t} do
      export = clean!(TournamentExport.export_tournament(t))
      clean!(TournamentExport.export_all(scope))

      # The tournament's own key is carried, deliberately; the installation's
      # is not, and neither is the marker that the slug was minted.
      assert export =~ t.openresults_key
      refute export =~ "public_slug_minted_at"
    end

    test "a hand-off file", %{scope: scope, tournament: t} do
      assert {:ok, envelope} = Handoff.hand_off(t, "the venue laptop", scope)
      clean!(envelope)
    end

    test "a restore point", %{scope: scope, tournament: t} do
      assert {:ok, snapshot} = Snapshots.capture(t, "test.custody", scope)
      clean!(snapshot.payload)
    end

    test "a TRF", %{tournament: t} do
      assert {:ok, text} = TrfExport.export(t)
      clean!(text)
    end

    test "an import of any of those does not make this or another machine registered", %{
      scope: scope,
      tournament: t
    } do
      envelope = t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()

      # Forget this installation, as a different machine would be.
      Installation.start_over(%{host: "openresults.zerotwo.cloud", operator: nil})
      PairingsEngine.Meta.delete(Installation.meta_prefix() <> "consent")
      refute Installation.registered?()

      assert {:ok, _} = PairingsEngine.TournamentImport.import(envelope, scope)
      refute Installation.registered?()
      refute Installation.consented?()
    end
  end
end
