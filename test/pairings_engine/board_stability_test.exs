defmodule PairingsEngine.BoardStabilityTest do
  @moduledoc """
  Regression net for two related instances of one bug class, both found the
  hard way in production: a board's displayed number was derived LIVE from
  something outside that board's own row, so changing something unrelated
  silently renumbered a board that nobody touched — mid-round, with people
  already seated at it.

    * 0.14.6: the number came from a board's POSITION within a filtered
      collection (bye/vacant/normal buckets) — fixed by numbering every
      non-special pairing in one pass, sorted by real board, regardless of
      bye/vacant/normal status. See the "survives changes to another
      board" tests below.

    * The narrower survivor: the SPECIAL/ordinary split itself was read
      LIVE from `Player.fixed_board` on every render, so giving a player a
      fixed (accessible) table *after* their round was already paired
      retroactively renumbered every board after theirs. Fixed by freezing
      `PairingDisplay.compute_labels/1`'s output onto
      `Pairing.display_board`/`display_special`, once, at the moment a
      round is (re-)paired — see `PairingsEngine.Tournaments.freeze_round_display_boards!/1`
      and `PairingsEngine.PairingDisplay`'s moduledoc. See the "frozen at
      pairing time" tests below.

  The invariant these tests pin, stated once:

      Changing ANYTHING about one board, or about a player who isn't
      currently seated at it, must never change the number displayed next
      to a board it doesn't touch — and once a round is paired, NOTHING
      short of re-pairing (or an explicit freeze) may change its numbers
      at all.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{PairingDisplay, Repo, Tournaments}
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

    # Every production call site freezes display labels immediately after
    # inserting a round's pairings (see Tournaments.freeze_round_display_boards!/1's
    # callers) — do the same here so the fixture matches reality instead of
    # leaving display_board nil, which no real round ever does.
    :ok = Tournaments.freeze_round_display_boards!(round.id)

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
  end

  describe "special/ordinary labels are frozen at pairing time, never live again" do
    test "fixed_board set BEFORE pairing is what the freeze picks up" do
      t = Repo.insert!(%Tournament{name: "Pre-set", type: "swiss", rounds_count: 3})

      players =
        for n <- 1..6 do
          Repo.insert!(%Player{tournament_id: t.id, name: "Player #{n}"})
        end

      players |> Enum.at(2) |> Ecto.Changeset.change(fixed_board: 1001) |> Repo.update!()

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

      :ok = Tournaments.freeze_round_display_boards!(round.id)

      result = labels(round.id)
      # Board 2 held the fixed_board player (players 3 & 4 → board 2) —
      # freezing at pairing time is exactly the normal, wanted case: no
      # hole left in the ordinary sequence.
      changed_board = Enum.at(pairings, 1).board
      assert result[changed_board] == "1001"
      assert result |> Map.values() |> Enum.sort() == ["1", "2", "1001"] |> Enum.sort()
    end

    test "setting a player's fixed_board AFTER the round is paired changes nothing" do
      {_t, round, players, _pairings} = fixture()
      before_labels = labels(round.id)

      # This is the bug this freeze exists to close: giving a player a
      # fixed (accessible) table after people are already seated must
      # never retroactively renumber their board, or any other board, in
      # an already-paired round.
      players |> Enum.at(2) |> Ecto.Changeset.change(fixed_board: 1001) |> Repo.update!()

      assert labels(round.id) == before_labels
    end

    test "clearing a player's fixed_board mid-round changes nothing either" do
      {_t, round, players, _pairings} = fixture()
      before_labels = labels(round.id)

      player = Enum.at(players, 2)
      player |> Ecto.Changeset.change(fixed_board: 1001) |> Repo.update!()
      player |> Repo.reload!() |> Ecto.Changeset.change(fixed_board: nil) |> Repo.update!()

      assert labels(round.id) == before_labels
    end

    test "re-pairing (a fresh round) reflects fixed_board as it stands at that later moment" do
      {t, _round1, players, _pairings} = fixture()

      players |> Enum.at(6) |> Ecto.Changeset.change(fixed_board: 42) |> Repo.update!()

      round2 = Repo.insert!(%Round{tournament_id: t.id, number: 2, status: "playing"})

      pairings2 =
        players
        |> Enum.chunk_every(2)
        |> Enum.with_index(1)
        |> Enum.map(fn {[w, b], board} ->
          Repo.insert!(%Pairing{
            round_id: round2.id,
            board: board,
            white_player_id: w.id,
            black_player_id: b.id,
            result: ""
          })
        end)

      :ok = Tournaments.freeze_round_display_boards!(round2.id)

      # Player 7 (index 6) is on board 4 of round 2 — freezing a NEW round
      # is exactly "when I click pair", so it correctly picks up the
      # fixed_board that was set in between round 1 and round 2.
      changed_board = Enum.at(pairings2, 3).board
      assert labels(round2.id)[changed_board] == "42"
    end

    test "an explicit re-freeze (not an automatic one) does pick up a later fixed_board change" do
      {_t, round, players, pairings} = fixture()

      # Player index 2 ("Player 3") sits on board 2 (players are chunked
      # [1,2]->board 1, [3,4]->board 2, ...).
      players |> Enum.at(2) |> Ecto.Changeset.change(fixed_board: 1001) |> Repo.update!()
      changed_board = Enum.at(pairings, 1).board
      assert labels(round.id)[changed_board] != "1001"

      # There is no automatic trigger for this — an arbiter would have to
      # explicitly unpair and re-pair the round. This test only confirms
      # freeze_round_display_boards!/1 itself is not stale logic: calling
      # it again does reflect current fixed_board state, it is simply never
      # called again automatically.
      :ok = Tournaments.freeze_round_display_boards!(round.id)
      assert labels(round.id)[changed_board] == "1001"
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
