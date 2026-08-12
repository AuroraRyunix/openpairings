defmodule PairingsEngine.PairingDisplayTest do
  @moduledoc """
  Pure, no-DB tests for `PairingsEngine.PairingDisplay` — the presentation
  layer that renumbers fixed-table ("special") boards to the end of the
  list, closing the gap in the ordinary sequence.

  Every test that checks *identity* (which player ends up on which row)
  compares actual struct references (`==` on the whole `%Pairing{}`, not
  just a re-derived board number) — the one thing that must never happen
  here is a real result getting attached to the wrong pairing because a
  display-only renumbering pass touched something it shouldn't have.
  Nothing in this module writes `pairing.board` — `with_display_boards/1`
  and `board_labels/1` only ever return a *separate* label alongside the
  untouched pairing, never mutate the struct.
  """
  use ExUnit.Case, async: true

  alias PairingsEngine.PairingDisplay
  alias PairingsEngine.Tournaments.{Pairing, Player}

  defp player(attrs), do: struct(%Player{name: "P"}, attrs)

  defp pairing(id, board, white, black) do
    %Pairing{id: id, board: board, white_player: white, black_player: black, result: ""}
  end

  describe "with_display_boards/1 — no fixed-table players at all" do
    test "boards are untouched, order unchanged" do
      a = player(id: 1, name: "Alice")
      b = player(id: 2, name: "Bob")
      c = player(id: 3, name: "Carol")
      d = player(id: 4, name: "Dave")

      p1 = pairing(101, 1, a, b)
      p2 = pairing(102, 2, c, d)

      result = PairingDisplay.with_display_boards([p1, p2])

      assert result == [
               %{pairing: p1, board: "1"},
               %{pairing: p2, board: "2"}
             ]
    end

    test "input order doesn't matter — output is sorted by real board number" do
      a = player(id: 1, name: "Alice")
      b = player(id: 2, name: "Bob")
      p1 = pairing(101, 1, a, b)
      p2 = pairing(102, 2, b, a)

      # Given out of board order...
      assert PairingDisplay.with_display_boards([p2, p1]) == [
               %{pairing: p1, board: "1"},
               %{pairing: p2, board: "2"}
             ]
    end
  end

  describe "with_display_boards/1 — one fixed-table player" do
    test "the ordinary boards close the gap; the special board moves to the end with its own label" do
      alice = player(id: 1, name: "Alice", fixed_board: 1001)
      bob = player(id: 2, name: "Bob")
      carol = player(id: 3, name: "Carol")
      dave = player(id: 4, name: "Dave")
      erin = player(id: 5, name: "Erin")
      frank = player(id: 6, name: "Frank")

      # Real engine boards: 1 (Alice/Bob, Alice is fixed_board 1001),
      # 2 (Carol/Dave), 3 (Erin/Frank).
      p_alice = pairing(101, 1, alice, bob)
      p_carol = pairing(102, 2, carol, dave)
      p_erin = pairing(103, 3, erin, frank)

      result = PairingDisplay.with_display_boards([p_alice, p_carol, p_erin])

      # Carol's board (real 2) becomes displayed board 1; Erin's (real 3)
      # becomes displayed board 2 — the gap real board 1 left is closed.
      # Alice's pairing is untouched (same struct, same id) and sorts last.
      assert result == [
               %{pairing: p_carol, board: "1"},
               %{pairing: p_erin, board: "2"},
               %{pairing: p_alice, board: "1001"}
             ]
    end

    test "matches the user's own worked example: real board 10 -> 1001, real board 11 -> displayed 10" do
      # Boards 1-9 present and ordinary, exactly as they'd be in a real
      # round — this is what makes "board 10 should still exist" a
      # meaningful claim rather than a trivial one-pairing renumbering.
      ordinary =
        for n <- 1..9 do
          pairing(
            100 + n,
            n,
            player(id: n * 10 + 1, name: "P#{n}A"),
            player(id: n * 10 + 2, name: "P#{n}B")
          )
        end

      fixed_player = player(id: 1, name: "Wheelchair", fixed_board: 1001)
      opp = player(id: 2, name: "Opp")
      shifted_player = player(id: 3, name: "Shifted")
      shifted_opp = player(id: 4, name: "ShiftedOpp")

      p_fixed = pairing(9999, 10, fixed_player, opp)
      p_shifted = pairing(10_000, 11, shifted_player, shifted_opp)

      result = PairingDisplay.with_display_boards(ordinary ++ [p_fixed, p_shifted])

      # Boards 1-9 keep their own numbers (nothing before them was pulled
      # out); board 11 becomes displayed board 10, taking over the exact
      # slot board 10 vacated; the fixed-table pairing lands at the end.
      assert Enum.map(result, &{&1.pairing.id, &1.board}) ==
               Enum.map(1..9, &{100 + &1, Integer.to_string(&1)}) ++
                 [{10_000, "10"}, {9999, "1001"}]
    end

    test "a bye pairing (no black player) with the fixed-table player doesn't crash" do
      alice = player(id: 1, name: "Alice", fixed_board: 1001)
      p_bye = pairing(101, 1, alice, nil)

      assert PairingDisplay.with_display_boards([p_bye]) == [%{pairing: p_bye, board: "1001"}]
    end
  end

  describe "with_display_boards/1 — multiple fixed-table players, not paired together" do
    test "special boards sort by their own fixed_board value, ascending, after every normal board" do
      a = player(id: 1, name: "A", fixed_board: 1002)
      b = player(id: 2, name: "B")
      c = player(id: 3, name: "C", fixed_board: 1001)
      d = player(id: 4, name: "D")
      e = player(id: 5, name: "E")
      f = player(id: 6, name: "F")

      p_a = pairing(101, 1, a, b)
      p_c = pairing(102, 2, c, d)
      p_normal = pairing(103, 3, e, f)

      result = PairingDisplay.with_display_boards([p_a, p_c, p_normal])

      assert [
               %{pairing: ^p_normal, board: "1"},
               %{pairing: ^p_c, board: "1001"},
               %{pairing: ^p_a, board: "1002"}
             ] = result
    end
  end

  describe "with_display_boards/1 — two fixed-table players paired against each other" do
    test "same fixed_board value on both sides: one row, one label, no duplication" do
      a = player(id: 1, name: "A", fixed_board: 1001)
      b = player(id: 2, name: "B", fixed_board: 1001)
      p = pairing(101, 1, a, b)

      assert PairingDisplay.with_display_boards([p]) == [%{pairing: p, board: "1001"}]
    end

    test "different fixed_board values on both sides: both shown, slash-joined, ascending" do
      a = player(id: 1, name: "A", fixed_board: 1002)
      b = player(id: 2, name: "B", fixed_board: 1001)
      p = pairing(101, 1, a, b)

      assert PairingDisplay.with_display_boards([p]) == [%{pairing: p, board: "1001/1002"}]
    end

    test "only one side of a fixed-table pairing has fixed_board set: uses that one value" do
      a = player(id: 1, name: "A", fixed_board: 1001)
      b = player(id: 2, name: "B")
      p = pairing(101, 1, a, b)

      assert PairingDisplay.with_display_boards([p]) == [%{pairing: p, board: "1001"}]
    end
  end

  describe "board_labels/1 — relabels without reordering" do
    test "keeps the input pairings' own order (e.g. already alphabetical), just fixes the label" do
      alice = player(id: 1, name: "Alice", fixed_board: 1001)
      bob = player(id: 2, name: "Bob")
      carol = player(id: 3, name: "Carol")
      dave = player(id: 4, name: "Dave")

      p_alice = pairing(101, 1, alice, bob)
      p_carol = pairing(102, 2, carol, dave)

      # Alphabetical-ish order, not board order — board_labels/1 must not
      # reorder these, only fix up the labels.
      result = PairingDisplay.board_labels([p_carol, p_alice])

      assert result == [
               %{pairing: p_carol, board: "1"},
               %{pairing: p_alice, board: "1001"}
             ]
    end
  end

  describe "special?/1" do
    test "true if either side has fixed_board set, false otherwise" do
      a = player(id: 1, fixed_board: 5)
      b = player(id: 2)

      assert PairingDisplay.special?(pairing(1, 1, a, b))
      assert PairingDisplay.special?(pairing(2, 1, b, a))
      refute PairingDisplay.special?(pairing(3, 1, b, b))
      refute PairingDisplay.special?(pairing(4, 1, b, nil))
    end
  end
end
