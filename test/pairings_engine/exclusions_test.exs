defmodule PairingsEngine.ExclusionsTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Exclusions
  alias PairingsEngine.Tournaments.{Player, Tournament}

  defp player(id, attrs) do
    struct(%Player{id: id, name: "P#{id}", club: "", federation: ""}, attrs)
  end

  defp tournament(attrs) do
    struct(
      %Tournament{club_exclusion: "none", club_exclusion_list: "", fed_exclusion: "none", fed_exclusion_list: ""},
      attrs
    )
  end

  defp pair_ids(pairs), do: MapSet.new(pairs, fn {a, b} -> {a.id, b.id} end)

  describe "excluded_pairs/2 — club_exclusion: \"none\"" do
    test "excludes nothing, even when players share a club" do
      players = [player(1, club: "Chess Club"), player(2, club: "Chess Club")]
      t = tournament(club_exclusion: "none")

      assert Exclusions.excluded_pairs(t, players) == MapSet.new()
    end
  end

  describe "excluded_pairs/2 — club_exclusion: \"all\"" do
    test "excludes every pair sharing a non-blank club" do
      a = player(1, club: "Chess Club")
      b = player(2, club: "Chess Club")
      c = player(3, club: "Other Club")

      t = tournament(club_exclusion: "all")

      assert pair_ids(Exclusions.excluded_pairs(t, [a, b, c])) == MapSet.new([{1, 2}])
    end

    test "a blank club is never grouped, even with another blank club" do
      a = player(1, club: "")
      b = player(2, club: "")

      t = tournament(club_exclusion: "all")

      assert Exclusions.excluded_pairs(t, [a, b]) == MapSet.new()
    end

    test "generates each unordered pair once for a club with more than two members" do
      players = for id <- 1..4, do: player(id, club: "Big Club")
      t = tournament(club_exclusion: "all")

      pairs = Exclusions.excluded_pairs(t, players)
      # C(4, 2) = 6 unordered pairs, none duplicated / reversed.
      assert MapSet.size(pairs) == 6
      assert pair_ids(pairs) == MapSet.new([{1, 2}, {1, 3}, {1, 4}, {2, 3}, {2, 4}, {3, 4}])
    end
  end

  describe "excluded_pairs/2 — club_exclusion: \"listed\"" do
    test "excludes only pairs whose shared club is in the list" do
      a = player(1, club: "Chess Club")
      b = player(2, club: "Chess Club")
      c = player(3, club: "Other Club")
      d = player(4, club: "Other Club")

      t = tournament(club_exclusion: "listed", club_exclusion_list: "Chess Club")

      assert pair_ids(Exclusions.excluded_pairs(t, [a, b, c, d])) == MapSet.new([{1, 2}])
    end

    test "list membership is trimmed and case-insensitive" do
      a = player(1, club: "chess club")
      b = player(2, club: "  Chess Club  ")

      t = tournament(club_exclusion: "listed", club_exclusion_list: " CHESS CLUB , Other")

      assert pair_ids(Exclusions.excluded_pairs(t, [a, b])) == MapSet.new([{1, 2}])
    end

    test "an empty list excludes nothing" do
      a = player(1, club: "Chess Club")
      b = player(2, club: "Chess Club")

      t = tournament(club_exclusion: "listed", club_exclusion_list: "")

      assert Exclusions.excluded_pairs(t, [a, b]) == MapSet.new()
    end
  end

  describe "excluded_pairs/2 — federation rules mirror club rules" do
    test "\"all\" excludes every pair sharing a non-blank federation" do
      a = player(1, federation: "BEL")
      b = player(2, federation: "BEL")
      c = player(3, federation: "NED")

      t = tournament(fed_exclusion: "all")

      assert pair_ids(Exclusions.excluded_pairs(t, [a, b, c])) == MapSet.new([{1, 2}])
    end

    test "\"listed\" restricts to the given federations" do
      a = player(1, federation: "BEL")
      b = player(2, federation: "BEL")
      c = player(3, federation: "NED")
      d = player(4, federation: "NED")

      t = tournament(fed_exclusion: "listed", fed_exclusion_list: "NED")

      assert pair_ids(Exclusions.excluded_pairs(t, [a, b, c, d])) == MapSet.new([{3, 4}])
    end

    test "a blank federation is never excluded" do
      a = player(1, federation: "")
      b = player(2, federation: "")

      t = tournament(fed_exclusion: "all")

      assert Exclusions.excluded_pairs(t, [a, b]) == MapSet.new()
    end
  end

  describe "excluded_pairs/2 — club and federation rules union" do
    test "a pair excluded by either rule appears once; a pair excluded by both is not duplicated" do
      # a & b share both a club and a federation; c shares only the federation with a & b.
      a = player(1, club: "Chess Club", federation: "BEL")
      b = player(2, club: "Chess Club", federation: "BEL")
      c = player(3, club: "Other Club", federation: "BEL")

      t = tournament(club_exclusion: "all", fed_exclusion: "all")

      pairs = Exclusions.excluded_pairs(t, [a, b, c])
      assert pair_ids(pairs) == MapSet.new([{1, 2}, {1, 3}, {2, 3}])
      assert MapSet.size(pairs) == 3
    end

    test "independent axes: a club-only rule ignores federation overlap" do
      a = player(1, club: "Chess Club", federation: "BEL")
      b = player(2, club: "Other Club", federation: "BEL")

      t = tournament(club_exclusion: "all", fed_exclusion: "none")

      assert Exclusions.excluded_pairs(t, [a, b]) == MapSet.new()
    end
  end

  describe "excluded_pairs/2 — pair ordering" do
    test "returned pairs are canonically ordered by ascending player id" do
      # Reverse insertion order (b before a by id) shouldn't affect the
      # returned pair's orientation.
      a = player(2, club: "Chess Club")
      b = player(1, club: "Chess Club")

      t = tournament(club_exclusion: "all")

      assert Exclusions.excluded_pairs(t, [a, b]) == MapSet.new([{b, a}])
    end
  end
end
