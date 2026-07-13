defmodule PairingsEngine.Tournaments.PlayerTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Tournaments.Player

  describe "parse_absent_rounds_input/1" do
    test "blank input normalizes to an empty string" do
      assert Player.parse_absent_rounds_input("") == {:ok, ""}
      assert Player.parse_absent_rounds_input("   ") == {:ok, ""}
    end

    test "a single round number" do
      assert Player.parse_absent_rounds_input("3") == {:ok, "3"}
    end

    test "comma-separated list, already canonical" do
      assert Player.parse_absent_rounds_input("1,3,5") == {:ok, "1,3,5"}
    end

    test "semicolon separator" do
      assert Player.parse_absent_rounds_input("1;3") == {:ok, "1,3"}
    end

    test "colon separator" do
      assert Player.parse_absent_rounds_input("4:5") == {:ok, "4,5"}
    end

    test "period separator (not read as a decimal point)" do
      assert Player.parse_absent_rounds_input("3.5") == {:ok, "3,5"}
    end

    test "whitespace is tolerated around and between tokens" do
      assert Player.parse_absent_rounds_input(" 1 , 3 ") == {:ok, "1,3"}
      assert Player.parse_absent_rounds_input("1 3") == {:ok, "1,3"}
    end

    test "a simple ascending range expands inclusively" do
      assert Player.parse_absent_rounds_input("2-4") == {:ok, "2,3,4"}
    end

    test "a reversed range still expands ascending" do
      assert Player.parse_absent_rounds_input("5-3") == {:ok, "3,4,5"}
    end

    test "a single-round range collapses to one number" do
      assert Player.parse_absent_rounds_input("4-4") == {:ok, "4"}
    end

    test "mixed separators and a range, per the spec example" do
      assert Player.parse_absent_rounds_input("2-4;1") == {:ok, "1,2,3,4"}
    end

    test "duplicates (including ones produced by overlapping ranges) are collapsed" do
      assert Player.parse_absent_rounds_input("1,1,2-3,3") == {:ok, "1,2,3"}
    end

    test "extra/doubled separators and trailing separators are ignored" do
      assert Player.parse_absent_rounds_input("1,,3,") == {:ok, "1,3"}
      assert Player.parse_absent_rounds_input(",1;;3::") == {:ok, "1,3"}
    end

    test "unparseable garbage is rejected" do
      assert Player.parse_absent_rounds_input("abc") == :error
      assert Player.parse_absent_rounds_input("3-") == :error
      assert Player.parse_absent_rounds_input("-3") == :error
      assert Player.parse_absent_rounds_input("3--4") == :error
      assert Player.parse_absent_rounds_input("1-2-3") == :error
      assert Player.parse_absent_rounds_input("1,two,3") == :error
    end

    test "a pathologically large range is rejected rather than expanded" do
      assert Player.parse_absent_rounds_input("1-999999999") == :error
    end
  end

  describe "changeset/2 absent_rounds normalization" do
    test "normalizes a forgiving grammar to canonical form before storage" do
      changeset = Player.changeset(%Player{}, %{"name" => "A", "absent_rounds" => "2-4;1"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :absent_rounds) == "1,2,3,4"
    end

    test "leaves absent_rounds untouched when not part of the attrs" do
      player = %Player{name: "A", absent_rounds: "1,2,3"}
      changeset = Player.changeset(player, %{"name" => "A renamed"})
      refute Ecto.Changeset.get_change(changeset, :absent_rounds)
      assert Ecto.Changeset.get_field(changeset, :absent_rounds) == "1,2,3"
    end

    test "rejects garbage with a friendly error instead of a bare format error" do
      changeset = Player.changeset(%Player{}, %{"name" => "A", "absent_rounds" => "not a round"})
      refute changeset.valid?
      assert {msg, _} = changeset.errors[:absent_rounds]
      assert msg =~ "round numbers or ranges"
    end
  end

  describe "changeset/2 fixed_board / special_table sync" do
    test "setting fixed_board via attrs marks special_table true" do
      changeset = Player.changeset(%Player{}, %{"name" => "A", "fixed_board" => "5"})
      assert Ecto.Changeset.get_field(changeset, :fixed_board) == 5
      assert Ecto.Changeset.get_field(changeset, :special_table) == true
    end

    test "blanking fixed_board via attrs marks special_table false" do
      player = %Player{name: "A", fixed_board: 5, special_table: true}
      changeset = Player.changeset(player, %{"name" => "A", "fixed_board" => ""})
      assert Ecto.Changeset.get_field(changeset, :fixed_board) == nil
      assert Ecto.Changeset.get_field(changeset, :special_table) == false
    end

    test "special_table set directly (e.g. by the SWAR importer) is left alone when fixed_board isn't in the attrs" do
      changeset = Player.changeset(%Player{}, %{"name" => "A", "special_table" => true})
      assert Ecto.Changeset.get_field(changeset, :special_table) == true
      assert Ecto.Changeset.get_field(changeset, :fixed_board) == nil
    end
  end
end
