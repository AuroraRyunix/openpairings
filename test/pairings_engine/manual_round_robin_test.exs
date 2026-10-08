defmodule PairingsEngine.ManualRoundRobinTest do
  @moduledoc """
  A round-robin round paired by hand (VCL4THP Q100), held to its round of
  the Berger table at the end of the manual pairing alteration, with every
  pair meeting exactly once per cycle (Q101) and no three same colours in a
  row (Q102). The Pairings page's side is in
  `manual_round_robin_live_test.exs`.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{ManualPairing, ManualRoundRobin, Pairing, Repo, RoundRobin}
  alias PairingsEngine.{Tournaments, TrfExport}
  alias PairingsEngine.Tournaments.Tournament

  @moduletag :capture_log

  defp tournament(attrs \\ []) do
    Repo.insert!(
      struct(
        Tournament,
        Map.merge(
          %{
            name: "Hand-made round robin",
            type: "swiss",
            pairing_system: "round_robin",
            rr_cycles: 1,
            rounds_count: 9,
            tiebreaks: ~w(SB),
            round_dates: List.duplicate("2026-09-01", 10)
          },
          Map.new(attrs)
        )
      )
    )
  end

  # Players numbered 1..n by rating, as the table freezes them.
  defp players(t, n) do
    for i <- 1..n do
      {:ok, p} =
        Tournaments.create_player(t.id, %{
          tournament_id: t.id,
          name: "Player #{i}",
          fide_rating: 2400 - 10 * i
        })

      p
    end
  end

  # Round `number`, created empty and paired by hand: `boards` as
  # `{white, black}` players.
  defp hand_round!(t, boards) do
    {:ok, round} = RoundRobin.create_round_by_hand(Repo.reload!(t))
    {:ok, true} = ManualPairing.start(round, [])

    for {{w, b}, board} <- Enum.with_index(boards, 1) do
      {:ok, _} = Tournaments.pair_from_pool(round, w.id, b.id, board)
    end

    Tournaments.get_round(t.id, round.number)
  end

  defp kinds(warnings), do: Enum.map(warnings, & &1.kind)

  describe "a round paired by hand (Q100)" do
    test "is created empty, with the numbers frozen and the round count the table's" do
      t = tournament()
      [p1, p2, p3, p4] = players(t, 4)

      assert {:ok, round} = RoundRobin.create_round_by_hand(t)
      assert round.number == 1
      assert round.pairings == []
      assert Repo.reload!(t).rounds_count == 3

      assert Enum.map([p1, p2, p3, p4], &Repo.reload!(&1).pairing_number) == [1, 2, 3, 4]
      assert length(Tournaments.list_round_pool(t.id, 1)) == 4
    end

    test "only for a round robin the table can judge" do
      swiss = tournament(pairing_system: "swiss")
      players(swiss, 4)
      assert {:error, :not_by_hand} = RoundRobin.create_round_by_hand(swiss)

      match_format = tournament(rr_match_format: true)
      players(match_format, 4)
      assert {:error, :not_by_hand} = RoundRobin.create_round_by_hand(match_format)

      {team, _teams} =
        team_round_robin([{"A", [2000, 1990]}, {"B", [1980, 1970]}, {"C", [1960, 1950]}])

      refute RoundRobin.by_hand?(team)
      assert {:error, :not_by_hand} = RoundRobin.create_round_by_hand(team)
    end

    test "the table's own round, made by hand, matches and records nothing" do
      t = tournament()
      ps = players(t, 4)
      {:ok, table} = RoundRobin.schedule(4, 1, 1)

      boards = for {:pairing, w, b} <- table, do: {Enum.at(ps, w - 1), Enum.at(ps, b - 1)}
      round = hand_round!(t, boards)

      assert {:matches, %{warnings: []}} = ManualPairing.assess(Repo.reload!(t), round)
    end

    test "a round that is not the table's is a departure, written as a ### line" do
      t = tournament()
      [p1, p2, p3, p4] = players(t, 4)
      round = hand_round!(t, [{p1, p2}, {p3, p4}])

      assert {:differs, info} = ManualPairing.assess(Repo.reload!(t), round)
      assert Enum.sort(info.correct) == Enum.sort([{p1.id, p4.id}, {p2.id, p3.id}])
      assert info.warnings == []
      assert info.line == "MPA @ Round 1: 1-4 2-3 => 1-2 3-4"

      :ok = ManualPairing.finish(round, {:set, info.line})
      {:ok, trf} = TrfExport.export(Repo.reload!(t))
      assert trf =~ "### MPA @ Round 1: 1-4 2-3 => 1-2 3-4"
      {:ok, rating} = TrfExport.export(Repo.reload!(t), nil, for: :rating)
      refute rating =~ "###"
    end

    test "on an odd field the player left off the boards sits out with the zero-point bye" do
      t = tournament()
      [p1, p2, p3, p4, p5] = players(t, 5)
      round = hand_round!(t, [{p1, p2}, {p3, p4}])

      assert {kind, info} = ManualPairing.assess(Repo.reload!(t), round)
      assert kind in [:matches, :differs]
      assert info.warnings == []
      if kind == :differs, do: assert(info.line =~ "5=BYE")

      :ok = ManualPairing.finish(round, :keep)

      assert Repo.all(
               from b in "byes",
                 where: b.tournament_id == ^t.id and b.round == 1,
                 select: {b.player_id, b.type}
             ) == [{p5.id, "requested-zero"}]
    end

    test "the rest of the table is refused once it would pair a pair a second time" do
      t = tournament()
      [p1, p2, p3, p4] = players(t, 4)
      # The table's round 2 (1-3... or whatever it is) played as round 1.
      {:ok, table2} = RoundRobin.schedule(4, 1, 2)
      ps = [p1, p2, p3, p4]
      boards = for {:pairing, w, b} <- table2, do: {Enum.at(ps, w - 1), Enum.at(ps, b - 1)}
      round = hand_round!(t, boards)
      :ok = ManualPairing.finish(round, :keep)

      assert {:error, message} = RoundRobin.pair_all_rounds(Repo.reload!(t))
      assert message =~ "already met in round 1"
      assert Pairing.paired_rounds_count(t.id) == 1
    end
  end

  describe "everyone meets everyone once per cycle (Q101)" do
    test "a pair that already met in the cycle is a repeat" do
      t = tournament()
      [p1, p2, p3, p4] = players(t, 4)
      round1 = hand_round!(t, [{p1, p2}, {p3, p4}])
      :ok = ManualPairing.finish(round1, :keep)

      warnings = ManualRoundRobin.warnings(Repo.reload!(t), 2, [{p2.id, p1.id}])
      assert [%{kind: :rr_repeat, players: [_, _], round: 1}] = warnings
    end

    test "in a double round robin the second cycle meets them again, without a repeat" do
      t = tournament(rr_cycles: 2)
      [p1, p2, p3, p4] = players(t, 4)

      for boards <- [[{p1, p2}, {p3, p4}], [{p3, p1}, {p2, p4}], [{p1, p4}, {p2, p3}]] do
        round = hand_round!(t, boards)
        :ok = ManualPairing.finish(round, :keep)
      end

      warnings = ManualRoundRobin.warnings(Repo.reload!(t), 4, [{p2.id, p1.id}, {p4.id, p3.id}])
      refute :rr_repeat in kinds(warnings)
    end

    test "players left off an even field's round cannot meet everyone in the rounds left" do
      t = tournament()
      [p1, p2, p3, p4] = players(t, 4)
      round = hand_round!(t, [{p1, p2}])

      assert {:differs, info} = ManualPairing.assess(Repo.reload!(t), round)

      assert [%{kind: :rr_incomplete, players: players, cycle: 1}] = info.warnings
      assert Enum.sort(players) == Enum.sort([p3.id, p4.id])
    end

    test "rounds that leave two triangles to meet cannot be finished, though every count fits" do
      t = tournament()
      [p1, p2, p3, p4, p5, p6] = players(t, 6)

      # Every game between {1,2,3} and {4,5,6}: what is left is two
      # triangles, which no two rounds can pair.
      for boards <- [[{p1, p4}, {p2, p5}, {p3, p6}], [{p5, p1}, {p6, p2}, {p4, p3}]] do
        round = hand_round!(t, boards)
        :ok = ManualPairing.finish(round, :keep)
      end

      round3 = hand_round!(t, [{p1, p6}, {p2, p4}, {p3, p5}])
      assert {:differs, info} = ManualPairing.assess(Repo.reload!(t), round3)
      assert [%{kind: :rr_incomplete, players: [], cycle: 1}] = info.warnings
    end

    test "rounds that still leave a way through raise nothing" do
      t = tournament()
      [p1, p2, p3, p4, p5, p6] = players(t, 6)
      round1 = hand_round!(t, [{p1, p2}, {p3, p4}, {p5, p6}])
      :ok = ManualPairing.finish(round1, :keep)

      round2 = hand_round!(t, [{p1, p3}, {p2, p5}, {p4, p6}])
      assert {_kind, %{warnings: []}} = ManualPairing.assess(Repo.reload!(t), round2)
    end
  end

  describe "no three same colours in a row (Q102)" do
    test "a third White running is named" do
      t = tournament(rr_cycles: 2)
      [p1, p2, p3, p4] = players(t, 4)

      for boards <- [[{p1, p2}, {p3, p4}], [{p1, p3}, {p4, p2}]] do
        round = hand_round!(t, boards)
        :ok = ManualPairing.finish(round, :keep)
      end

      warnings = ManualRoundRobin.warnings(Repo.reload!(t), 3, [{p1.id, p4.id}, {p2.id, p3.id}])
      assert [%{kind: :rr_colour_three, players: [id], colour: "w"}] = warnings
      assert id == p1.id

      assert [] = ManualRoundRobin.warnings(Repo.reload!(t), 3, [{p4.id, p1.id}, {p2.id, p3.id}])
    end

    test "the table itself never gives one within a cycle" do
      # Every Berger round of a single round robin, 3 to 16 players, has no
      # player on the same colour three rounds running - so a warning on a
      # hand-made round is never the table's own doing.
      for n <- 3..16 do
        total = RoundRobin.total_rounds(n, 1)

        runs =
          for r <- 1..total, reduce: %{} do
            acc ->
              {:ok, entries} = RoundRobin.schedule(n, 1, r)

              for {:pairing, w, b} <- entries, reduce: acc do
                acc ->
                  acc
                  |> Map.update(w, %{r => :w}, &Map.put(&1, r, :w))
                  |> Map.update(b, %{r => :b}, &Map.put(&1, r, :b))
              end
          end

        for {_p, by_round} <- runs, r <- 1..max(total - 2, 1) do
          colours = Enum.map(r..(r + 2), &Map.get(by_round, &1))
          refute match?([c, c, c] when c != nil, colours)
        end
      end
    end
  end
end
