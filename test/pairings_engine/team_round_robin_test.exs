defmodule PairingsEngine.TeamRoundRobinTest do
  # Whole schedules written in sequence; SQLite's single writer.
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Pairing, Repo, RoundRobin, TeamRoundRobin, Tournaments}
  alias PairingsEngine.Tournaments.{Match, Player}

  defp teams(n, boards \\ 2) do
    for i <- 1..n, do: {"T#{i}", Enum.map(1..boards, &(2000 - i * 10 - &1))}
  end

  # `{white_team_number, black_team_number}` per played match, and the bye
  # team's number, for one round - what the Berger table itself says.
  defp round_shape(t, number) do
    round = Tournaments.get_round(t.id, number)
    teams = t.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1.pairing_number})
    matches = Tournaments.list_matches(round.id)

    played =
      for %Match{team_b_id: b} = m <- matches, b != nil do
        {teams[m.team_a_id], teams[m.team_b_id]}
      end

    byes = for %Match{team_b_id: nil} = m <- matches, do: teams[m.team_a_id]
    {MapSet.new(played), byes}
  end

  describe "Berger tables over teams (C.05 Annex 1)" do
    for n <- [4, 5, 6] do
      @n n
      test "#{n} teams: every round is RoundRobin.schedule/3 over the team numbers" do
        {t, _} = team_round_robin(teams(@n))
        t = pair_all!(t)

        assert t.rounds_count == RoundRobin.total_rounds(@n, 1)

        for r <- 1..t.rounds_count do
          {:ok, entries} = RoundRobin.schedule(@n, 1, r)
          expected = for {:pairing, w, b} <- entries, into: MapSet.new(), do: {w, b}
          expected_byes = for {:bye, x} <- entries, do: x

          assert round_shape(t, r) == {expected, expected_byes}
        end
      end
    end

    test "4 teams match the published FIDE table, team A holding the table's White" do
      {t, _} = team_round_robin(teams(4))
      t = pair_all!(t)

      # FIDE Handbook C.05 Annex 1, N=4 (the same table round_robin_test pins).
      assert round_shape(t, 1) == {MapSet.new([{1, 4}, {2, 3}]), []}
      assert round_shape(t, 2) == {MapSet.new([{4, 3}, {1, 2}]), []}
      assert round_shape(t, 3) == {MapSet.new([{2, 4}, {3, 1}]), []}
    end

    test "every team meets every other team exactly once, and 5 teams give each one bye" do
      {t, _} = team_round_robin(teams(5))
      t = pair_all!(t)

      shapes = for r <- 1..t.rounds_count, do: round_shape(t, r)

      meetings =
        for {played, _} <- shapes, {a, b} <- played, do: Enum.sort([a, b])

      assert Enum.sort(meetings) == for(a <- 1..5, b <- 1..5, a < b, do: [a, b])
      assert shapes |> Enum.flat_map(&elem(&1, 1)) |> Enum.sort() == [1, 2, 3, 4, 5]

      # A bye match has no boards.
      bye_match = Repo.one!(from m in Match, where: is_nil(m.team_b_id), limit: 1)

      refute Repo.exists?(
               from p in PairingsEngine.Tournaments.Pairing, where: p.match_id == ^bye_match.id
             )
    end

    test "a double round robin reverses the colours in the second cycle" do
      {t, _} = team_round_robin(teams(4), rr_cycles: 2)
      t = pair_all!(t)

      assert t.rounds_count == 6
      {first, _} = round_shape(t, 1)
      {second, _} = round_shape(t, 4)
      assert second == MapSet.new(first, fn {a, b} -> {b, a} end)
    end

    test "fewer than two teams is refused, and pairing again after the end says the schedule is complete" do
      {t, _} = team_round_robin(teams(1))
      assert {:error, "At least two teams are needed"} = RoundRobin.pair_next_round(t)

      {t, _} = team_round_robin(teams(2))
      t = pair_all!(t)
      assert {:ok, 1} = RoundRobin.pair_all_rounds(t)
      assert {:error, {:all_rounds_paired, 1}} = Pairing.pair_next_round(t)
    end
  end

  describe "a match's boards" do
    test "the first team has White on board 1 and on every odd board" do
      assert Enum.map(1..6, &TeamRoundRobin.team_a_white?/1) == [
               true,
               false,
               true,
               false,
               true,
               false
             ]

      a = for i <- 1..4, do: %Player{id: 10 + i, name: "A#{i}"}
      b = for i <- 1..4, do: %Player{id: 20 + i, name: "B#{i}"}

      assert [
               {1, %{id: 11}, %{id: 21}, ""},
               {2, %{id: 22}, %{id: 12}, ""},
               {3, %{id: 13}, %{id: 23}, ""},
               {4, %{id: 24}, %{id: 14}, ""}
             ] = TeamRoundRobin.match_boards(a, b, 4)
    end

    test "board against board in board order, stored so board 1's colour follows the Berger table" do
      {t, _} = team_round_robin([{"Alpha", [2100, 2000]}, {"Beta", [1900, 1800]}])
      t = pair_all!(t)

      {match, [b1, b2]} = match_between(t, 1, "Alpha", "Beta")
      alpha = Tournaments.get_team(t.id, match.team_a_id)
      assert alpha.name == "Alpha"

      [a1, a2] = Tournaments.team_roster(t.id, alpha.id)
      [x1, x2] = Tournaments.team_roster(t.id, match.team_b_id)

      assert {b1.board, b1.white_player_id, b1.black_player_id} == {1, a1.id, x1.id}
      assert {b2.board, b2.white_player_id, b2.black_player_id} == {2, x2.id, a2.id}
    end

    test "unequal teams: the short team's empty board is a forfeit win for the player who is there" do
      a = for i <- 1..4, do: %Player{id: 10 + i}
      b = for i <- 1..2, do: %Player{id: 20 + i}

      assert [
               {1, _, _, ""},
               {2, _, _, ""},
               {3, %{id: 13}, nil, "1-0FF"},
               {4, nil, %{id: 14}, "0-1FF"}
             ] = TeamRoundRobin.match_boards(a, b, 4)
    end

    test "a board neither team can fill is not created" do
      a = [%Player{id: 11}]
      b = [%Player{id: 21}]
      assert [{1, _, _, ""}] = TeamRoundRobin.match_boards(a, b, 3)
    end

    test "missing players in a real schedule become forfeits, and board numbers run on across matches" do
      {t, _} = team_round_robin([{"Full", [2000, 1990, 1980]}, {"Short", [1900]}], boards: 3)
      t = pair_all!(t)

      {_match, boards} = match_between(t, 1, "Full", "Short")
      assert Enum.map(boards, & &1.board) == [1, 2, 3]
      # Board 2: Full is Black, so the empty seat is White's and Black wins.
      assert Enum.map(boards, & &1.result) == ["", "0-1FF", "1-0FF"]
      assert Enum.at(boards, 1).white_player_id == nil
      assert Enum.at(boards, 2).black_player_id == nil
    end

    test "the second match's boards continue after the first match's" do
      {t, _} = team_round_robin(teams(4, 3), boards: 3)
      t = pair_all!(t)

      round = Tournaments.get_round(t.id, 1)
      [m1, m2] = Tournaments.list_matches(round.id)

      by_match = Enum.group_by(round.pairings, & &1.match_id, & &1.board)
      assert Enum.sort(by_match[m1.id]) == [1, 2, 3]
      assert Enum.sort(by_match[m2.id]) == [4, 5, 6]
    end
  end

  describe "line-ups" do
    test "a player absent for the round is skipped and the reserve moves up" do
      p = fn id, attrs -> struct(%Player{id: id, status: "active", absent_rounds: ""}, attrs) end

      roster = [
        p.(1, %{}),
        p.(2, %{absent_rounds: "2"}),
        p.(3, %{}),
        p.(4, %{status: "withdrawn"})
      ]

      assert Enum.map(TeamRoundRobin.lineup(roster, 1, 2), & &1.id) == [1, 2]
      assert Enum.map(TeamRoundRobin.lineup(roster, 2, 2), & &1.id) == [1, 3]
      assert Enum.map(TeamRoundRobin.lineup(roster, 2, 3), & &1.id) == [1, 3]
    end

    test "players get pairing numbers team by team, in board order" do
      {t, _} = team_round_robin([{"A", [1500, 2400]}, {"B", [2500, 1000]}])
      t = pair_all!(t)

      numbers =
        for team <- Tournaments.list_teams(t.id),
            p <- Tournaments.team_roster(t.id, team.id),
            do: {team.name, p.name, p.pairing_number}

      assert numbers == [{"A", "A 1", 1}, {"A", "A 2", 2}, {"B", "B 1", 3}, {"B", "B 2", 4}]
    end

    test "the seeding order becomes the team pairing numbers and freezes" do
      {t, [a, b, c]} = team_round_robin(teams(3))
      {:ok, _} = Tournaments.move_team(t, c, :up)
      {:ok, _} = Tournaments.move_team(t, Repo.reload!(c), :up)

      t = pair_all!(t)
      numbers = t.id |> Tournaments.list_teams() |> Enum.map(&{&1.id, &1.pairing_number})
      assert numbers == [{c.id, 1}, {a.id, 2}, {b.id, 3}]

      assert {:error, :teams_frozen} = Tournaments.move_team(t, Repo.reload!(a), :up)
      assert {:error, :teams_frozen} = Tournaments.seed_teams_by_rating(t)
      assert {:error, :team_scheduled} = Tournaments.delete_team(Repo.reload!(a))
    end

    test "unpairing every round gives the teams back to the Teams page" do
      {t, _} = team_round_robin(teams(4))
      t = pair_all!(t)

      for n <- 3..1//-1, do: :ok = Pairing.delete_round(t.id, n)

      refute Tournaments.teams_frozen?(t.id)
      refute Repo.exists?(Match)
    end

    test "boards per match locks with the first round, for team events only" do
      {t, _} = team_round_robin(teams(2))
      refute :team_boards in Tournaments.locked_fields(t)

      t = pair_all!(t)
      assert :team_boards in Tournaments.locked_fields(t)
      assert {:error, :locked_after_pairing} = Tournaments.update_tournament(t, %{team_boards: 6})
    end
  end

  describe "team management" do
    test "board order is renumbered when a player moves or leaves" do
      {t, [a, _b]} = team_round_robin([{"A", [2000, 1900, 1800]}, {"B", [1700]}])
      [p1, p2, p3] = Tournaments.team_roster(t.id, a.id)

      {:ok, _} = Tournaments.move_player_board(t, p3, :up)
      assert Tournaments.team_roster(t.id, a.id) |> Enum.map(& &1.id) == [p1.id, p3.id, p2.id]

      {:ok, _} = Tournaments.set_player_team(t, Repo.reload!(p1), nil)

      assert Tournaments.team_roster(t.id, a.id) |> Enum.map(&{&1.id, &1.board_order}) ==
               [{p3.id, 1}, {p2.id, 2}]

      assert Repo.reload!(p1).board_order == nil
    end

    test "seeding by rating averages each team's first boards" do
      {t, [weak, strong]} =
        team_round_robin([{"Weak", [1500, 1500, 2800]}, {"Strong", [2000, 2000]}], boards: 2)

      {:ok, _} = Tournaments.seed_teams_by_rating(t)
      assert Enum.map(Tournaments.list_teams(t.id), & &1.id) == [strong.id, weak.id]
    end

    test "a team from another tournament cannot take a player" do
      {t1, [team1]} = team_round_robin([{"One", [2000]}])
      {t2, _} = team_round_robin([{"Two", [2000]}])
      [player2] = Tournaments.list_players(t2.id)

      assert {:error, :not_found} = Tournaments.set_player_team(t1, player2, team1)
      assert {:error, :not_found} = Tournaments.set_player_team(t2, player2, team1)
    end
  end
end
