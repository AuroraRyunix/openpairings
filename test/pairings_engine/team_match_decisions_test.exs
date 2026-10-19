defmodule PairingsEngine.TeamMatchDecisionsTest do
  @moduledoc """
  A team match decided as a whole - forfeited to one team, a double
  forfeit - and what follows from it: withdrawing a decision nobody took by
  hand, two withdrawn teams that were to meet, the boards under a decision,
  how such a match counts in W/D/L and the tie-breaks, the bye's boards,
  and direct encounter. (Review sweep 2026-10-19, TEAM-1 to TEAM-4, TEAM-6.)
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Repo, TeamMatches, TeamStandings, Tournaments}
  alias PairingsEngine.Tournaments.{Match, Pairing, Player}

  defp teams(n, boards \\ 2) do
    for i <- 1..n, do: {"T#{i}", Enum.map(1..boards, &(2000 - i * 10 - &1))}
  end

  defp team(t, name), do: t.id |> Tournaments.list_teams() |> Enum.find(&(&1.name == name))

  defp by_name(entries), do: Map.new(entries, &{&1.team.name, &1})

  defp board_rows(match),
    do: Repo.all(from p in Pairing, where: p.match_id == ^match.id, order_by: p.board)

  defp absent!(team, rounds),
    do: team |> Ecto.Changeset.change(absent_rounds: rounds) |> Repo.update!()

  describe "withdrawing a double forfeit the pairing wrote (TEAM-1)" do
    # Both teams out of round 1 as teams: the pairing writes the match as a
    # double forfeit with no boards. Withdrawing it used to clear the flag
    # and leave an empty match, which scored as a 0-0 draw - a draw's match
    # points to both for a match neither played.
    defp both_out do
      {t, [a, b]} = team_round_robin([{"A", [2000, 1900]}, {"B", [1950, 1850]}], rounds_count: 1)
      absent!(a, [1])
      absent!(b, [1])
      t = pair_all!(t)
      {match, boards} = match_between(t, 1, "A", "B")
      assert match.double_forfeit and boards == [] and is_nil(match.forfeit_previous_results)
      {t, match}
    end

    test "is refused while nobody can be seated: it would be the same match again" do
      {t, match} = both_out()

      assert {:error, :nobody_to_seat} = TeamMatches.withdraw_forfeit(t, match)
      assert Repo.reload!(match).double_forfeit

      [m] = TeamStandings.matches(t)
      assert {m.mp_a, m.mp_b} == {0.0, 0.0}
    end

    test "seats the match again once the teams are back, instead of scoring it a draw" do
      {t, match} = both_out()
      absent!(team(t, "A"), [])
      absent!(team(t, "B"), [])

      assert {:ok, withdrawn} = TeamMatches.withdraw_forfeit(t, match)
      refute withdrawn.double_forfeit

      {_match, boards} = match_between(t, 1, "A", "B")
      assert length(boards) == 2
      assert Enum.all?(boards, &(&1.white_player_id && &1.black_player_id && &1.result == ""))

      # Nothing played yet: no match points for anybody, least of all a draw's.
      [m] = TeamStandings.matches(t)
      refute m.scored?
      assert {m.mp_a, m.mp_b} == {nil, nil}
    end

    test "with one team back, the other's boards are the forfeit wins the pairing writes" do
      {t, match} = both_out()
      absent!(team(t, "A"), [])

      assert {:ok, _} = TeamMatches.withdraw_forfeit(t, match)
      {_match, boards} = match_between(t, 1, "A", "B")
      # A has White on board 1, Black on board 2.
      assert Enum.map(boards, & &1.result) == ["1-0FF", "0-1FF"]

      [m] = TeamStandings.matches(t)
      assert {m.mp_a, m.mp_b} == {2.0, 0.0}
    end

    test "a decision taken by hand still gives the boards back what they held" do
      {t, _} = team_swiss(teams(4), rounds: 3)
      pair_next!(t)
      t = Repo.reload!(t)
      {match, _} = match_between(t, 1, "T1", "T3")

      {:ok, doubled} = TeamMatches.double_forfeit(t, match)
      assert TeamMatches.decided_by_hand?(doubled)
      assert {:ok, _} = TeamMatches.withdraw_forfeit(t, doubled)

      {_match, boards} = match_between(t, 1, "T1", "T3")
      assert Enum.all?(boards, &(&1.result == ""))
    end
  end

  describe "two withdrawn teams that were to meet (TEAM-2)" do
    # Four teams, the Berger table for N=4:
    #   R1: T1-T4, T2-T3   R2: T4-T3, T1-T2   R3: T2-T4, T3-T1
    # T1 and T2 both withdraw from round 2; they were to meet in round 2.
    defp four_team_rr do
      {t, _} = team_round_robin(teams(4), rounds_count: 3)
      t = pair_all!(t)
      enter!(t, 1, "T1", "T4", ["1-0", "0-1"])
      enter!(t, 1, "T2", "T3", ["1-0", "0-1"])
      Repo.reload!(t)
    end

    defp withdraw!(t, name),
      do: {:ok, _} = Tournaments.withdraw_team(t, team(t, name), 2)

    defp decisions(t) do
      names = t.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1.name})

      from(m in Match,
        join: r in assoc(m, :round),
        where: r.tournament_id == ^t.id and not is_nil(m.team_b_id),
        order_by: [r.number, m.board],
        select: {r.number, m.team_a_id, m.team_b_id, m.forfeited_to_team_id, m.double_forfeit}
      )
      |> Repo.all()
      |> Enum.map(fn {n, a, b, to, double?} ->
        {n, Enum.sort([names[a], names[b]]), names[to], double?}
      end)
    end

    test "neither keeps a forfeit win, whichever withdrew first" do
      first = four_team_rr()
      withdraw!(first, "T1")
      withdraw!(first, "T2")

      second = four_team_rr()
      withdraw!(second, "T2")
      withdraw!(second, "T1")

      assert decisions(first) == decisions(second)
      assert {2, ["T1", "T2"], nil, true} in decisions(first)

      for t <- [first, second] do
        [m] =
          t
          |> TeamStandings.matches()
          |> Enum.filter(&(&1.round == 2 and &1.double_forfeit?))

        assert {m.mp_a, m.mp_b} == {0.0, 0.0}
      end

      e1 = first |> TeamStandings.standings() |> by_name()
      e2 = second |> TeamStandings.standings() |> by_name()

      assert Map.new(e1, fn {n, e} -> {n, {e.mp, e.gp}} end) ==
               Map.new(e2, fn {n, e} -> {n, {e.mp, e.gp}} end)
    end

    test "reinstating the second team gives it the forfeit back" do
      t = four_team_rr()
      withdraw!(t, "T1")
      withdraw!(t, "T2")

      {:ok, _} = Tournaments.reinstate_team(t, team(t, "T2"))

      assert {2, ["T1", "T2"], "T2", false} in decisions(t)
    end
  end

  describe "the boards of a decided match (TEAM-6)" do
    defp swiss_round_one do
      {t, _} = team_swiss(teams(4), rounds: 3)
      pair_next!(t)
      Repo.reload!(t)
    end

    test "are refused a result until the decision is withdrawn" do
      t = swiss_round_one()
      {match, [b1, _]} = match_between(t, 1, "T1", "T3")
      {:ok, doubled} = TeamMatches.double_forfeit(t, match)

      b1 = Repo.reload!(b1)
      assert {:error, :match_decided} = Tournaments.update_pairing_result(b1, "1-0")
      refute Tournaments.result_clearable?(b1)

      {:ok, _} = TeamMatches.withdraw_forfeit(t, doubled)
      assert {:ok, _} = Tournaments.update_pairing_result(Repo.reload!(b1), "1-0")
    end

    test "of a match forfeited to one team, too" do
      t = swiss_round_one()
      {match, [b1, _]} = match_between(t, 1, "T1", "T3")
      {:ok, _} = TeamMatches.forfeit_match(t, match, team(t, "T1").id)

      assert {:error, :match_decided} =
               Tournaments.update_pairing_result(Repo.reload!(b1), "0-1")
    end
  end

  describe "a match awarded to a team that seated nobody (TEAM-3)" do
    # Required line-ups. Round 1 pairs T1-T3; T3 then fields nobody (its
    # line-up emptied), so its seats are T1's forfeit wins, and the arbiter
    # forfeits the match to T3 by decision - 0-0 on the boards, a win in
    # match points.
    defp awarded_to_nobody do
      {t, _} = team_swiss(teams(4), rounds: 3, tiebreaks: ~w(MP GP BH))
      pair_next!(t)
      t = Repo.reload!(t)

      {match, _} = match_between(t, 1, "T1", "T3")
      t3 = team(t, "T3").id
      other_id = if match.team_a_id == t3, do: match.team_b_id, else: match.team_a_id
      other = TeamMatches.default_lineup(t, other_id, 1)

      {la, lb} = if match.team_a_id == t3, do: {[], other}, else: {other, []}
      {:ok, match} = TeamMatches.set_lineups(t, match, la, lb)
      assert Enum.all?(board_rows(match), &(&1.result in ["1-0FF", "0-1FF"]))

      {:ok, match} = TeamMatches.forfeit_match(t, match, t3)
      enter!(t, 1, "T4", "T2", ["1/2-1/2", "1/2-1/2"])

      {Repo.reload!(t), match}
    end

    test "counts as won in W/D/L, as its match points say" do
      {t, _match} = awarded_to_nobody()
      e = t |> TeamStandings.standings() |> by_name()

      assert e["T3"].mp == 2.0
      assert {e["T3"].won, e["T3"].drawn, e["T3"].lost} == {1, 0, 0}
    end

    test "is a forfeit WIN for the tie-breaks, a forfeit loss for the other side" do
      {t, match} = awarded_to_nobody()
      e = t |> TeamStandings.standings() |> by_name()
      t3 = team(t, "T3")
      loser_id = if match.team_a_id == t3.id, do: match.team_b_id, else: match.team_a_id
      loser = Enum.find(Map.values(e), &(&1.team.id == loser_id))

      assert [%{kind: :forfeit_win}] = e["T3"].working["BH"]
      assert [%{kind: :forfeit_loss}] = loser.working["BH"]
    end
  end

  describe "the team Swiss bye in the BB column (TEAM-4)" do
    test "counts a win on every board, as the Board Count it ranks by does" do
      {t, _} = team_swiss(teams(3), rounds: 2, tiebreaks: ~w(MP GP BB))
      pair_next!(t)
      t = Repo.reload!(t)

      [bye] = t |> TeamStandings.matches() |> Enum.filter(& &1.bye?)

      e =
        t
        |> TeamStandings.standings()
        |> Enum.find(&(&1.team.id == bye.team_a_id))

      # Two boards: board 1 weighs 2, board 2 weighs 1; a win is 1 point.
      assert e.tiebreaks["BB"] == 3.0
      # The game points stay a drawn match's (C.04.6 Art. 1.4).
      assert e.gp == 1.0
    end
  end

  describe "direct encounter, as shown (R2)" do
    # A double forfeit between two teams that then stay level, with a loss
    # worth half a match point so the encounter has something to add up.
    test "a team Swiss leaves a forfeited meeting out, as the order does" do
      {t, _} =
        team_swiss(teams(4),
          rounds: 1,
          tiebreaks: ~w(DE),
          team_match_points_loss: 0.5
        )

      pair_next!(t)
      t = Repo.reload!(t)
      {match, _} = match_between(t, 1, "T1", "T3")
      {:ok, _} = TeamMatches.double_forfeit(t, match)
      enter!(t, 1, "T4", "T2", ["1/2-1/2", "1/2-1/2"])

      e = t |> TeamStandings.standings() |> by_name()
      assert e["T1"].mp == e["T3"].mp
      assert {e["T1"].tiebreaks["DE"], e["T3"].tiebreaks["DE"]} == {0.0, 0.0}
    end

    test "a round robin counts it: its forfeits are games (C.07 Art. 15.2)" do
      {t, _} =
        team_round_robin(teams(4),
          rounds_count: 3,
          tiebreaks: ~w(DE),
          team_match_points_loss: 0.5
        )

      t = pair_all!(t)
      {match, _} = match_between(t, 1, "T1", "T4")
      {:ok, _} = TeamMatches.double_forfeit(t, match)
      enter!(t, 1, "T2", "T3", ["1/2-1/2", "1/2-1/2"])

      e = t |> TeamStandings.standings() |> by_name()
      assert e["T1"].mp == e["T4"].mp
      assert {e["T1"].tiebreaks["DE"], e["T4"].tiebreaks["DE"]} == {0.5, 0.5}
    end
  end

  test "a player missing from the roster moves nowhere, without raising (DIA-1)" do
    {t, _} = team_round_robin([{"A", [2000, 1900]}, {"B", [1950, 1850]}])
    [p | _] = Tournaments.team_roster(t.id, team(t, "A").id)

    # The page still shows P on A; a co-arbiter has since moved P to B.
    Repo.update_all(from(x in Player, where: x.id == ^p.id), set: [team_id: team(t, "B").id])

    assert {:ok, ^p} = Tournaments.move_player_board(t, p, :up)
    assert {:ok, ^p} = Tournaments.move_player_board(t, p, :down)
  end
end
