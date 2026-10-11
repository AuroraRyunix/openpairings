defmodule PairingsEngine.TeamForfeitFullScoreTest do
  @moduledoc """
  `team_forfeit_board_points`: what a match awarded as a whole pays the
  winner in game points.

  A league may fix the score of a match lost by team forfeit, whatever the
  team that turned up put on its boards. The Belgian Interclubs do (KBSB
  Wedstrijdreglement Art. 37.c): "Bij volledige ploegforfait wordt de
  uitslag vastgesteld op 2-0 voor de matchpunten, en voor de bordpunten op
  8-0 voor een ploeg van 8 spelers, op 6-0 voor een ploeg van 6 spelers en
  op 4-0 voor een ploeg van 4 spelers."

  "seated", the default, is what the app always did: a forfeit win on an
  empty seat pays nobody, so the awarded team gets a point per board it
  filled - 3-0 on four boards with three players. "full" pays the board
  count, in `TeamStandings.score_match/5`, the one place the standings, the
  tie-breaks, the snapshot and the TRF `310` totals read. No board result
  changes and no player gains a game.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{
    AccountsFixtures,
    Snapshot,
    TeamMatches,
    TeamStandings,
    TournamentExport,
    TournamentImport,
    Tournaments,
    TrfExport
  }

  alias PairingsEngine.Accounts.Scope

  defp four_boards(opts \\ []) do
    teams = for i <- 1..4, do: {"T#{i}", Enum.map(1..4, &(2000 - i * 10 - &1))}
    {t, _} = team_round_robin(teams, [boards: 4] ++ Keyword.delete(opts, :points))
    points = Keyword.get(opts, :points, "full")
    {:ok, t} = Tournaments.update_tournament(t, %{"team_forfeit_board_points" => points})
    t
  end

  defp paired(opts \\ []) do
    t = four_boards(opts)
    pair_next!(t)
    Repo.reload!(t)
  end

  defp first_match(t) do
    [m | _] = t.id |> Tournaments.get_round(1) |> Map.fetch!(:id) |> Tournaments.list_matches()
    m
  end

  defp scored(t, match),
    do: t |> Repo.reload!() |> TeamStandings.matches() |> Enum.find(&(&1.match_id == match.id))

  defp entry(t, team_id),
    do: t |> Repo.reload!() |> TeamStandings.standings() |> Enum.find(&(&1.team.id == team_id))

  # The home team seats three of four and is awarded the match.
  defp three_seated_and_forfeited(t) do
    m = first_match(t)
    %{a: a, b: b} = TeamMatches.lineups(t, m)
    {:ok, m} = TeamMatches.set_lineups(t, m, Enum.take(a, 3), b)
    {:ok, _} = TeamMatches.forfeit_match(t, m, m.team_a_id)
    m
  end

  describe "the default" do
    test "a new tournament scores a whole forfeit by seats filled" do
      teams = for i <- 1..4, do: {"T#{i}", Enum.map(1..4, &(2000 - i * 10 - &1))}
      {t, _} = team_round_robin(teams, boards: 4)
      assert t.team_forfeit_board_points == "seated"
      pair_next!(t)
      m = three_seated_and_forfeited(Repo.reload!(t))

      s = scored(t, m)
      assert {s.mp_a, s.mp_b} == {2.0, 0.0}
      assert {s.gp_a, s.gp_b} == {3.0, 0.0}
      assert s.awarded_full == nil
    end

    test "only the two values exist" do
      t = four_boards()
      assert {:error, _} = Tournaments.update_tournament(t, %{"team_forfeit_board_points" => "8"})
    end
  end

  describe "full: a match forfeited by decision" do
    test "to a team that seated three of four scores 4-0, not 3-0" do
      t = paired()
      m = three_seated_and_forfeited(t)

      s = scored(t, m)
      assert {s.mp_a, s.mp_b} == {2.0, 0.0}
      assert {s.gp_a, s.gp_b} == {4.0, 0.0}
      assert s.awarded_full == :a
    end

    test "to a team that entered no line-up scores 4-0 as well" do
      t = paired()
      m = first_match(t)
      %{b: b} = TeamMatches.lineups(t, m)
      {:ok, m} = TeamMatches.set_lineups(t, m, [], b)
      {:ok, _} = TeamMatches.forfeit_match(t, m, m.team_a_id)

      s = scored(t, m)
      assert {s.mp_a, s.mp_b} == {2.0, 0.0}
      assert {s.gp_a, s.gp_b} == {4.0, 0.0}
    end

    test "with every seat filled it was 4-0 before and still is" do
      t = paired()
      m = first_match(t)
      {:ok, _} = TeamMatches.forfeit_match(t, m, m.team_a_id)

      s = scored(t, m)
      assert {s.mp_a, s.mp_b} == {2.0, 0.0}
      assert {s.gp_a, s.gp_b} == {4.0, 0.0}
    end

    test "after games were played the boards decide, as they did" do
      t = paired()
      m = first_match(t)
      %{a: a, b: b} = TeamMatches.lineups(t, m)
      {:ok, m} = TeamMatches.set_lineups(t, m, Enum.take(a, 3), b)

      for sm <- TeamStandings.matches(t),
          sm.match_id == m.id,
          b <- sm.boards,
          b.a_player_id && b.b_player_id,
          do: {:ok, _} = Tournaments.update_pairing_result(b.pairing, "1/2-1/2")

      {:ok, _} = TeamMatches.forfeit_match(t, Repo.reload!(m), m.team_a_id)

      # Three boards were played, then the match was awarded: the three
      # boards the winner filled are its forfeit wins, the fourth nobody's.
      s = scored(t, m)
      assert s.played_before_decision?
      assert {s.mp_a, s.mp_b} == {2.0, 0.0}
      assert {s.gp_a, s.gp_b} == {3.0, 0.0}
    end

    test "no board changes and no player gains a game" do
      t = paired()
      m = three_seated_and_forfeited(t)
      s = scored(t, m)

      # The boards are what the decision wrote: three forfeit wins.
      assert Enum.map(s.boards, & &1.a_points) |> Enum.reject(&is_nil/1) |> Enum.sum() == 3.0

      stats = TeamStandings.board_stats(Repo.reload!(t))
      winners = Enum.filter(stats, &(&1.team_id == m.team_a_id))
      assert length(winners) == 3
      assert winners |> Enum.map(& &1.points) |> Enum.sum() == 3.0
    end
  end

  describe "full: a team out of the round" do
    test "its opponent scores the full count whatever it seats" do
      t = four_boards()
      [t1 | _] = Tournaments.list_teams(t.id)
      {:ok, _} = Tournaments.set_team_absent(t, t1, 1, true)
      pair_next!(t)
      t = Repo.reload!(t)

      m =
        t.id
        |> Tournaments.get_round(1)
        |> Map.fetch!(:id)
        |> Tournaments.list_matches()
        |> Enum.find(&(t1.id in [&1.team_a_id, &1.team_b_id]))

      # The team that came leaves a seat empty.
      %{a: a, b: b} = TeamMatches.lineups(t, m)

      {:ok, m} =
        if m.team_a_id == t1.id,
          do: TeamMatches.set_lineups(t, m, a, Enum.take(b, 3)),
          else: TeamMatches.set_lineups(t, m, Enum.take(a, 3), b)

      s = scored(t, m)
      {present, absent} = if m.team_a_id == t1.id, do: {s.gp_b, s.gp_a}, else: {s.gp_a, s.gp_b}
      assert {present, absent} == {4.0, 0.0}
      assert entry(t, t1.id).gp == 0.0
    end
  end

  describe "a single forfeited board stays one board's point" do
    test "an empty seat in a match that is played" do
      t = paired()
      m = first_match(t)
      %{a: a, b: b} = TeamMatches.lineups(t, m)
      {:ok, m} = TeamMatches.set_lineups(t, m, a, Enum.take(b, 3))

      for sm <- TeamStandings.matches(t),
          sm.match_id == m.id,
          b <- sm.boards,
          b.pairing.result == "",
          do: {:ok, _} = Tournaments.update_pairing_result(b.pairing, "1/2-1/2")

      # Three draws and the fourth board to the team that filled it.
      s = scored(t, m)
      assert s.awarded_full == nil
      assert {s.gp_a, s.gp_b} == {2.5, 1.5}
    end

    test "a board forfeit entered as a result" do
      t = paired()
      m = first_match(t)

      [first | rest] =
        for sm <- TeamStandings.matches(t), sm.match_id == m.id, b <- sm.boards, do: b

      {:ok, _} = Tournaments.update_pairing_result(first.pairing, "1-0FF")
      for b <- rest, do: {:ok, _} = Tournaments.update_pairing_result(b.pairing, "1/2-1/2")

      s = scored(t, m)
      assert s.awarded_full == nil
      assert {s.gp_a, s.gp_b} == {2.5, 1.5}
    end

    test "every board forfeited one by one is still not a decision" do
      t = paired()
      m = first_match(t)
      %{a: a, b: b} = TeamMatches.lineups(t, m)
      {:ok, m} = TeamMatches.set_lineups(t, m, Enum.take(a, 3), b)

      for sm <- TeamStandings.matches(t), sm.match_id == m.id, b <- sm.boards do
        result = if rem(b.board, 2) == 1, do: "1-0FF", else: "0-1FF"
        {:ok, _} = Tournaments.update_pairing_result(b.pairing, result)
      end

      # Nobody awarded the match and both teams were in the round: the
      # boards add up, the empty seat's forfeit win paying nobody.
      s = scored(t, m)
      assert s.awarded_full == nil
      assert {s.gp_a, s.gp_b} == {3.0, 0.0}
    end
  end

  describe "everything downstream reads the same figure" do
    test "standings, the board tie-break, the snapshot and the TRF totals" do
      t = paired(tiebreaks: ~w(MP GP BB))
      m = three_seated_and_forfeited(t)

      for sm <- TeamStandings.matches(Repo.reload!(t)),
          sm.round == 1,
          b <- sm.boards,
          b.pairing.result == "",
          do: {:ok, _} = Tournaments.update_pairing_result(b.pairing, "1/2-1/2")

      e = entry(t, m.team_a_id)
      assert {e.mp, e.gp} == {2.0, 4.0}
      # Board 1 weighs 4, board 4 weighs 1: 4 + 3 + 2 + 1, the empty seat
      # included, so it adds up with the game points the table shows.
      assert e.tiebreaks["BB"] == 10.0

      {:ok, _} = t.id |> Tournaments.get_round(1) |> Tournaments.publish_round_now()
      t = t |> Repo.reload!() |> Ecto.Changeset.change(standings_through: 1) |> Repo.update!()
      snapshot = Snapshot.build(t)
      no = Enum.find(snapshot["teams"], &(&1["name"] == e.team.name))["no"]
      row = Enum.find(snapshot["team_standings"]["rows"], &(&1["team"] == no))
      assert {row["mp"], row["gp"]} == {2.0, 4.0}

      sent =
        snapshot["rounds"]
        |> Enum.flat_map(&(&1["matches"] || []))
        |> Enum.find(&(&1["team_a"] == no or &1["team_b"] == no))

      assert sent["game_points"] in [%{"a" => 4.0, "b" => 0.0}, %{"a" => 0.0, "b" => 4.0}]

      t = t |> Ecto.Changeset.change(round_dates: ["2026-10-01"]) |> Repo.update!()
      {:ok, text} = TrfExport.export(t, nil)

      line =
        text
        |> String.split("\r\n")
        |> Enum.find(&(String.starts_with?(&1, "310") and &1 =~ e.team.name))

      assert line =~ "4.0"
    end

    test "the setting goes out in the export and comes back on import" do
      t = paired()
      scope = Scope.for_user(AccountsFixtures.user_fixture())

      data = t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()
      [exported] = data["tournaments"]
      assert exported["tournament"]["team_forfeit_board_points"] == "full"
      {:ok, [copy]} = TournamentImport.import(data, scope)
      assert copy.team_forfeit_board_points == "full"
    end
  end

  describe "FIDE mode" do
    test "locked with the rest of the scoring once round 1 is paired" do
      t = four_boards(points: "seated")
      refute :team_forfeit_board_points in Tournaments.fide_locked_fields(t)
      pair_next!(t)
      assert :team_forfeit_board_points in Tournaments.fide_locked_fields(Repo.reload!(t))
    end
  end
end
