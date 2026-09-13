defmodule PairingsEngine.Federations.BEL.SqliteFileTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Federations.BEL.SqliteFile
  alias PairingsEngine.Support.KbsbSqliteFixture, as: Fixture

  describe "zip?/1 and sqlite?/1" do
    test "detect a zip by its PK signature" do
      zip = Fixture.zip(Fixture.build_sqlite([Fixture.default_row()]))
      assert SqliteFile.zip?(zip)
      refute SqliteFile.sqlite?(zip)
    end

    test "detect a bare sqlite file by its header" do
      sqlite = Fixture.build_sqlite([Fixture.default_row()])
      assert SqliteFile.sqlite?(sqlite)
      refute SqliteFile.zip?(sqlite)
    end

    test "neither for an unrelated binary (e.g. the old CSV upload)" do
      refute SqliteFile.zip?("MATRICULE;NOM\n1;Peeters\n")
      refute SqliteFile.sqlite?("MATRICULE;NOM\n1;Peeters\n")
    end
  end

  describe "read/1" do
    test "reads players from a bare sqlite file, with no clubs table" do
      sqlite = Fixture.build_sqlite([Fixture.default_row()])

      assert {:ok, %{rows: [row], clubs: nil}} = SqliteFile.read(sqlite)
      assert row["IdNumber"] == 100_001
      assert row["Name"] == "Peeters, Jan"
    end

    test "reads players from a zip (the real download shape)" do
      zip = Fixture.zip(Fixture.build_sqlite([Fixture.default_row()]))

      assert {:ok, %{rows: [_row], clubs: nil}} = SqliteFile.read(zip)
    end

    test "reads the optional clubs table when present (the pinned shape)" do
      sqlite =
        Fixture.build_sqlite(
          [Fixture.default_row()],
          [%{Club: 42, Name: "KGSRL"}, %{Club: 99, Name: "Unused Club"}]
        )

      assert {:ok, %{clubs: clubs}} = SqliteFile.read(sqlite)
      assert clubs == %{42 => "KGSRL", 99 => "Unused Club"}
    end

    test "reads a clubs table in KBSB's real shape: extra Federation column, NULL name" do
      sqlite =
        Fixture.build_sqlite(
          [
            Fixture.default_row(%{IdNumber: 1, Club: 42}),
            # A defunct club: a player references it, but it has no row in
            # `clubs` at all - matches the real file's 6 such numbers,
            # every one of them unaffiliated.
            Fixture.default_row(%{IdNumber: 2, Club: 999, Affiliated: 0})
          ],
          [
            %{Club: 42, Name: "KGSRL", Federation: "VSF"},
            # NULL name - present in the schema even though the real file
            # had none on 2026-09-13. Treated the same as no row.
            %{Club: 7, Name: nil, Federation: "FEFB"}
          ]
        )

      assert {:ok, %{clubs: clubs}} = SqliteFile.read(sqlite)
      assert clubs == %{42 => "KGSRL"}
      refute Map.has_key?(clubs, 7)
      refute Map.has_key?(clubs, 999)
    end

    test "errors on a missing players table" do
      path = Path.join(System.tmp_dir!(), "empty_#{System.unique_integer([:positive])}.sqlite")
      {:ok, conn} = Exqlite.Sqlite3.open(path)
      Exqlite.Sqlite3.execute(conn, "CREATE TABLE something_else (x INTEGER)")
      Exqlite.Sqlite3.close(conn)
      bytes = File.read!(path)
      File.rm(path)

      assert {:error, message} = SqliteFile.read(bytes)
      assert message =~ "no \"players\" table"
    end

    test "errors on a players table missing a required column" do
      path = Path.join(System.tmp_dir!(), "partial_#{System.unique_integer([:positive])}.sqlite")
      {:ok, conn} = Exqlite.Sqlite3.open(path)

      Exqlite.Sqlite3.execute(
        conn,
        "CREATE TABLE players (IdNumber INTEGER PRIMARY KEY, Name TEXT)"
      )

      Exqlite.Sqlite3.close(conn)
      bytes = File.read!(path)
      File.rm(path)

      assert {:error, message} = SqliteFile.read(bytes)
      assert message =~ "missing column"
    end

    test "errors on a corrupt zip" do
      assert {:error, _reason} = SqliteFile.read(<<0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0>>)
    end

    test "cleans up its temp file after reading" do
      before_files = File.ls!(System.tmp_dir!())
      sqlite = Fixture.build_sqlite([Fixture.default_row()])
      {:ok, _} = SqliteFile.read(sqlite)
      after_files = File.ls!(System.tmp_dir!())

      assert Enum.count(after_files, &String.starts_with?(&1, "kbsb_players_")) ==
               Enum.count(before_files, &String.starts_with?(&1, "kbsb_players_"))
    end
  end

  describe "to_member_row/2" do
    test "applies the field allowlist: birthday reduces to a year, modif columns never appear" do
      raw = %{
        "IdNumber" => 100_001,
        "Name" => "Peeters, Jan",
        "Sex" => "M",
        "Birthday" => "19900615",
        "Fed" => "BEL",
        "Club" => 42,
        "Affiliated" => 1,
        "Elo" => 1850,
        "EloPrevious" => 1840,
        "Gain" => 10,
        "Games" => 5,
        "GamesPrevious" => 4,
        "Performance" => 1900,
        "Opponents" => "",
        "LastGames" => "",
        "Border" => 0,
        "Arbiter" => 0,
        "NatPlayer" => 1,
        "NatFideSign" => "",
        "G" => 0,
        "Died" => 0,
        "FideId" => 10_012_345
      }

      row = SqliteFile.to_member_row(raw, %{42 => "KGSRL"})

      assert row.national_id == "100001"
      assert row.last_name == "Peeters"
      assert row.first_name == "Jan"
      assert row.national_rating == 1850
      assert row.fide_id == 10_012_345
      assert row.club_number == 42
      assert row.club_name == "KGSRL"
      assert row.federation == "BEL"
      assert row.birth_year == 1990
      assert row.affiliated == true
      assert row.died == false

      refute Map.has_key?(row, :login_modif)
      refute Map.has_key?(row, :date_modif)
      refute Map.has_key?(row, :birthday)
    end

    test "died and affiliated convert 1/0 to booleans" do
      raw_dead = %{
        "IdNumber" => 2,
        "Name" => "Dubois, Marie",
        "Birthday" => nil,
        "Fed" => "",
        "Club" => nil,
        "Affiliated" => 0,
        "Elo" => nil,
        "FideId" => nil,
        "Died" => 1
      }

      row = SqliteFile.to_member_row(raw_dead)
      assert row.died == true
      assert row.affiliated == false
      assert row.club_name == ""
      assert row.birth_year == nil
    end

    test "a name with no first name (single field) yields an empty first_name" do
      row = SqliteFile.to_member_row(%{"IdNumber" => 3, "Name" => "Someone"})
      assert row.last_name == "Someone"
      assert row.first_name == ""
    end
  end
end
