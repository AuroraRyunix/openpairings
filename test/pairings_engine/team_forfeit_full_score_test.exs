defmodule PairingsEngine.TeamForfeitFullScoreTest do
  @moduledoc """
  FAILS ON PURPOSE - the test of a change that is not made yet.

  A league may fix the score of a match lost by team forfeit, whatever the
  team that turned up put on its boards. The Belgian Interclubs do (KBSB
  Wedstrijdreglement Art. 37.c): "Bij volledige ploegforfait wordt de
  uitslag vastgesteld op 2-0 voor de matchpunten, en voor de bordpunten op
  8-0 voor een ploeg van 8 spelers, op 6-0 voor een ploeg van 6 spelers en
  op 4-0 voor een ploeg van 4 spelers."

  Today a match forfeited by decision (`TeamMatches.forfeit_match/3`), and
  a team absent for a round robin round (`TeamRounds`), write a forfeit win
  on every board - and with required line-ups a forfeit win on an EMPTY
  seat pays nobody (`TeamStandings.side_points/2`). So the awarded team
  gets one game point per board it seated: 3-0 on four boards with three
  players, 0-0 (and the match, by `awarded_unseated?/2`) with none. The
  match points are right in every case; only the game points fall short.

  The change asked for: a tournament setting, here called
  `team_forfeit_board_points` - `"seated"` (today's behaviour, the default)
  or `"full"`. With `"full"`, a match awarded as a whole and in which no
  game was played (`forfeited_to_team_id` set and not
  `played_before_decision?`, or a round robin opponent absent as a team)
  scores `team_boards` game points to the awarded team and none to the
  other, in `TeamStandings.score_match/4` - the one place the standings,
  the tie-breaks, the snapshot and the TRF `310` totals read. No board
  result changes and no player gains a game. `OpenPairingsKbsb.Interclubs.
  settings/3` would then set it to `"full"` for the series it creates.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{TeamMatches, TeamStandings, Tournaments}

  defp four_boards do
    teams = for i <- 1..4, do: {"T#{i}", Enum.map(1..4, &(2000 - i * 10 - &1))}
    {t, _} = team_round_robin(teams, boards: 4)
    {:ok, t} = Tournaments.update_tournament(t, %{"team_forfeit_board_points" => "full"})
    pair_next!(t)
    Repo.reload!(t)
  end

  defp first_match(t) do
    [m | _] = t.id |> Tournaments.get_round(1) |> Map.fetch!(:id) |> Tournaments.list_matches()
    m
  end

  defp scored(t, match),
    do: t |> Repo.reload!() |> TeamStandings.matches() |> Enum.find(&(&1.match_id == match.id))

  test "a match forfeited to a team that seated three of four scores 4-0, not 3-0" do
    t = four_boards()
    m = first_match(t)
    %{a: a, b: b} = TeamMatches.lineups(t, m)
    {:ok, m} = TeamMatches.set_lineups(t, m, Enum.take(a, 3), b)
    {:ok, _} = TeamMatches.forfeit_match(t, m, m.team_a_id)

    s = scored(t, m)
    assert {s.mp_a, s.mp_b} == {2.0, 0.0}
    assert {s.gp_a, s.gp_b} == {4.0, 0.0}
  end

  test "a match with every seat filled already scores 4-0 (passes today, and must keep passing)" do
    t = four_boards()
    m = first_match(t)

    for sm <- TeamStandings.matches(t),
        sm.match_id == m.id,
        b <- sm.boards,
        do: {:ok, _} = Tournaments.update_pairing_result(b.pairing, "1/2-1/2")

    {:ok, _} = TeamMatches.forfeit_match(t, Repo.reload!(m), m.team_a_id)

    s = scored(t, m)
    assert {s.mp_a, s.mp_b} == {2.0, 0.0}
    assert {s.gp_a, s.gp_b} == {4.0, 0.0}
  end
end
