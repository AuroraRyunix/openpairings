defmodule PairingsEngine.BoardStabilityTest do
  @moduledoc """
  Regression net for one class of bug, found the hard way in 0.14.6: a
  board's displayed number was derived from its position within a *filtered*
  collection, so changing one board's status silently renumbered every board
  after it — mid-round, with people already seated at them.

  The invariant these tests pin, stated once:

      Changing ANYTHING about one board must never change the number
      displayed next to a DIFFERENT board.

  Each test below does something to board 2 of a five-board round and
  asserts boards 1, 3, 4 and 5 kept their numbers.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{PairingDisplay, Repo}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  defp fixture do
    t =
      Repo.insert!(%Tournament{name: "Board Stability", type: "swiss", rounds_count: 3})

    players =
      for n <- 1..10 do
        Repo.insert!(%Player{tournament_id: t.id, name: "Player #{n}", fide_rating: 2000 - n})
      end

    round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "playing"})

    pairings =
      players
      |> Enum.chunk_every(2)
      |> Enum.with_index(1)
      |> Enum.map(fn {[w, b], board} ->
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: board,
          white_player_id: w.id,
          black_player_id: b.id,
          result: ""
        })
      end)

    {t, round, players, pairings}
  end

  # `%{real board => displayed label}` for the round as it currently stands.
  defp labels(round_id) do
    Repo.all(
      from p in Pairing,
        where: p.round_id == ^round_id,
        preload: [:white_player, :black_player]
    )
    |> PairingDisplay.with_display_boards()
    |> Map.new(fn %{pairing: p, board: label} -> {p.board, label} end)
  end

  defp untouched(before_labels, after_labels, changed_board) do
    for {board, label} <- before_labels, board != changed_board do
      assert Map.get(after_labels, board) == label,
             "board #{board} was renumbered from #{label} to " <>
               "#{inspect(Map.get(after_labels, board))} because board " <>
               "#{changed_board} changed — that is the 0.14.6 bug"
    end
  end

  describe "a board's number survives changes to another board" do
    test "baseline: five boards number 1..5" do
      {_t, round, _players, _pairings} = fixture()

      assert labels(round.id) == %{1 => "1", 2 => "2", 3 => "3", 4 => "4", 5 => "5"}
    end

    test "marking a player absent (vacating a seat) does not renumber" do
      {_t, round, _players, pairings} = fixture()
      before_labels = labels(round.id)

      # The original bug: this moved board 2 into the "vacant" bucket and
      # shifted boards 3-5 down one.
      pairings
      |> Enum.at(1)
      |> Ecto.Changeset.change(black_player_id: nil, result: "")
      |> Repo.update!()

      untouched(before_labels, labels(round.id), 2)
    end

    test "awarding a bye does not renumber" do
      {_t, round, _players, pairings} = fixture()
      before_labels = labels(round.id)

      pairings
      |> Enum.at(1)
      |> Ecto.Changeset.change(black_player_id: nil, result: "bye")
      |> Repo.update!()

      untouched(before_labels, labels(round.id), 2)
    end

    test "entering a result does not renumber" do
      {_t, round, _players, pairings} = fixture()
      before_labels = labels(round.id)

      pairings |> Enum.at(1) |> Ecto.Changeset.change(result: "1-0") |> Repo.update!()

      untouched(before_labels, labels(round.id), 2)
    end

    test "swapping the two players on a board does not renumber" do
      {_t, round, _players, pairings} = fixture()
      before_labels = labels(round.id)

      p = Enum.at(pairings, 1)

      p
      |> Ecto.Changeset.change(
        white_player_id: p.black_player_id,
        black_player_id: p.white_player_id
      )
      |> Repo.update!()

      untouched(before_labels, labels(round.id), 2)
    end

    test "a player's OWN fixed board is what relabels their board, not a neighbour's" do
      {_t, round, players, _pairings} = fixture()

      players |> Enum.at(2) |> Ecto.Changeset.change(fixed_board: 1001) |> Repo.update!()

      # The board whose player moved is relabelled — that much is the point
      # of the feature.
      assert labels(round.id)[2] == "1001"
    end

    @tag :known_gap
    test "KNOWN GAP: setting a fixed board mid-round DOES renumber later boards" do
      {_t, round, players, _pairings} = fixture()
      before_labels = labels(round.id)

      # This is the one surviving instance of the 0.14.6 class of bug, kept
      # here as an executable record rather than silently "fixed", because
      # the two goals genuinely conflict:
      #
      #   * A fixed-board player must not leave a hole in the ordinary
      #     sequence (the reason the feature exists) — which means the
      #     remaining boards close up.
      #   * A board's number must not move because another board changed
      #     (the reason 0.14.6 was a bug) — which means they must not.
      #
      # They only collide when `fixed_board` is set AFTER the round is
      # paired. Set before pairing — the normal case — closing the gap is
      # exactly right and nothing is live to disturb. Changing this is a
      # product call, not a refactor, so it is reported rather than assumed.
      players |> Enum.at(2) |> Ecto.Changeset.change(fixed_board: 1001) |> Repo.update!()

      after_labels = labels(round.id)

      assert before_labels[3] == "3"

      assert after_labels[3] == "2",
             "if this now says 3, the gap was closed differently — " <>
               "update this test and the note above"

      assert after_labels[4] == "3"
      assert after_labels[5] == "4"
      # Board 1 sits before the change and is unaffected either way.
      assert after_labels[1] == "1"
    end

    test "clearing a fixed board restores the ordinary numbering" do
      {_t, round, players, _pairings} = fixture()
      before_labels = labels(round.id)

      player = Enum.at(players, 2)
      player |> Ecto.Changeset.change(fixed_board: 1001) |> Repo.update!()

      # Reload: reusing the stale struct makes `change(fixed_board: nil)` a
      # no-op (nil -> nil), which silently turns this into a test of nothing.
      player |> Repo.reload!() |> Ecto.Changeset.change(fixed_board: nil) |> Repo.update!()

      assert labels(round.id) == before_labels
    end
  end

  describe "board_labels/1 (documents that keep their own row order)" do
    test "labels match with_display_boards/1 for the same round" do
      {_t, round, _players, _pairings} = fixture()

      rows =
        Repo.all(
          from p in Pairing,
            where: p.round_id == ^round.id,
            preload: [:white_player, :black_player]
        )

      ordered =
        rows |> PairingDisplay.with_display_boards() |> Map.new(&{&1.pairing.id, &1.board})

      in_place = rows |> PairingDisplay.board_labels() |> Map.new(&{&1.pairing.id, &1.board})

      # The two differ in ROW ORDER only; a given pairing must carry the same
      # label either way, or print and screen would disagree.
      assert ordered == in_place
    end
  end
end
