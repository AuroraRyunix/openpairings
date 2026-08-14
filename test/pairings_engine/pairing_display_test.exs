defmodule PairingsEngine.PairingDisplayTest do
  @moduledoc """
  Pure, no-DB tests for `PairingsEngine.PairingDisplay`.

  Split to match the module's own split:

    * `compute_labels/1` is the ONLY function that ever looks at
      `Player.fixed_board` — it's what
      `PairingsEngine.Tournaments.freeze_round_display_boards!/1` calls,
      once, at pairing time. All the "what should a fixed-table board be
      labelled/renumbered to" logic lives here now.
    * `with_display_boards/1` and `board_labels/1` never look at
      `fixed_board` at all anymore — they read the already-frozen
      `display_board`/`display_special` fields a pairing carries and only
      decide ROW ORDER (still live: bye/vacant status is fine to reflect
      immediately, see the module's moduledoc for why that's a different
      concern from the frozen NUMBER). Their tests below build pairings
      with `display_board`/`display_special` pre-set, standing in for
      "already frozen", and never set `fixed_board` on a player at all —
      if one of these functions started reading it again, these tests
      wouldn't catch it, but `compute_labels/1`'s tests below would still
      pin the correct content, and `board_stability_test.exs` pins that
      editing `fixed_board` after freezing has zero effect end-to-end.

  Every test that checks *identity* (which player ends up on which row)
  compares actual struct references (`==` on the whole `%Pairing{}`, not
  just a re-derived board number) — the one thing that must never happen
  here is a real result getting attached to the wrong pairing because a
  display-only renumbering pass touched something it shouldn't have.
  Nothing in this module writes `pairing.board` — every function here only
  ever returns a *separate* label alongside the untouched pairing, never
  mutates the struct.
  """
  use ExUnit.Case, async: true

  alias PairingsEngine.PairingDisplay
  alias PairingsEngine.Tournaments.{Pairing, Player}

  defp player(attrs), do: struct(%Player{name: "P"}, attrs)

  defp pairing(id, board, white, black), do: pairing(id, board, white, black, "")

  defp pairing(id, board, white, black, result) do
    %Pairing{id: id, board: board, white_player: white, black_player: black, result: result}
  end

  # A pairing already carrying frozen display fields, standing in for what
  # Tournaments.freeze_round_display_boards!/1 would have written — used by
  # the with_display_boards/1 and board_labels/1 tests below, which must
  # never need to know a player's fixed_board at all.
  defp frozen(id, board, white, black, result, display_board, display_special \\ false) do
    %Pairing{
      id: id,
      board: board,
      white_player: white,
      black_player: black,
      result: result,
      display_board: display_board,
      display_special: display_special
    }
  end

  describe "compute_labels/1 — no fixed-table players at all" do
    test "boards are numbered by real board order, none marked special" do
      a = player(id: 1, name: "Alice")
      b = player(id: 2, name: "Bob")
      c = player(id: 3, name: "Carol")
      d = player(id: 4, name: "Dave")

      p1 = pairing(101, 1, a, b)
      p2 = pairing(102, 2, c, d)

      assert PairingDisplay.compute_labels([p1, p2]) == %{
               101 => %{display_board: "1", display_special: false},
               102 => %{display_board: "2", display_special: false}
             }
    end

    test "input order doesn't matter — labels come from real board order" do
      a = player(id: 1, name: "Alice")
      b = player(id: 2, name: "Bob")
      p1 = pairing(101, 1, a, b)
      p2 = pairing(102, 2, b, a)

      assert PairingDisplay.compute_labels([p2, p1]) == %{
               101 => %{display_board: "1", display_special: false},
               102 => %{display_board: "2", display_special: false}
             }
    end
  end

  describe "compute_labels/1 — one fixed-table player" do
    test "the ordinary boards close the gap; the special board gets its own label" do
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

      # Carol's board (real 2) becomes displayed board 1; Erin's (real 3)
      # becomes displayed board 2 — the gap real board 1 left is closed.
      assert PairingDisplay.compute_labels([p_alice, p_carol, p_erin]) == %{
               101 => %{display_board: "1001", display_special: true},
               102 => %{display_board: "1", display_special: false},
               103 => %{display_board: "2", display_special: false}
             }
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

      labels = PairingDisplay.compute_labels(ordinary ++ [p_fixed, p_shifted])

      # Boards 1-9 keep their own numbers (nothing before them was pulled
      # out); board 11 becomes displayed board 10, taking over the exact
      # slot board 10 vacated; the fixed-table pairing gets its own label.
      expected =
        Map.new(
          1..9,
          &{100 + &1, %{display_board: Integer.to_string(&1), display_special: false}}
        )
        |> Map.put(10_000, %{display_board: "10", display_special: false})
        |> Map.put(9999, %{display_board: "1001", display_special: true})

      assert labels == expected
    end

    test "a bye pairing (no black player) with the fixed-table player doesn't crash" do
      alice = player(id: 1, name: "Alice", fixed_board: 1001)
      p_bye = pairing(101, 1, alice, nil, "bye")

      assert PairingDisplay.compute_labels([p_bye]) == %{
               101 => %{display_board: "1001", display_special: true}
             }
    end
  end

  describe "compute_labels/1 — multiple fixed-table players, not paired together" do
    test "each special board gets its own fixed_board-derived label" do
      a = player(id: 1, name: "A", fixed_board: 1002)
      b = player(id: 2, name: "B")
      c = player(id: 3, name: "C", fixed_board: 1001)
      d = player(id: 4, name: "D")
      e = player(id: 5, name: "E")
      f = player(id: 6, name: "F")

      p_a = pairing(101, 1, a, b)
      p_c = pairing(102, 2, c, d)
      p_normal = pairing(103, 3, e, f)

      assert PairingDisplay.compute_labels([p_a, p_c, p_normal]) == %{
               101 => %{display_board: "1002", display_special: true},
               102 => %{display_board: "1001", display_special: true},
               103 => %{display_board: "1", display_special: false}
             }
    end
  end

  describe "compute_labels/1 — two fixed-table players paired against each other" do
    test "same fixed_board value on both sides: one label, no duplication" do
      a = player(id: 1, name: "A", fixed_board: 1001)
      b = player(id: 2, name: "B", fixed_board: 1001)
      p = pairing(101, 1, a, b)

      assert PairingDisplay.compute_labels([p]) == %{
               101 => %{display_board: "1001", display_special: true}
             }
    end

    test "different fixed_board values on both sides: both shown, slash-joined, ascending" do
      a = player(id: 1, name: "A", fixed_board: 1002)
      b = player(id: 2, name: "B", fixed_board: 1001)
      p = pairing(101, 1, a, b)

      assert PairingDisplay.compute_labels([p]) == %{
               101 => %{display_board: "1001/1002", display_special: true}
             }
    end

    test "only one side of a fixed-table pairing has fixed_board set: uses that one value" do
      a = player(id: 1, name: "A", fixed_board: 1001)
      b = player(id: 2, name: "B")
      p = pairing(101, 1, a, b)

      assert PairingDisplay.compute_labels([p]) == %{
               101 => %{display_board: "1001", display_special: true}
             }
    end
  end

  describe "with_display_boards/1 — row order over already-frozen labels" do
    test "labels are read straight from the frozen fields, order unchanged for plain boards" do
      p1 = frozen(101, 1, player(id: 1), player(id: 2), "", "1")
      p2 = frozen(102, 2, player(id: 3), player(id: 4), "", "2")

      assert PairingDisplay.with_display_boards([p2, p1]) == [
               %{pairing: p1, board: "1"},
               %{pairing: p2, board: "2"}
             ]
    end

    test "normal boards first, then byes, then vacant seats, then special — each keeping its own frozen label" do
      p_normal = frozen(101, 1, player(id: 1), player(id: 2), "", "1")
      p_bye = frozen(102, 3, player(id: 3), nil, "bye", "3")
      p_vacant = frozen(103, 2, player(id: 4), nil, "", "2")
      p_special = frozen(104, 4, player(id: 5), player(id: 6), "", "1001", true)

      result = PairingDisplay.with_display_boards([p_special, p_vacant, p_bye, p_normal])

      # Row ORDER groups by current bye/vacant/special status (fine to be
      # live — reordering doesn't renumber anyone), but every label is the
      # frozen one, untouched.
      assert [
               %{pairing: ^p_normal, board: "1"},
               %{pairing: ^p_bye, board: "3"},
               %{pairing: ^p_vacant, board: "2"},
               %{pairing: ^p_special, board: "1001"}
             ] = result
    end

    test "multiple special boards sort by real board, keeping their own frozen labels" do
      p_a = frozen(101, 1, player(id: 1), player(id: 2), "", "1002", true)
      p_c = frozen(102, 2, player(id: 3), player(id: 4), "", "1001", true)
      p_normal = frozen(103, 3, player(id: 5), player(id: 6), "", "1")

      result = PairingDisplay.with_display_boards([p_a, p_c, p_normal])

      assert [
               %{pairing: ^p_normal, board: "1"},
               %{pairing: ^p_a, board: "1002"},
               %{pairing: ^p_c, board: "1001"}
             ] = result
    end
  end

  describe "board_labels/1 — relabels without reordering" do
    test "keeps the input pairings' own order, reading each frozen label as-is" do
      p_alice = frozen(101, 1, player(id: 1), player(id: 2), "", "1001", true)
      p_carol = frozen(102, 2, player(id: 3), player(id: 4), "", "1")

      # Alphabetical-ish order, not board order — board_labels/1 must not
      # reorder these, only report the label.
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
