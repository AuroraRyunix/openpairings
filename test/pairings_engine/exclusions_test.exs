defmodule PairingsEngine.ExclusionsTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Exclusions
  alias PairingsEngine.Tournaments.{PairingRule, Player}

  defp player(id, attrs \\ []) do
    struct(%Player{id: id, name: "P#{id}", club: "", federation: ""}, attrs)
  end

  defp rule(attrs), do: struct(%PairingRule{kind: "club", window: "all", names: []}, attrs)

  defp pair_ids(pairs), do: MapSet.new(pairs, fn {a, b} -> {a.id, b.id} end)

  describe "groups and hard pairs" do
    test "a club rule keeps every pair sharing a non-blank club apart" do
      a = player(1, club: "Chess Club")
      b = player(2, club: "Chess Club")
      c = player(3, club: "Other Club")

      assert pair_ids(Exclusions.hard_pairs([rule(kind: "club")], [a, b, c], 1, 5)) ==
               MapSet.new([{1, 2}])
    end

    test "a blank club is never a group" do
      assert Exclusions.hard_pairs([rule(kind: "club")], [player(1), player(2)], 1, 5) ==
               MapSet.new()
    end

    test "clubs are compared trimmed and case-insensitively" do
      a = player(1, club: "Chess Club")
      b = player(2, club: "  chess club ")

      assert pair_ids(Exclusions.hard_pairs([rule(kind: "club")], [a, b], 1, 5)) ==
               MapSet.new([{1, 2}])
    end

    test "names limit a rule to the clubs or federations listed" do
      players = [
        player(1, federation: "BEL"),
        player(2, federation: "bel"),
        player(3, federation: "NED"),
        player(4, federation: "NED")
      ]

      r = rule(kind: "federation", names: ["BEL"])
      assert pair_ids(Exclusions.hard_pairs([r], players, 1, 5)) == MapSet.new([{1, 2}])
    end

    test "a club of four is six pairs, each once, and two rules naming one pair count it once" do
      players = for id <- 1..4, do: player(id, club: "Big", federation: "BEL")
      pairs = Exclusions.hard_pairs([rule(kind: "club"), rule(kind: "federation")], players, 1, 5)
      assert MapSet.size(pairs) == 6
    end

    test "a group rule keeps its own members apart, and only those still in the field" do
      r = rule(kind: "group", player_ids: [1, 2, 3, 99])
      players = [player(1), player(2), player(3), player(4)]

      assert pair_ids(Exclusions.hard_pairs([r], players, 1, 5)) ==
               MapSet.new([{1, 2}, {1, 3}, {2, 3}])

      assert Exclusions.groups(rule(kind: "group", player_ids: [1, 99]), players) == []
    end

    test "a player who joins later is covered by the rule as it stands" do
      r = rule(kind: "club")
      before = [player(1, club: "Rook"), player(2, club: "Knight")]
      assert Exclusions.hard_pairs([r], before, 3, 5) == MapSet.new()

      late = player(3, club: "Rook")
      assert pair_ids(Exclusions.hard_pairs([r], before ++ [late], 3, 5)) == MapSet.new([{1, 3}])
    end

    test "soft rules are wishes: never hard pairs, always soft groups" do
      players = [player(1, club: "Rook"), player(2, club: "Rook"), player(3, club: "Rook")]
      r = rule(kind: "club", soft: true)

      assert Exclusions.hard_pairs([r], players, 1, 5) == MapSet.new()
      assert Exclusions.soft_groups([r], players, 1, 5) == [[1, 2, 3]]
      assert Exclusions.soft_groups([rule(kind: "club")], players, 1, 5) == []
    end
  end

  describe "rounds" do
    test "first N, last N and a range hold in exactly their rounds" do
      first = rule(window: "first", window_rounds: 2)
      last = rule(window: "last", window_rounds: 2)
      range = rule(window: "range", window_from: 3, window_to: 4)

      held = fn r -> Enum.filter(1..7, &Exclusions.applies?(r, &1, 7)) end

      assert held.(first) == [1, 2]
      assert held.(last) == [6, 7]
      assert held.(range) == [3, 4]
      assert held.(rule([])) == Enum.to_list(1..7)
    end

    test "\"last N\" follows the number of rounds" do
      last = rule(window: "last", window_rounds: 2)
      assert Exclusions.rounds(last, 9) == {8, 9}
      assert Exclusions.rounds(last, 5) == {4, 5}
    end

    test "a rule added once rounds were paired never holds before its first round" do
      late = rule(from_round: 4)
      refute Exclusions.applies?(late, 3, 7)
      assert Exclusions.applies?(late, 4, 7)

      assert Exclusions.rounds(rule(window: "first", window_rounds: 2, from_round: 4), 7) == nil
    end

    test "hard pairs of a round take only the rules that hold in it" do
      players = [
        player(1, club: "Rook", federation: "BEL"),
        player(2, club: "Rook", federation: "BEL")
      ]

      r = rule(kind: "federation", window: "last", window_rounds: 1)

      assert Exclusions.hard_pairs([r], players, 4, 5) == MapSet.new()
      assert MapSet.size(Exclusions.hard_pairs([r], players, 5, 5)) == 1
      assert MapSet.size(Exclusions.hard_pairs([r], players, nil, 5)) == 1
    end
  end

  describe "effect and description" do
    test "counts pairs and the groups they come from" do
      players =
        [player(1, club: "A"), player(2, club: "A"), player(3, club: "A")] ++
          [player(4, club: "B"), player(5, club: "B"), player(6, club: "C")]

      assert Exclusions.effect(rule(kind: "club"), players) == %{pairs: 4, groups: 2}
    end

    test "describes a rule in plain ASCII for the TRF" do
      assert Exclusions.describe(rule(kind: "club")) == "same club"

      assert Exclusions.describe(
               rule(
                 kind: "federation",
                 soft: true,
                 names: ["BEL"],
                 window: "last",
                 window_rounds: 2
               )
             ) == "same federation (BEL), if possible, last 2 rounds"

      assert Exclusions.describe(rule(kind: "club", names: ["Échiquier"])) ==
               "same club (Echiquier)"
    end

    test "club_groups/1 groups a roster by club, groups of one left out" do
      players = [player(1, club: "Rook"), player(2, club: "rook"), player(3, club: "Solo")]
      assert [[%{id: 1}, %{id: 2}]] = Exclusions.club_groups(players)
      assert Exclusions.club_groups([]) == []
    end
  end
end
