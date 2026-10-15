defmodule PairingsEngine.PostponedRethinkTest do
  @moduledoc """
  Overdue boards and the settled-round bound (`docs/postponed-rethink.md`):
  a round-robin blank that a later complete round has moved past counts as
  an unnamed postponed game wherever standings are shown, instead of
  holding the public standings at the round before it for a season.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{PostponedGames, Repo, Snapshot, SnapshotFixtures, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  # Four players, three rounds (C.05 Annex 1): rows are {white, black, result}.
  defp round_robin(schedule, attrs \\ %{}) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Map.merge(
            %{
              name: "Club round robin",
              type: "roundrobin",
              pairing_system: "round_robin",
              rounds_count: length(schedule),
              tiebreaks: ~w(SB),
              publish_mode: "manual"
            },
            attrs
          )
        )
      )

    p =
      for no <- 1..4, into: %{} do
        {no,
         Repo.insert!(%Player{
           tournament_id: t.id,
           pairing_number: no,
           name: "Player #{no}",
           fide_rating: 2000 - no * 10
         })}
      end

    for {games, number} <- Enum.with_index(schedule, 1) do
      round =
        Repo.insert!(%Round{
          tournament_id: t.id,
          number: number,
          status: "finished",
          published_at: ~U[2026-09-01 18:00:00Z],
          results_public: true
        })

      for {{w, b, result}, board} <- Enum.with_index(games, 1) do
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: board,
          white_player_id: p[w] && p[w].id,
          black_player_id: p[b] && p[b].id,
          result: result
        })
      end
    end

    {Repo.reload!(t), p}
  end

  # Round 1 has one unentered board (1-4); rounds 2 and 3 as given.
  defp season(round2, round3, attrs \\ %{}) do
    round_robin(
      [
        [{1, 4, ""}, {2, 3, "1-0"}],
        round2,
        round3
      ],
      attrs
    )
  end

  @complete2 [{4, 3, "0-1"}, {1, 2, "1/2-1/2"}]
  @complete3 [{2, 4, "1-0"}, {3, 1, "0-1"}]

  describe "overdue_blanks/1" do
    test "a blank in a round older than a complete round is overdue" do
      {t, p} = season(@complete2, [{2, 4, ""}, {3, 1, ""}])

      assert [%{round: 1, pairing: pairing}] = PostponedGames.overdue_blanks(t)
      assert {pairing.white_player_id, pairing.black_player_id} == {p[1].id, p[4].id}
    end

    test "a later round with only some results does not make it overdue" do
      # A game played early, typed in before the round's evening.
      {t, _p} = season([{4, 3, "0-1"}, {1, 2, ""}], [{2, 4, ""}, {3, 1, ""}])

      assert PostponedGames.overdue_blanks(t) == []
    end

    test "the blanks of the latest complete round and after are never overdue" do
      {t, _p} = season(@complete2, [{2, 4, "1-0"}, {3, 1, ""}])

      assert [%{round: 1}] = PostponedGames.overdue_blanks(t)
    end

    test "a postponed game in the later round still makes that round complete" do
      {t, _p} = season([{4, 3, "*W"}, {1, 2, "1/2-1/2"}], [{2, 4, ""}, {3, 1, ""}])

      assert [%{round: 1}] = PostponedGames.overdue_blanks(t)
    end

    test "a Swiss never has overdue boards" do
      {t, _p} = season(@complete2, @complete3, %{pairing_system: "swiss", type: "swiss"})

      assert PostponedGames.overdue_blanks(t) == []
    end
  end

  describe "the standings bound" do
    test "a round whose only blank is overdue is settled, and the bound goes through it" do
      {t, _p} = season(@complete2, [{2, 4, ""}, {3, 1, ""}])

      assert Tournaments.round_settled?(t, 1)
      assert Tournaments.round_settled?(t, 2)
      refute Tournaments.round_settled?(t, 3)
      assert Tournaments.standings_through_round(t) == 2
      assert Tournaments.effective_standings_through(t) == 2
    end

    test "before a later round is complete the bound holds, as it always did" do
      {t, _p} = season([{4, 3, "0-1"}, {1, 2, ""}], [{2, 4, ""}, {3, 1, ""}])

      refute Tournaments.round_settled?(t, 1)
      assert Tournaments.standings_through_round(t) == 0
    end

    test "a vacated seat with no result still unsettles its round" do
      {t, _p} =
        round_robin([
          [{1, 4, ""}, {2, nil, ""}],
          @complete2
        ])

      refute Tournaments.round_settled?(t, 1)
      assert Tournaments.standings_through_round(t) == 0
    end

    test "the arbiter can publish standings through a settled round" do
      {t, _p} = season(@complete2, [{2, 4, ""}, {3, 1, ""}])

      assert {:ok, _} = Tournaments.publish_standings_through(t, 2)
      assert {:error, :round_not_complete} = Tournaments.publish_standings_through(t, 3)
    end

    test "the same data in a Swiss keeps the old bound" do
      {t, _p} = season(@complete2, @complete3, %{pairing_system: "swiss", type: "swiss"})

      refute Tournaments.round_settled?(t, 1)
      assert Tournaments.standings_through_round(t) == 0
    end
  end

  describe "what a pending game counts as" do
    test "pending: true counts an overdue board as a draw for both by default" do
      {t, p} = season(@complete2, @complete3)

      plain = points(Standings.standings(t))
      pending = points(Standings.standings(t, pending: true))

      assert plain[p[1].id] == 1.5 and plain[p[4].id] == 0.0
      assert pending[p[1].id] == 2.0 and pending[p[4].id] == 0.5
    end

    test "the record is flagged postponed, so nothing takes it for a finished game" do
      {t, p} = season(@complete2, @complete3)

      entry = t |> Standings.standings(pending: true) |> Enum.find(&(&1.player.id == p[4].id))

      assert [%{round: 1, postponed: true, outcome: :draw}] =
               Enum.filter(entry.games, &(&1.round == 1))
    end

    test "the postponed setting's value for the opponent is what both seats get" do
      {t, p} = season(@complete2, @complete3, %{postponed_opponent_outcome: "loss"})

      pending = points(Standings.standings(t, pending: true))
      assert pending[p[1].id] == 1.5 and pending[p[4].id] == 0.0
    end

    test "Sonneborn-Berger counts it as the draw the score counts" do
      {t, p} = season(@complete2, @complete3)

      sb = fn entries, id -> Enum.find(entries, &(&1.player.id == id)).tiebreaks["SB"] end
      pending = Standings.standings(t, pending: true)
      four = Enum.find(pending, &(&1.player.id == p[4].id)).points

      # Player 1 drew 2 and beat 3: SB = half of 2's score + 3's score + half of 4's.
      two = Enum.find(pending, &(&1.player.id == p[2].id)).points
      three = Enum.find(pending, &(&1.player.id == p[3].id)).points
      assert sb.(pending, p[1].id) == two / 2 + three + four / 2
    end
  end

  describe "postponed results in a round robin" do
    test "are allowed without the tick" do
      {t, _p} = season(@complete2, [{2, 4, ""}, {3, 1, ""}])
      refute t.postponed_games
      assert Tournament.postponed_allowed?(t)

      board = Repo.one!(from p in Pairing, where: p.result == "", limit: 1)
      assert {:ok, %Pairing{result: "*W"}} = Tournaments.update_pairing_result(board, "*W")
    end

    test "a Swiss still needs it" do
      refute Tournament.postponed_allowed?(%Tournament{pairing_system: "swiss"})

      assert Tournament.postponed_allowed?(%Tournament{
               pairing_system: "swiss",
               postponed_games: true
             })
    end
  end

  describe "the snapshot" do
    test "standings go through the latest settled round, provisional, with the count" do
      t = SnapshotFixtures.round_robin_pending_tournament()
      snapshot = Snapshot.build(t)
      standings = snapshot["standings"]

      assert standings["after_round"] == 4
      assert standings["provisional"] == true
      assert standings["pending_games"] == 2
      assert standings["postponed_games"] == 1
    end

    test "the overdue board is marked pending, with points, and is not called postponed" do
      snapshot = Snapshot.build(SnapshotFixtures.round_robin_pending_tournament())
      board = snapshot |> board_at(2, 3)

      assert board["pending"] == true
      assert board["result"] == nil
      refute Map.has_key?(board, "postponed")
      assert board["points"] == %{"white" => 0.5, "black" => 0.5}
      assert board["postponed_as"] == %{"white" => "draw", "black" => "draw"}
    end

    test "the blanks of the round being played are not pending" do
      snapshot = Snapshot.build(SnapshotFixtures.round_robin_pending_tournament())

      for board <- [2, 3] do
        row = board_at(snapshot, 5, board)
        assert row["result"] == nil
        refute Map.has_key?(row, "pending")
        refute Map.has_key?(row, "points")
      end
    end

    test "the standings rows add up with the pending board counted" do
      snapshot = Snapshot.build(SnapshotFixtures.round_robin_pending_tournament())
      # Player 1: 1-0, pending (½), 0-1 won by 1 (1), 1-0 = 3.5; player 2:
      # 1-0, pending (½), postponed (½), 1-0 = 3.0.
      points = Map.new(snapshot["standings"]["rows"], &{&1["player"], &1["points"]})
      assert points[1] == 3.5
      assert points[2] == 3.0
    end

    test "with nothing pending, no new key travels" do
      {t, _p} = round_robin([@complete2, @complete3])
      standings = Snapshot.build(t)["standings"]

      refute Map.has_key?(standings, "provisional")
      refute Map.has_key?(standings, "pending_games")
      refute Map.has_key?(standings, "postponed_games")
    end
  end

  defp points(entries), do: Map.new(entries, &{&1.player.id, &1.points})

  defp board_at(snapshot, round, board) do
    snapshot["rounds"]
    |> Enum.find(&(&1["number"] == round))
    |> Map.fetch!("boards")
    |> Enum.find(&(&1["board"] == board))
  end
end
