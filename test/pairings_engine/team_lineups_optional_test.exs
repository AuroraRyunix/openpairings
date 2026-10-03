defmodule PairingsEngine.TeamLineupsOptionalTest do
  @moduledoc """
  Team events paired with no players entered (`team_lineups` "optional",
  docs/team-tournaments.md "Line-ups optional"): pairing, results on empty
  boards and as a match score, standings, team absence, the TRF report and
  the JSON backup.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.Accounts.{Scope, User}

  alias PairingsEngine.{
    Repo,
    TeamMatches,
    TeamStandings,
    TournamentExport,
    TournamentImport,
    Tournaments,
    TrfExport
  }

  alias PairingsEngine.Tournaments.{Match, Pairing}

  defp no_players(n), do: for(i <- 1..n, do: {"T#{i}", []})

  @dates ~w(2026-10-01 2026-10-02 2026-10-03 2026-10-04 2026-10-05)

  defp swiss(n, opts \\ []),
    do:
      team_swiss(
        no_players(n),
        [boards: 4, rounds: 3, team_lineups: "optional", round_dates: @dates] ++ opts
      )

  defp rr(n, opts \\ []),
    do:
      team_round_robin(
        no_players(n),
        [boards: 4, team_lineups: "optional", round_dates: @dates] ++ opts
      )

  defp matches(t, number) do
    round = Tournaments.get_round(t.id, number)

    round.id
    |> Tournaments.list_matches()
    |> Enum.filter(& &1.team_b_id)
    |> Enum.map(fn m ->
      boards =
        Repo.all(from p in Pairing, where: p.match_id == ^m.id, order_by: p.board)

      {m, boards}
    end)
  end

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "lineups#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  describe "pairing teams with no players" do
    test "a team Swiss pairs, and every match gets all its boards, empty and with no result" do
      {t, _} = swiss(4)
      round = pair_next!(t)
      assert round.number == 1

      ms = matches(t, 1)
      assert length(ms) == 2

      for {_m, boards} <- ms do
        assert length(boards) == 4
        assert Enum.all?(boards, &(is_nil(&1.white_player_id) and is_nil(&1.black_player_id)))
        assert Enum.all?(boards, &(&1.result == ""))
      end

      # Board numbers run on through the round.
      assert ms |> Enum.flat_map(&elem(&1, 1)) |> Enum.map(& &1.board) == Enum.to_list(1..8)
    end

    test "with required line-ups the same teams are refused, as before" do
      {t, _} = team_swiss(no_players(4), boards: 4, rounds: 3)

      assert {:error, "At least two teams with a player available for round 1 are needed"} =
               PairingsEngine.Pairing.pair_next_round(t)
    end

    test "a team round robin pairs every round with all boards" do
      {t, _} = rr(4)
      t = pair_all!(t)

      for r <- 1..t.rounds_count, {_m, boards} <- matches(t, r) do
        assert length(boards) == 4
        assert Enum.all?(boards, &(&1.result == ""))
      end
    end

    test "a team with some players seats them and leaves the rest of its boards empty" do
      {t, _} =
        team_swiss([{"A", [2100, 2000]}, {"B", []}, {"C", []}, {"D", [1900]}],
          boards: 3,
          rounds: 3,
          team_lineups: "optional"
        )

      pair_next!(t)

      for {_m, boards} <- matches(t, 1) do
        assert length(boards) == 3
        # No forfeit for a seat nobody was entered for.
        assert Enum.all?(boards, &(&1.result == ""))
      end

      seated =
        t
        |> matches(1)
        |> Enum.flat_map(&elem(&1, 1))
        |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])

      assert seated |> Enum.reject(&is_nil/1) |> length() == 3
    end
  end

  describe "results" do
    test "board results on empty boards score the teams, and the next round pairs" do
      {t, _} = swiss(4)
      pair_next!(t)
      [{m1, b1}, {m2, b2}] = matches(t, 1)

      # Match 1: team A wins 3-1; match 2: 2-2.
      for {p, r} <- Enum.zip(b1, ~w(1-0 0-1 1-0 1/2-1/2)),
          do: {:ok, _} = Tournaments.update_pairing_result(p, r)

      for {p, r} <- Enum.zip(b2, ~w(1/2-1/2 1/2-1/2 1/2-1/2 1/2-1/2)),
          do: {:ok, _} = Tournaments.update_pairing_result(p, r)

      # Board 2 is Black for team A: "0-1" there is team A's win.
      scored = t |> Repo.reload!() |> TeamStandings.matches() |> Map.new(&{&1.match_id, &1})
      assert {scored[m1.id].gp_a, scored[m1.id].gp_b} == {3.5, 0.5}
      assert {scored[m1.id].mp_a, scored[m1.id].mp_b} == {2.0, 0.0}
      assert {scored[m2.id].gp_a, scored[m2.id].mp_a} == {2.0, 1.0}
      assert TeamStandings.match_played?(scored[m1.id])

      standings = TeamStandings.standings(Repo.reload!(t))
      assert Enum.map(standings, & &1.mp) == [2.0, 1.0, 1.0, 0.0]
      assert hd(standings).gp == 3.5

      assert %{number: 2} = pair_next!(t)
    end

    test "a match score is written onto the boards and scores like them" do
      {t, _} = swiss(4)
      pair_next!(t)
      [{m1, _}, {m2, _}] = matches(t, 1)

      assert {:ok, _} = TeamMatches.set_match_score(t, m1, 2.5, 1.5)
      assert {:ok, _} = TeamMatches.set_match_score(t, m2, 0, 4)

      m1 = Repo.reload!(m1)
      assert {m1.match_score_a, m1.match_score_b} == {2.5, 1.5}
      assert TeamMatches.match_score?(m1)

      [{_, b1}, {_, b2}] = matches(t, 1)
      # One win for team A on board 1, three draws.
      assert Enum.map(b1, & &1.result) == ~w(1-0 1/2-1/2 1/2-1/2 1/2-1/2)
      # Team B wins every board: Black on the odd boards, White on the even.
      assert Enum.map(b2, & &1.result) == ~w(0-1 1-0 0-1 1-0)

      scored = t |> TeamStandings.matches() |> Map.new(&{&1.match_id, &1})
      assert {scored[m1.id].gp_a, scored[m1.id].gp_b, scored[m1.id].mp_a} == {2.5, 1.5, 2.0}
      assert {scored[m2.id].gp_a, scored[m2.id].gp_b, scored[m2.id].mp_b} == {0.0, 4.0, 2.0}
      assert scored[m1.id].match_score == {2.5, 1.5}

      # The round is complete: the next one pairs.
      assert %{number: 2} = pair_next!(t)
    end

    test "a board of a match decided by its score cannot be changed on its own" do
      {t, _} = swiss(4)
      pair_next!(t)
      [{m1, [board | _]} | _] = matches(t, 1)
      {:ok, _} = TeamMatches.set_match_score(t, m1, 3, 1)

      assert {:error, :match_score_set} =
               Tournaments.update_pairing_result(Repo.reload!(board), "0-1")

      assert {:error, :match_score_set} =
               TeamMatches.forfeit_match(t, Repo.reload!(m1), m1.team_a_id)

      assert {:ok, _} = TeamMatches.clear_match_score(t, Repo.reload!(m1))
      [{_, boards} | _] = matches(t, 1)
      assert Enum.all?(boards, &(&1.result == ""))
      assert {:ok, _} = Tournaments.update_pairing_result(hd(boards), "0-1")
    end

    test "a match score is refused when it does not add up, when players sit, or when line-ups are required" do
      {t, _} = swiss(4)
      pair_next!(t)
      [{m1, _} | _] = matches(t, 1)

      assert {:error, :bad_score} = TeamMatches.set_match_score(t, m1, 3, 3)
      assert {:error, :bad_score} = TeamMatches.set_match_score(t, m1, 2.25, 1.75)
      assert {:error, :bad_score} = TeamMatches.set_match_score(t, m1, -1, 5)

      {t2, _} =
        team_swiss([{"A", [2100]}, {"B", [2000]}, {"C", []}, {"D", []}],
          boards: 2,
          rounds: 3,
          team_lineups: "optional"
        )

      pair_next!(t2)

      seated =
        t2
        |> matches(1)
        |> Enum.find(fn {_m, boards} -> Enum.any?(boards, & &1.white_player_id) end)
        |> elem(0)

      assert {:error, :players_seated} = TeamMatches.set_match_score(t2, seated, 1, 1)

      {t3, _} = team_swiss([{"A", [2100]}, {"B", [2000]}], boards: 1, rounds: 1)
      pair_next!(t3)
      [{m3, _}] = matches(t3, 1)
      assert {:error, :not_optional} = TeamMatches.set_match_score(t3, m3, 1, 0)
    end
  end

  describe "a team absent as a team" do
    test "a team Swiss leaves it out of that round" do
      {t, [a | _]} = swiss(5)
      {:ok, _} = Tournaments.set_team_absent(t, a, 1, true)
      pair_next!(t)

      paired =
        t |> matches(1) |> Enum.flat_map(fn {m, _} -> [m.team_a_id, m.team_b_id] end)

      refute a.id in paired
      assert length(paired) == 4
      # Not the bye either: four teams play, none sits out on a bye.
      refute Repo.exists?(from m in Match, where: is_nil(m.team_b_id))

      # A round already paired cannot be changed this way.
      assert {:error, :round_paired} = Tournaments.set_team_absent(t, Repo.reload!(a), 1, false)
    end

    test "a team round robin gives its boards to the opponent, and a match both miss is a double forfeit" do
      {t, [a, b, _c, _d]} = rr(4)
      {:ok, _} = Tournaments.set_team_absent(t, a, 1, true)
      {:ok, _} = Tournaments.set_team_absent(t, b, 2, true)
      {:ok, a} = Tournaments.set_team_absent(t, Repo.reload!(a), 2, true)
      assert a.absent_rounds == [1, 2]
      t = pair_all!(t)

      scored = t |> TeamStandings.matches() |> Enum.reject(& &1.bye?)

      r1 = Enum.find(scored, &(&1.round == 1 and a.id in [&1.team_a_id, &1.team_b_id]))
      a_side? = r1.team_a_id == a.id
      assert Enum.all?(r1.boards, &(&1.pairing.result in ~w(1-0FF 0-1FF)))
      assert if(a_side?, do: {r1.gp_a, r1.gp_b}, else: {r1.gp_b, r1.gp_a}) == {0.0, 4.0}
      refute TeamStandings.match_played?(r1)

      r2 =
        Enum.find(
          scored,
          &(&1.round == 2 and MapSet.new([&1.team_a_id, &1.team_b_id]) == MapSet.new([a.id, b.id]))
        )

      if r2 do
        assert r2.double_forfeit?
        assert Enum.all?(r2.boards, &(&1.pairing.result == "0-0FF"))
        assert {r2.mp_a, r2.mp_b} == {0.0, 0.0}
      end
    end
  end

  describe "line-ups after pairing" do
    test "an optional line-up may leave a gap, and both sides may stay empty" do
      {t, [a, b]} =
        team_swiss([{"A", [2100, 2000, 1900]}, {"B", [1800]}],
          boards: 3,
          rounds: 1,
          team_lineups: "optional"
        )

      pair_next!(t)
      [{m, _}] = matches(t, 1)
      roster_a = Tournaments.team_roster(t.id, a.id) |> Enum.map(& &1.id)
      [b1] = Tournaments.team_roster(t.id, b.id) |> Enum.map(& &1.id)

      {lineup_a, lineup_b} =
        if m.team_a_id == a.id,
          do: {[Enum.at(roster_a, 0), nil, Enum.at(roster_a, 2)], [nil, nil, b1]},
          else: {[nil, nil, b1], [Enum.at(roster_a, 0), nil, Enum.at(roster_a, 2)]}

      assert {:ok, _} = TeamMatches.set_lineups(t, m, lineup_a, lineup_b)
      [{_, boards}] = matches(t, 1)
      assert length(boards) == 3
      assert Enum.all?(boards, &(&1.result == ""))
      assert Enum.at(boards, 1) |> then(&{&1.white_player_id, &1.black_player_id}) == {nil, nil}

      assert {:ok, _} =
               TeamMatches.set_lineups(t, Repo.reload!(m), [nil, nil, nil], [nil, nil, nil])

      [{_, boards}] = matches(t, 1)
      assert length(boards) == 3
      assert Enum.all?(boards, &is_nil(&1.white_player_id))
    end
  end

  describe "the TRF report" do
    test "an empty board is no game; 310 still carries the match and game points; 330 the forfeit" do
      {t, [a | _]} = swiss(4, rounds: 2)
      pair_next!(t)
      [{m1, _}, {_m2, b2}] = matches(t, 1)
      {:ok, _} = TeamMatches.set_match_score(t, m1, 2.5, 1.5)
      for p <- b2, do: {:ok, _} = Tournaments.update_pairing_result(p, "1/2-1/2")

      {:ok, _} = Tournaments.set_team_absent(t, Repo.reload!(a), 2, true)
      pair_next!(t)

      for {_m, boards} <- matches(t, 2),
          p <- boards,
          do: {:ok, _} = Tournaments.update_pairing_result(p, "1-0")

      t = Repo.reload!(t)
      {:ok, text} = TrfExport.export(t)
      lines = String.split(text, ["\r\n", "\n"])

      refute Enum.any?(lines, &String.starts_with?(&1, "001 "))

      recs = Enum.filter(lines, &String.starts_with?(&1, "310 "))
      assert length(recs) == 4

      standings = t |> TeamStandings.standings() |> Map.new(&{&1.team.pairing_number, &1})

      for rec <- recs do
        number = rec |> String.slice(4, 3) |> String.trim() |> String.to_integer()
        mp = rec |> String.slice(54, 6) |> String.trim() |> Float.parse() |> elem(0)
        gp = rec |> String.slice(61, 6) |> String.trim() |> Float.parse() |> elem(0)
        assert {mp, gp} == {standings[number].mp, standings[number].gp}
        # No players, no rating: the strength factor is blank.
        assert rec |> String.slice(47, 6) |> String.trim() == ""
      end
    end

    test "a match won by forfeit, its boards nobody's, is a 330 record" do
      {t, [a, b, c, d]} = rr(4)
      {:ok, _} = Tournaments.set_team_absent(t, a, 1, true)
      t = pair_all!(t)
      # FIDE mode enters results round by round; this test is about the file.
      {:ok, t} = Tournaments.leave_fide_mode(t)

      for r <- 1..t.rounds_count,
          {_m, boards} <- matches(t, r),
          p <- boards,
          p.result == "",
          do: {:ok, _} = Tournaments.update_pairing_result(p, "1/2-1/2")

      {:ok, text} = TrfExport.export(Repo.reload!(t))

      forfeits =
        text |> String.split(["\r\n", "\n"]) |> Enum.filter(&String.starts_with?(&1, "330 "))

      numbers = Map.new([a, b, c, d], &{&1.id, Repo.reload!(&1).pairing_number})
      a_no = numbers[a.id]

      assert [line] = forfeits
      assert String.slice(line, 7, 3) |> String.trim() == "1"
      white = line |> String.slice(11, 3) |> String.trim() |> String.to_integer()
      black = line |> String.slice(15, 3) |> String.trim() |> String.to_integer()
      assert a_no in [white, black]
      # The present team won it: "+-" when it had White on board 1.
      assert String.slice(line, 4, 2) == if(white == a_no, do: "-+", else: "+-")
    end
  end

  describe "the JSON backup" do
    test "the setting, the match scores, team absences and typed ratings survive a round trip" do
      {t, [a | _]} = swiss(4, rounds: 3)
      {:ok, _} = Tournaments.update_team(a, %{"rating_override" => "2150"})
      {:ok, _} = Tournaments.set_team_absent(t, Repo.reload!(a), 3, true)
      pair_next!(t)
      [{m1, _}, {_m2, b2}] = matches(t, 1)
      {:ok, _} = TeamMatches.set_match_score(t, m1, 3.5, 0.5)
      for p <- b2, do: {:ok, _} = Tournaments.update_pairing_result(p, "0-1")

      t = Repo.reload!(t)
      envelope = TournamentExport.export_tournament(t)
      assert {:ok, [imported]} = TournamentImport.import(envelope, user_scope())
      imported = Repo.reload!(imported)

      assert imported.team_lineups == "optional"
      assert imported.team_rating_method == "olympiad"

      by_name = fn tid -> tid |> Tournaments.list_teams() |> Map.new(&{&1.name, &1}) end
      teams = by_name.(imported.id)
      assert teams["T1"].rating_override == 2150
      assert teams["T1"].absent_rounds == [3]

      [match_score] =
        Repo.all(
          from m in Match,
            join: r in assoc(m, :round),
            where: r.tournament_id == ^imported.id and not is_nil(m.match_score_a),
            select: {m.match_score_a, m.match_score_b}
        )

      assert match_score == {3.5, 0.5}

      summary = fn tournament ->
        tournament
        |> TeamStandings.standings()
        |> Enum.map(&{&1.team.name, &1.rank, &1.mp, &1.gp})
      end

      assert summary.(imported) == summary.(t)
    end
  end

  describe "with required line-ups" do
    test "a match neither team can field anybody for is a double forfeit" do
      {t, [a, b, _c, _d]} =
        team_round_robin([{"A", []}, {"B", []}, {"C", [1800]}, {"D", [1700]}],
          boards: 2,
          round_dates: @dates
        )

      t = pair_all!(t)

      m =
        t
        |> TeamStandings.matches()
        |> Enum.find(&(MapSet.new([&1.team_a_id, &1.team_b_id]) == MapSet.new([a.id, b.id])))

      assert m.boards == []
      assert m.double_forfeit?
      assert {m.mp_a, m.mp_b} == {0.0, 0.0}
    end

    test "a double forfeit written by the pairing does not bring its round into the standings early" do
      {t, [_t1, t2, _t3, t4]} =
        team_round_robin(
          [
            {"T1", [2000, 1990]},
            {"T2", [1900, 1890]},
            {"T3", [1800, 1790]},
            {"T4", [1700, 1690]}
          ],
          boards: 2,
          round_dates: @dates
        )

      # Berger round 3 of four teams is 2-4 and 3-1.
      {:ok, _} = Tournaments.set_team_absent(t, t2, 3, true)
      {:ok, _} = Tournaments.set_team_absent(t, t4, 3, true)
      t = pair_all!(t)

      assert t |> TeamStandings.matches() |> Enum.any?(&(&1.round == 3 and &1.double_forfeit?))

      for {_m, boards} <- matches(t, 1),
          p <- boards,
          do: {:ok, _} = Tournaments.update_pairing_result(p, "1/2-1/2")

      standings = t |> Repo.reload!() |> TeamStandings.standings()
      assert Enum.all?(standings, &(&1.played == 1))
    end

    test "a match forfeited by decision to a team with nobody seated is that team's win" do
      {t, [a, _b, c, _d]} =
        team_round_robin([{"A", []}, {"B", []}, {"C", [1800]}, {"D", [1700]}],
          boards: 2,
          round_dates: @dates
        )

      t = pair_all!(t)
      {:ok, t} = Tournaments.leave_fide_mode(t)

      {match, round} =
        Enum.find_value(1..t.rounds_count, fn r ->
          t
          |> matches(r)
          |> Enum.find(fn {m, _} ->
            MapSet.new([m.team_a_id, m.team_b_id]) == MapSet.new([a.id, c.id])
          end)
          |> case do
            nil -> nil
            {m, _} -> {m, r}
          end
        end)

      {:ok, _} = TeamMatches.forfeit_match(t, match, a.id)
      scored = t |> TeamStandings.matches() |> Enum.find(&(&1.match_id == match.id))
      a_side? = scored.team_a_id == a.id
      mp = if a_side?, do: {scored.mp_a, scored.mp_b}, else: {scored.mp_b, scored.mp_a}
      assert mp == {2.0, 0.0}

      # Every other board gets a result so the whole event can be reported.
      for r <- 1..t.rounds_count, {_m, boards} <- matches(t, r), p <- boards, p.result == "" do
        {:ok, _} = Tournaments.update_pairing_result(p, "1/2-1/2")
      end

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      a_no = Repo.reload!(a).pairing_number

      assert Enum.any?(
               String.split(text, ["
", "
"]),
               &(String.starts_with?(&1, "330 ") and
                   String.slice(&1, 7, 3) |> String.trim() == "#{round}" and
                   String.contains?(&1, String.pad_leading("#{a_no}", 3)))
             )
    end
  end

  describe "the setting" do
    test "locks once round 1 is paired" do
      {t, _} = swiss(4)
      pair_next!(t)

      assert {:error, :locked_after_pairing} =
               Tournaments.update_tournament(Repo.reload!(t), %{"team_lineups" => "required"})
    end

    test "only takes its two values" do
      {t, _} = swiss(4)

      assert {:error, %Ecto.Changeset{}} =
               Tournaments.update_tournament(t, %{"team_lineups" => "sometimes"})
    end
  end
end
