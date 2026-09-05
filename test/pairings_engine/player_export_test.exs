defmodule PairingsEngine.PlayerExportTest do
  # No database: `export/2` takes the players it is given, so the whole
  # module can be exercised on plain structs.
  use ExUnit.Case, async: true

  alias PairingsEngine.PlayerExport
  alias PairingsEngine.Tournaments.Player

  @bom "﻿"

  defp player(attrs), do: struct(%Player{}, attrs)

  defp lines(csv) do
    csv
    |> String.replace_prefix(@bom, "")
    # NOT trim: true - a player whose only column is empty is a
    # legitimately empty row, and trimming hid it. The file ends with
    # CRLF, so the last element is the empty string after it.
    |> String.split("\r\n")
    |> Enum.drop(-1)
  end

  describe "columns and their order" do
    test "the chosen order is the file's order, not the declaration order" do
      p = player(name: "Carlsen, Magnus", club: "Offerspill", fide_rating: 2830)

      forwards = PlayerExport.export([p], columns: [:name, :club, :fide_rating], bom: false)
      backwards = PlayerExport.export([p], columns: [:fide_rating, :club, :name], bom: false)

      assert hd(lines(forwards)) == "Name,Club,FIDE rating"
      assert hd(lines(backwards)) == "FIDE rating,Club,Name"

      assert lines(forwards) |> Enum.at(1) == "\"Carlsen, Magnus\",Offerspill,2830"
      assert lines(backwards) |> Enum.at(1) == "2830,Offerspill,\"Carlsen, Magnus\""
    end

    test "parse_columns keeps the order given and drops unknown and repeated keys" do
      assert PlayerExport.parse_columns("club,name,club,nonsense") == [:club, :name]
    end

    test "parse_columns falls back rather than producing a file with no columns" do
      assert PlayerExport.parse_columns("nonsense") == PlayerExport.default_columns()
      assert PlayerExport.parse_columns("") == PlayerExport.default_columns()
      assert PlayerExport.parse_columns(nil) == PlayerExport.default_columns()
    end
  end

  describe "delimiters" do
    test "the separator is the one asked for" do
      p = player(name: "A", club: "B")

      for {name, char} <- [{"comma", ","}, {"semicolon", ";"}, {"tab", "\t"}, {"pipe", "|"}] do
        csv = PlayerExport.export([p], columns: [:name, :club], delimiter: name, bom: false)
        assert hd(lines(csv)) == "Name#{char}Club"
      end
    end

    test "a value carrying the delimiter is quoted - and only then" do
      # The same name is safe under a semicolon and needs quoting under a
      # comma, which is the whole reason the separator is offered.
      p = player(name: "Carlsen, Magnus")

      comma = PlayerExport.export([p], columns: [:name], delimiter: "comma", bom: false)
      semi = PlayerExport.export([p], columns: [:name], delimiter: "semicolon", bom: false)

      assert Enum.at(lines(comma), 1) == "\"Carlsen, Magnus\""
      assert Enum.at(lines(semi), 1) == "Carlsen, Magnus"
    end

    test "a quote in a value is doubled inside a quoted field" do
      p = player(name: ~s(Ann "Nan" Lee))
      csv = PlayerExport.export([p], columns: [:name], bom: false)
      assert Enum.at(lines(csv), 1) == ~s("Ann ""Nan"" Lee")
    end

    test "an unknown delimiter name falls back to a comma instead of failing" do
      csv = PlayerExport.export([player(name: "A")], columns: [:name], delimiter: "🙂", bom: false)
      assert hd(lines(csv)) == "Name"
    end
  end

  describe "which players" do
    test "skip_absent drops the permanently absent and keeps the rest" do
      players = [
        player(name: "Here", absent: false),
        player(name: "Gone", absent: true),
        # A player who misses one round is NOT absent from the tournament.
        player(name: "Round three off", absent: false, absent_rounds: "3")
      ]

      kept =
        players
        |> PlayerExport.export(columns: [:name], sort: "name", skip_absent: true, bom: false)
        |> lines()
        |> tl()

      assert kept == ["Here", "Round three off"]
    end

    test "without the option every player is exported" do
      players = [player(name: "Here"), player(name: "Gone", absent: true)]
      csv = PlayerExport.export(players, columns: [:name], sort: "name", bom: false)
      assert tl(lines(csv)) == ["Gone", "Here"]
    end
  end

  describe "row order" do
    test "seed uses the starting rank" do
      players = [
        player(name: "Third", pairing_number: 3),
        player(name: "First", pairing_number: 1),
        player(name: "Second", pairing_number: 2)
      ]

      csv = PlayerExport.export(players, columns: [:name], sort: "seed", bom: false)
      assert tl(lines(csv)) == ["First", "Second", "Third"]
    end

    test "players with no starting rank yet keep the order they arrived in" do
      # `Tournaments.list_players/1` hands them over in rating-then-name
      # order, which is the seeding they WOULD be given - so a list
      # exported before the first pairing is still in seed order.
      players = [
        player(name: "Strongest", pairing_number: nil),
        player(name: "Middle", pairing_number: nil),
        player(name: "Weakest", pairing_number: nil)
      ]

      csv = PlayerExport.export(players, columns: [:name], sort: "seed", bom: false)
      assert tl(lines(csv)) == ["Strongest", "Middle", "Weakest"]
    end

    test "an already-seeded player sorts ahead of one not yet seeded" do
      players = [
        player(name: "Late", pairing_number: nil),
        player(name: "Seeded", pairing_number: 9)
      ]

      csv = PlayerExport.export(players, columns: [:name], sort: "seed", bom: false)
      assert tl(lines(csv)) == ["Seeded", "Late"]
    end

    test "name sorts alphabetically, ignoring case" do
      players = [player(name: "de Vries"), player(name: "Adams"), player(name: "Zhao")]
      csv = PlayerExport.export(players, columns: [:name], sort: "name", bom: false)
      assert tl(lines(csv)) == ["Adams", "de Vries", "Zhao"]
    end
  end

  describe "values" do
    test "rating used is the FIDE one when there is one, the national one otherwise" do
      rated = player(name: "A", fide_rating: 2200, national_rating: 2100)
      unrated = player(name: "B", fide_rating: 0, national_rating: 1800)

      csv = PlayerExport.export([rated, unrated], columns: [:name, :elo_used], bom: false)
      assert tl(lines(csv)) == ["A,2200", "B,1800"]
    end

    test "booleans read as yes and no, and a missing value is empty" do
      p = player(name: "A", absent: true, forfeit: false, fide_id: nil)
      csv = PlayerExport.export([p], columns: [:absent, :forfeit, :fide_id], bom: false)
      assert Enum.at(lines(csv), 1) == "yes,no,"
    end

    test "a birth date is ISO, and absent when unset" do
      with_date = player(name: "A", birth_date: ~D[1990-11-30])
      without = player(name: "B")

      csv = PlayerExport.export([with_date, without], columns: [:birth_date], bom: false)
      assert tl(lines(csv)) == ["1990-11-30", ""]
    end
  end

  describe "spreadsheet safety" do
    # Names are typed by whoever registered the player, so a name can be a
    # formula - which Excel and LibreOffice will run for whoever opens the
    # file.
    test "a name that looks like a formula is neutralised" do
      for name <- ["=HYPERLINK(\"http://x\",\"click\")", "+1+1", "@SUM(A1)", "-2+3"] do
        csv = PlayerExport.export([player(name: name)], columns: [:name], bom: false)
        assert Enum.at(lines(csv), 1) |> String.trim("\"") |> String.starts_with?("'")
      end
    end

    test "a negative number is left alone - the guard is for typed text only" do
      p = player(name: "A", extra_points: -1.5)
      csv = PlayerExport.export([p], columns: [:extra_points], bom: false)
      assert Enum.at(lines(csv), 1) == "-1.5"
    end
  end

  describe "the file itself" do
    test "rows end CRLF and the marker is there unless it is turned off" do
      csv = PlayerExport.export([player(name: "A")], columns: [:name])
      assert String.starts_with?(csv, @bom)
      assert csv == @bom <> "Name\r\nA\r\n"

      plain = PlayerExport.export([player(name: "A")], columns: [:name], bom: false)
      refute String.starts_with?(plain, @bom)
      assert plain == "Name\r\nA\r\n"
    end

    test "a tournament with no players still exports its header" do
      assert PlayerExport.export([], columns: [:name], bom: false) == "Name\r\n"
    end
  end
end
