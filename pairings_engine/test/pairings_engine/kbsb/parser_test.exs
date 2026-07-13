defmodule PairingsEngine.Kbsb.ParserTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Kbsb.Parser

  @fixture_path Path.join([__DIR__, "..", "..", "fixtures", "kbsb_sample.csv"])

  test "parses a semicolon-delimited file with header-driven columns" do
    binary = File.read!(@fixture_path)

    assert {:ok, rows} = Parser.parse(binary)
    assert length(rows) == 3

    [jan, marie, els] = rows

    assert jan.national_id == "12345"
    assert jan.last_name == "Peeters"
    assert jan.first_name == "Jan"
    assert jan.national_rating == 1850
    assert jan.fide_id == nil
    assert jan.club_number == 42
    assert jan.club_name == "KSK Antwerpen"
    assert jan.federation == "VSF"
    assert jan.birth_year == 1990

    assert marie.national_id == "67890"
    assert marie.last_name == "Dubois"
    assert marie.fide_id == 10_012_345
    assert marie.federation == "FEFB"

    # Blank numeric cells parse to nil, not 0 or an error.
    assert els.national_rating == nil
    assert els.fide_id == nil
  end

  test "rows missing a national id or a last name are dropped, not errored" do
    binary = """
    Matricule;Nom;Prenom;Elo
    ;Sans Matricule;X;1500
    999;;X;1500
    42;Valid;Y;1600
    """

    assert {:ok, rows} = Parser.parse(binary)
    assert length(rows) == 1
    assert hd(rows).national_id == "42"
  end

  test "columns are resolved by header name, order-independent" do
    binary = """
    Elo;Nom;Matricule
    1700;Reordered;555
    """

    assert {:ok, [row]} = Parser.parse(binary)
    assert row.national_id == "555"
    assert row.last_name == "Reordered"
    assert row.national_rating == 1700
  end

  test "recognises a comma-delimited file" do
    binary = "Matricule,Nom,Elo\n1,Comma,1400\n"

    assert {:ok, [row]} = Parser.parse(binary)
    assert row.national_id == "1"
    assert row.last_name == "Comma"
    assert row.national_rating == 1400
  end

  test "missing national id column is an error" do
    binary = "Nom;Elo\nFoo;1500\n"

    assert {:error, reason} = Parser.parse(binary)
    assert reason =~ "national ID"
  end

  test "missing name column is an error" do
    binary = "Matricule;Elo\n1;1500\n"

    assert {:error, reason} = Parser.parse(binary)
    assert reason =~ "name column"
  end

  test "an empty file is an error" do
    assert {:error, _reason} = Parser.parse("")
  end

  test "optional columns absent from the header default to nil/blank for every row" do
    binary = "Matricule;Nom\n1;OnlyRequired\n"

    assert {:ok, [row]} = Parser.parse(binary)
    assert row.first_name == ""
    assert row.national_rating == nil
    assert row.fide_id == nil
    assert row.club_name == ""
    assert row.federation == ""
    assert row.birth_year == nil
  end

  test "decodes Windows-1252 bytes (accented names) without crashing" do
    # "Prénom" header + "Aériale" name, encoded as Windows-1252/Latin-1 (0xE9 = é).
    binary = <<"Matricule;Nom;Elo\n1;A", 0xE9, "riale;1500\n">>

    assert {:ok, [row]} = Parser.parse(binary)
    assert row.last_name == "Aériale"
  end

  test "strips a UTF-8 BOM before parsing the header" do
    binary = "﻿Matricule;Nom\n1;BomTest\n"

    assert {:ok, [row]} = Parser.parse(binary)
    assert row.national_id == "1"
    assert row.last_name == "BomTest"
  end

  test "a UTF-8 BOM ahead of an otherwise CP1252-encoded file doesn't mojibake the header" do
    # Raw UTF-8 BOM bytes (EF BB BF), followed by a header/row that's
    # itself Windows-1252 (0xE9 = "é" in "Réserve"). If the BOM bytes were
    # stripped *after* CP1252 decoding (rather than before, on the raw
    # binary), they'd have already decoded into "ï»¿" and survived into the
    # header, producing a false "missing national ID column" error.
    binary = <<0xEF, 0xBB, 0xBF, "Matricule;Nom\n1;R", 0xE9, "serve\n">>

    assert {:ok, [row]} = Parser.parse(binary)
    assert row.national_id == "1"
    assert row.last_name == "Réserve"
  end

  test "a quoted field containing the delimiter doesn't shift later columns" do
    binary = ~s(Matricule;Nom;Club;Elo\n1;Dupont;"Cercle des Échecs, Namur";1600\n)

    assert {:ok, [row]} = Parser.parse(binary)
    assert row.national_id == "1"
    assert row.last_name == "Dupont"
    assert row.club_name == "Cercle des Échecs, Namur"
    assert row.national_rating == 1600
  end

  test "a doubled quote inside a quoted field unescapes to one literal quote" do
    binary = ~s(Matricule;Nom;Club\n1;Dupont;"Club ""Les Fous""\"\n)

    assert {:ok, [row]} = Parser.parse(binary)
    assert row.club_name == ~s(Club "Les Fous")
  end

  test "a quoted field is unwrapped even without a delimiter inside it" do
    binary = ~s(Matricule;Nom\n1;"Plain"\n)

    assert {:ok, [row]} = Parser.parse(binary)
    assert row.last_name == "Plain"
  end
end
