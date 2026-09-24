defmodule PairingsEngine.TeamStandingsTest do
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Repo, Standings, TeamStandings, Tiebreaks, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  # Four teams, two boards, the Berger table for N=4:
  #   R1: T1-T4, T2-T3   R2: T4-T3, T1-T2   R3: T2-T4, T3-T1
  # (the first team named has White on board 1, Black on board 2).
  #
  # The results below, match by match, from the first team's side:
  #   R1  T1 2-0 T4    T2 1-1 T3
  #   R2  T4 ½-1½ T3   T1 1-1 T2
  #   R3  T2 2-0 T4    T3 1½-½ T1
  #
  # Worked by hand, match points 2/1/0:
  #
  #   team  MP  GP   BH (opp MP)   SB (opp MP x MP)    EMGSB (opp MP x GP)    BB (board 1 x2, board 2 x1)
  #   T1    3   3.5  0+4+5 = 9     0x2+4x1+5x0 = 4     0x2+4x1+5x½ = 6.5      R1 2+1, R2 1, R3 ½x2 = 5
  #   T2    4   4    5+3+0 = 8     5x1+3x1+0x2 = 8     5x1+3x1+0x2 = 8        R1 2, R2 2, R3 2+1 = 7
  #   T3    5   4    4+0+3 = 7     4x1+0x2+3x2 = 10    4x1+0x1½+3x1½ = 8.5    R1 1, R2 1+1, R3 1+1 = 5
  #   T4    0   ½    3+5+4 = 12    0                   3x0+5x½+4x0 = 2.5      R2 ½x2 = 1
  defp worked_example(opts \\ []) do
    {t, _} =
      team_round_robin(
        [{"T1", [2100, 2000]}, {"T2", [2050, 1950]}, {"T3", [2000, 1900]}, {"T4", [1950, 1850]}],
        opts
      )

    t = pair_all!(t)

    # R1 T1-T4: T1 wins board 1 as White and board 2 as Black.
    enter!(t, 1, "T1", "T4", ["1-0", "0-1"])
    # R1 T2-T3: T2 wins board 1, T3 wins board 2 as White.
    enter!(t, 1, "T2", "T3", ["1-0", "1-0"])
    # R2 T4-T3: board 1 drawn, T3 wins board 2 as White.
    enter!(t, 2, "T4", "T3", ["1/2-1/2", "1-0"])
    # R2 T1-T2: T2 wins board 1 as Black, T1 wins board 2 as Black.
    enter!(t, 2, "T1", "T2", ["0-1", "0-1"])
    # R3 T2-T4: T2 wins both.
    enter!(t, 3, "T2", "T4", ["1-0", "0-1"])
    # R3 T3-T1: board 1 drawn, T3 wins board 2 as Black.
    enter!(t, 3, "T3", "T1", ["1/2-1/2", "0-1"])

    Repo.reload!(t)
  end

  defp by_name(entries), do: Map.new(entries, &{&1.team.name, &1})

  describe "match points and game points (C.07 Art. 11.1)" do
    test "the worked example's scores and ranking" do
      t = worked_example(tiebreaks: ~w(GP BH SB EMGSB BB))
      entries = TeamStandings.standings(t)
      e = by_name(entries)

      assert Enum.map(entries, & &1.team.name) == ["T3", "T2", "T1", "T4"]
      assert {e["T1"].mp, e["T2"].mp, e["T3"].mp, e["T4"].mp} == {3.0, 4.0, 5.0, 0.0}
      assert {e["T1"].gp, e["T2"].gp, e["T3"].gp, e["T4"].gp} == {3.5, 4.0, 4.0, 0.5}
      assert {e["T3"].won, e["T3"].drawn, e["T3"].lost} == {2, 1, 0}
      assert e["T4"].played == 3
    end

    test "match points follow the configured values" do
      t = worked_example()

      {:ok, t} =
        Tournaments.update_tournament(t, %{team_match_points_win: 3, team_match_points_draw: 1})

      e = t |> TeamStandings.standings() |> by_name()

      # T1: win, draw, loss. T3: draw, win, win.
      assert e["T1"].mp == 4.0
      assert e["T3"].mp == 7.0
    end

    test "match_points/3 decides by game points" do
      t = %Tournament{
        team_match_points_win: 2.0,
        team_match_points_draw: 1.0,
        team_match_points_loss: 0.0
      }

      assert TeamStandings.match_points(t, 2.5, 1.5) == {2.0, 0.0}
      assert TeamStandings.match_points(t, 1.5, 2.5) == {0.0, 2.0}
      assert TeamStandings.match_points(t, 2.0, 2.0) == {1.0, 1.0}
    end

    test "an unfinished match counts its game points but no match points" do
      {t, _} = team_round_robin([{"A", [2000, 1900]}, {"B", [1950, 1850]}])
      t = pair_all!(t)

      {_match, [b1, _b2]} = match_between(t, 1, "A", "B")
      {:ok, _} = Tournaments.update_pairing_result(b1, "1-0")

      e = t |> TeamStandings.standings() |> by_name()
      assert {e["A"].gp, e["A"].mp, e["A"].played} == {1.0, 0.0, 0}

      [m] = TeamStandings.matches(t)
      refute m.complete?
      assert m.mp_a == nil
    end

    test "a forfeit win on an empty board counts for the team that was there" do
      {t, _} = team_round_robin([{"Full", [2000, 1900]}, {"Short", [1950]}])
      t = pair_all!(t)

      {_match, [b1, b2]} = match_between(t, 1, "Full", "Short")
      assert b2.result == "0-1FF"
      {:ok, _} = Tournaments.update_pairing_result(b1, "0-1")

      [m] = TeamStandings.matches(t)
      assert {m.gp_a, m.gp_b, m.mp_a, m.mp_b} == {1.0, 1.0, 1.0, 1.0}
    end

    test "the bye of an odd round robin scores nothing" do
      {t, _} = team_round_robin([{"A", [2000]}, {"B", [1900]}, {"C", [1800]}], boards: 1)
      t = pair_all!(t)

      for m <- TeamStandings.matches(t), not m.bye? do
        [b] = m.boards
        {:ok, _} = Tournaments.update_pairing_result(b.pairing, "1/2-1/2")
      end

      for e <- TeamStandings.standings(t) do
        assert e.played == 2
        assert e.mp == 2.0
        assert e.gp == 1.0
      end
    end
  end

  describe "team tie-breaks, hand-computed" do
    # A round robin: Buchholz is not used (C.07 Article 8) - dropped, with
    # the reason the page gives.
    test "SB, EMGSB and BB; no Buchholz in a round robin" do
      t = worked_example(tiebreaks: ~w(GP BH SB EMGSB BB))
      e = t |> TeamStandings.standings() |> by_name()

      assert TeamStandings.dropped_tiebreaks_with_reasons(t) == [{"BH", :round_robin}]
      refute Map.has_key?(e["T1"].tiebreaks, "BH")

      assert Map.take(e["T1"].tiebreaks, ~w(SB EMGSB BB)) ==
               %{"SB" => 4.0, "EMGSB" => 6.5, "BB" => 5.0}

      assert Map.take(e["T2"].tiebreaks, ~w(SB EMGSB BB)) ==
               %{"SB" => 8.0, "EMGSB" => 8.0, "BB" => 7.0}

      assert Map.take(e["T3"].tiebreaks, ~w(SB EMGSB BB)) ==
               %{"SB" => 10.0, "EMGSB" => 8.5, "BB" => 5.0}

      assert Map.take(e["T4"].tiebreaks, ~w(SB EMGSB BB)) ==
               %{"SB" => 0.0, "EMGSB" => 2.5, "BB" => 1.0}

      assert e["T2"].tiebreaks["GP"] == 4.0
    end

    test "the working adds up to the number" do
      t = worked_example(tiebreaks: ~w(SB EMGSB))
      e = t |> TeamStandings.standings() |> by_name()

      for {_name, entry} <- e, code <- ~w(SB EMGSB) do
        parts = entry.working[code]
        assert length(parts) == 3
        assert parts |> Enum.map(& &1.value) |> Enum.sum() == entry.tiebreaks[code]
      end

      t3_sb = e["T3"].working["SB"] |> Enum.map(&{&1.round, &1.value})
      assert t3_sb == [{1, 4.0}, {2, 0.0}, {3, 6.0}]
    end

    # T1 and T2 end on 4 match points each; T2 beat T1 in round 2.
    #   R1  T1 2-0 T4    T2 2-0 T3
    #   R2  T4 1-1 T3    T1 0-2 T2
    #   R3  T2 0-2 T4    T3 0-2 T1
    defp tied_example(tiebreaks) do
      {t, _} =
        team_round_robin(
          [
            {"T1", [2100, 2000]},
            {"T2", [2050, 1950]},
            {"T3", [2000, 1900]},
            {"T4", [1950, 1850]}
          ],
          tiebreaks: tiebreaks
        )

      t = pair_all!(t)
      enter!(t, 1, "T1", "T4", ["1-0", "0-1"])
      enter!(t, 1, "T2", "T3", ["1-0", "0-1"])
      enter!(t, 2, "T4", "T3", ["1-0", "1-0"])
      enter!(t, 2, "T1", "T2", ["0-1", "1-0"])
      enter!(t, 3, "T2", "T4", ["0-1", "1-0"])
      enter!(t, 3, "T3", "T1", ["0-1", "1-0"])
      Repo.reload!(t)
    end

    test "DE: the team that won the direct match ranks first" do
      without = tied_example([]) |> TeamStandings.standings()

      assert without |> Enum.take(2) |> Enum.map(&{&1.team.name, &1.mp}) == [
               {"T1", 4.0},
               {"T2", 4.0}
             ]

      with_de = tied_example(["DE"]) |> TeamStandings.standings()
      assert with_de |> Enum.take(2) |> Enum.map(& &1.team.name) == ["T2", "T1"]

      e = by_name(with_de)
      assert {e["T2"].tiebreaks["DE"], e["T1"].tiebreaks["DE"]} == {2.0, 0.0}
      # T3 and T4 are not tied with anyone.
      assert {e["T3"].tiebreaks["DE"], e["T4"].tiebreaks["DE"]} == {0.0, 0.0}
    end

    test "DE only looks at teams still tied after the tie-breaks listed before it" do
      # GP: T1 4, T2 4 - still tied, so DE still decides.
      assert tied_example(~w(GP DE))
             |> TeamStandings.standings()
             |> Enum.take(2)
             |> Enum.map(& &1.team.name) == ["T2", "T1"]
    end

    # T1, T2 and T3 all end on 4 match points in a cycle - T2 beat T1, T1
    # beat T3, T3 beat T2 - and each beat T4. Game points split them:
    #   R1  T1 1½-½ T4   T2 0-2 T3
    #   R2  T4 0-2 T3    T1 ½-1½ T2
    #   R3  T2 2-0 T4    T3 ½-1½ T1
    #   GP: T1 3.5, T2 3.5, T3 4.5
    # With GP listed before DE, T3 is already separated, so DE is decided
    # between T1 and T2 alone: T2 won. Over all three MP-tied teams, DE would
    # give each of them 2 and decide nothing.
    test "DE after GP excludes the team GP already separated" do
      {t, _} =
        team_round_robin(
          [
            {"T1", [2100, 2000]},
            {"T2", [2050, 1950]},
            {"T3", [2000, 1900]},
            {"T4", [1950, 1850]}
          ],
          tiebreaks: ~w(GP DE)
        )

      t = pair_all!(t)
      enter!(t, 1, "T1", "T4", ["1-0", "1/2-1/2"])
      enter!(t, 1, "T2", "T3", ["0-1", "1-0"])
      enter!(t, 2, "T4", "T3", ["0-1", "1-0"])
      enter!(t, 2, "T1", "T2", ["0-1", "1/2-1/2"])
      enter!(t, 3, "T2", "T4", ["1-0", "0-1"])
      enter!(t, 3, "T3", "T1", ["0-1", "1/2-1/2"])

      entries = TeamStandings.standings(Repo.reload!(t))

      assert Enum.map(entries, &{&1.team.name, &1.mp, &1.gp}) ==
               [{"T3", 4.0, 4.5}, {"T2", 4.0, 3.5}, {"T1", 4.0, 3.5}, {"T4", 0.0, 0.5}]

      e = by_name(entries)
      assert {e["T2"].tiebreaks["DE"], e["T1"].tiebreaks["DE"]} == {2.0, 0.0}
    end

    test "codes team standings cannot calculate are dropped with a reason" do
      t = worked_example(tiebreaks: ~w(MP BHC1 SB KS))
      assert TeamStandings.effective_tiebreaks(t) == ~w(MP SB)

      assert TeamStandings.dropped_tiebreaks_with_reasons(t) == [
               {"BHC1", :not_calculable},
               {"KS", :not_calculable}
             ]
    end
  end

  describe "the tie-break catalogue" do
    test "an individual tournament's picker is unchanged, a team tournament's offers the team breaks" do
      individual = Tiebreaks.selectable("swiss") |> Enum.map(& &1.code)
      assert individual == ~w(BH BHC1 BHC2 MBH SB DE WIN WON BPG PS KS ARO AROC1)
      assert Tiebreaks.selectable() |> Enum.map(& &1.code) == individual

      assert Tiebreaks.selectable("team-roundrobin") |> Enum.map(& &1.code) ==
               ~w(BH SB DE MP GP EMGSB BB)
    end

    test "individual standings still drop the team-only breaks" do
      t = %Tournament{tiebreaks: ~w(BH MP GP BB EMGSB)}

      assert Standings.dropped_tiebreaks_with_reasons(t, []) ==
               [
                 {"MP", :not_calculable},
                 {"GP", :not_calculable},
                 {"BB", :not_calculable},
                 {"EMGSB", :not_calculable}
               ]
    end

    test "FIDE's team defaults are all calculable by team standings" do
      for type <- ~w(team-swiss team-roundrobin) do
        assert Tiebreaks.fide_defaults(type) -- TeamStandings.supported_codes() == []
      end
    end
  end

  describe "individual board statistics" do
    test "score, games, percentage and performance per board" do
      t = worked_example()
      stats = TeamStandings.board_stats(t)
      by = Map.new(stats, &{&1.player.name, &1})

      # T3's second board: lost R1 as White? No - T3 is team B in R1, so its
      # board-2 player was White and won; won R2 as White; won R3 as Black.
      t3b2 = by["T3 2"]
      assert {t3b2.main_board, t3b2.games, t3b2.points, t3b2.percentage} == {2, 3, 3.0, 100.0}

      # Opponents: T2 2 (1950), T4 2 (1850), T1 2 (2000); 3 wins.
      assert t3b2.performance == PairingsEngine.PlayerStats.performance([1950, 1850, 2000], 3, 0)

      t4b1 = by["T4 1"]
      assert {t4b1.games, t4b1.points} == {3, 0.5}

      assert stats |> Enum.map(& &1.main_board) |> Enum.uniq() == [1, 2]
    end
  end
end
