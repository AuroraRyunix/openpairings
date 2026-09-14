defmodule PairingsEngine.Support.KbsbSqliteFixture do
  @moduledoc """
  Builds a synthetic `players.sqlite` (the real schema, fake rows) for
  tests - optionally with a `clubs` table - and zips it, so tests can
  exercise `PairingsEngine.Federations.BEL.SqliteFile`/`Http`/`Sync`
  without a real KBSB download or any personal data.
  """

  @columns ~w(IdNumber Name Sex Birthday Fed Club Affiliated Elo
              EloPrevious Gain Games GamesPrevious Performance Opponents
              LastGames Border Arbiter NatPlayer NatFideSign G Died FideId
              LoginModif DateModif)

  @doc """
  `rows` is a list of maps with (a subset of) atom keys matching the real
  column names, e.g. `%{IdNumber: 1, Name: "Peeters, Jan", Club: 42,
  Affiliated: 1, Died: 0, Elo: 1850, Birthday: "19900101", FideId: nil}`.
  Any column not given defaults to `nil` (or 0 for `Affiliated`/`Died`).

  `clubs` is an optional list of `%{Club: number, Name: name}` maps - when
  given, a `clubs` table is created alongside `players`.

  Returns the raw bytes of the `.sqlite` file.
  """
  def build_sqlite(rows, clubs \\ nil) do
    path =
      Path.join(System.tmp_dir!(), "kbsb_fixture_#{System.unique_integer([:positive])}.sqlite")

    {:ok, conn} = Exqlite.Sqlite3.open(path)

    create_sql =
      "CREATE TABLE players (" <>
        Enum.map_join(@columns, ", ", fn
          "IdNumber" -> "IdNumber INTEGER PRIMARY KEY"
          col -> col
        end) <> ")"

    :ok = Exqlite.Sqlite3.execute(conn, create_sql)

    Enum.each(rows, fn row ->
      values = Enum.map(@columns, &Map.get(row, String.to_atom(&1)))
      placeholders = Enum.map_join(@columns, ", ", fn _ -> "?" end)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO players VALUES (#{placeholders})")
      :ok = Exqlite.Sqlite3.bind(stmt, values)
      :done = Exqlite.Sqlite3.step(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)
    end)

    if clubs do
      # The real pinned shape (confirmed against KBSB's actual
      # `players_202608.zip`, 2026-09-13): `Name` is nullable, and there's
      # an extra `Federation` column this code never reads.
      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "CREATE TABLE clubs (Club INTEGER PRIMARY KEY, Name VARCHAR(100), Federation VARCHAR(20))"
        )

      Enum.each(clubs, fn %{Club: num} = club ->
        name = Map.get(club, :Name)
        federation = Map.get(club, :Federation)
        {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO clubs VALUES (?, ?, ?)")
        :ok = Exqlite.Sqlite3.bind(stmt, [num, name, federation])
        :done = Exqlite.Sqlite3.step(conn, stmt)
        Exqlite.Sqlite3.release(conn, stmt)
      end)
    end

    Exqlite.Sqlite3.close(conn)
    bytes = File.read!(path)
    File.rm(path)
    bytes
  end

  @doc "Zips `sqlite_bytes` under the entry name `players.sqlite`, as KBSB's real zip does."
  def zip(sqlite_bytes) do
    tmp = Path.join(System.tmp_dir!(), "kbsb_fixture_src_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    sqlite_path = Path.join(tmp, "players.sqlite")
    File.write!(sqlite_path, sqlite_bytes)

    zip_path = Path.join(tmp, "players.zip")

    {:ok, _} =
      :zip.create(String.to_charlist(zip_path), [~c"players.sqlite"],
        cwd: String.to_charlist(tmp)
      )

    bytes = File.read!(zip_path)
    File.rm_rf!(tmp)
    bytes
  end

  @doc "One default fake row, overridable via `overrides`."
  def default_row(overrides \\ %{}) do
    Map.merge(
      %{
        IdNumber: 100_001,
        Name: "Peeters, Jan",
        Sex: "M",
        Birthday: "19900615",
        Fed: "BEL",
        Club: 42,
        Affiliated: 1,
        Elo: 1850,
        EloPrevious: 1840,
        Gain: 10,
        Games: 5,
        GamesPrevious: 4,
        Performance: 1900,
        Opponents: "",
        LastGames: "",
        Border: 0,
        Arbiter: 0,
        NatPlayer: 1,
        NatFideSign: "",
        G: 0,
        Died: 0,
        FideId: 10_012_345,
        LoginModif: "2026-01-01",
        DateModif: "2026-01-01"
      },
      overrides
    )
  end
end
