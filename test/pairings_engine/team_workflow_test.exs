defmodule PairingsEngine.TeamWorkflowTest do
  @moduledoc """
  The team workflow (docs/team-tournaments.md): line-ups entered after the
  pairing, roster locks, board colours, a team's withdrawal, the double
  forfeit, the team Swiss bye's value, the team tie-break catalogue, Keizer
  refused for a team event, and what the TRF report says about each.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{
    Compliance,
    Repo,
    TeamMatches,
    TeamStandings,
    Tiebreaks,
    TournamentExport,
    TournamentImport,
    Tournaments,
    TrfExport,
    TrfImport
  }

  alias PairingsEngine.Tournaments.{Match, Pairing, Player, Tournament}

  defp teams(n, boards \\ 2) do
    for i <- 1..n, do: {"T#{i}", Enum.map(1..boards, &(2000 - i * 10 - &1))}
  end

  defp team(t, name), do: t.id |> Tournaments.list_teams() |> Enum.find(&(&1.name == name))

  defp player(t, name),
    do: Repo.one!(from p in Player, where: p.tournament_id == ^t.id and p.name == ^name)

  defp names(t, ids) do
    by_id = t.id |> Tournaments.list_players() |> Map.new(&{&1.id, &1.name})
    Enum.map(ids, &Map.get(by_id, &1))
  end

  defp fill_round!(t, number) do
    Tournaments.get_round(t.id, number).pairings
    |> Enum.filter(&(&1.result == ""))
    |> Enum.each(fn p -> {:ok, _} = Tournaments.update_pairing_result(p, "1-0") end)
  end

  # FIDE wants a date for every round in a TRF.
  defp dated!(t) do
    t
    |> Repo.reload!()
    |> Ecto.Changeset.change(
      start_date: "2026-09-01",
      end_date: "2026-09-05",
      round_dates: Enum.map(1..t.rounds_count, &"2026-09-0#{&1}")
    )
    |> Repo.update!()
  end

  defp user_scope do
    user =
      Repo.insert!(%PairingsEngine.Accounts.User{
        email: "teamwf#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    PairingsEngine.Accounts.Scope.for_user(user)
  end

  # A two-team, three-board round robin with a reserve on each team: A has
  # A 1..A 4, B has B 1..B 4; boards 1-3 seated from the rosters.
  defp two_team_match do
    {t, _} =
      team_round_robin([{"A", [2100, 2000, 1900, 1800]}, {"B", [2050, 1950, 1850, 1750]}],
        boards: 3,
        rounds_count: 1
      )

    t = pair_all!(t)
    {match, _boards} = match_between(t, 1, "A", "B")
    {t, match}
  end

  describe "line-ups (A1)" do
    test "the default line-up is what the pairing seated" do
      {t, match} = two_team_match()
      lineups = TeamMatches.lineups(t, match)

      assert names(t, lineups.a) == ["A 1", "A 2", "A 3"]
      assert names(t, lineups.b) == ["B 1", "B 2", "B 3"]
      assert TeamMatches.default_lineup(t, match.team_a_id, 1) == lineups.a
    end

    test "a changed line-up rewrites the match's boards, the reserve moving up" do
      {t, match} = two_team_match()
      a = Enum.map(["A 1", "A 3", "A 4"], &player(t, &1).id)
      b = Enum.map(["B 1", "B 2"], &player(t, &1).id) ++ [nil]

      assert {:ok, _} = TeamMatches.set_lineups(t, match, a, b)

      lineups = TeamMatches.lineups(t, match)
      assert names(t, lineups.a) == ["A 1", "A 3", "A 4"]
      assert names(t, lineups.b) == ["B 1", "B 2", nil]

      # Board 3: A (team A has White on odd boards) against an empty seat.
      board3 =
        Repo.one!(from p in Pairing, where: p.match_id == ^match.id and p.board == 3)

      assert board3.result == "1-0FF"
      assert board3.black_player_id == nil
      # The reserve now has an individual pairing number for the TRF.
      assert player(t, "A 4").pairing_number
    end

    test "players keep the roster's board order" do
      {t, match} = two_team_match()
      a = Enum.map(["A 2", "A 1", "A 3"], &player(t, &1).id)
      b = TeamMatches.lineups(t, match).b

      assert {:error, {:board_order, upper, lower}} = TeamMatches.set_lineups(t, match, a, b)
      assert {upper.name, lower.name} == {"A 2", "A 1"}
    end

    test "a gap, a player twice, a stranger and an unavailable player are refused" do
      {t, match} = two_team_match()
      b = TeamMatches.lineups(t, match).b
      a1 = player(t, "A 1").id

      assert {:error, :gap} = TeamMatches.set_lineups(t, match, [a1, nil, player(t, "A 3").id], b)
      assert {:error, {:twice, _}} = TeamMatches.set_lineups(t, match, [a1, a1, nil], b)

      assert {:error, {:not_on_team, _}} =
               TeamMatches.set_lineups(t, match, [player(t, "B 4").id, nil, nil], b)

      player(t, "A 4") |> Ecto.Changeset.change(absent_rounds: "1") |> Repo.update!()

      assert {:error, {:unavailable, %{name: "A 4"}}} =
               TeamMatches.set_lineups(
                 t,
                 match,
                 [a1, player(t, "A 2").id, player(t, "A 4").id],
                 b
               )

      assert {:error, :no_players} =
               TeamMatches.set_lineups(t, match, [nil, nil, nil], [nil, nil, nil])
    end

    test "the line-ups lock once a result of the match is entered" do
      {t, match} = two_team_match()
      lineups = TeamMatches.lineups(t, match)
      {_m, [first | _]} = match_between(t, 1, "A", "B")
      {:ok, _} = Tournaments.update_pairing_result(first, "1-0")

      refute TeamMatches.lineup_open?(Repo.reload!(match))

      assert {:error, :match_started} =
               TeamMatches.set_lineups(t, Repo.reload!(match), lineups.a, lineups.b)
    end
  end

  describe "board colours (B3)" do
    test "a new and an existing tournament keep FIDE's convention" do
      {t, match} = two_team_match()
      assert t.team_board_colours == "fide"
      {_m, boards} = match_between(t, 1, "A", "B")
      a = team(t, "A").id
      assert match.team_a_id == a
      # Team A White on boards 1 and 3, Black on 2.
      assert Enum.map(boards, &player_team(&1.white_player_id)) == [a, match.team_b_id, a]
      assert {:error, :not_home_and_away} = TeamMatches.swap_home(t, match)
    end

    test "league colours: the home team can be swapped before the match starts" do
      {t, _} =
        team_round_robin([{"A", [2100, 2000]}, {"B", [2050, 1950]}],
          boards: 2,
          rounds_count: 1,
          team_board_colours: "home"
        )

      t = pair_all!(t)
      {match, _} = match_between(t, 1, "A", "B")
      a = team(t, "A").id
      b = team(t, "B").id

      assert {:ok, _} = TeamMatches.swap_home(t, match)
      swapped = Repo.reload!(match)
      assert {swapped.team_a_id, swapped.team_b_id} == {b, a}

      {_m, boards} = match_between(t, 1, "A", "B")
      assert Enum.map(boards, &player_team(&1.white_player_id)) == [b, a]
    end

    test "the setting locks once round 1 is paired" do
      {t, _match} = two_team_match()
      assert :team_board_colours in Tournaments.locked_fields(t)
    end
  end

  defp player_team(id), do: Repo.get!(Player, id).team_id

  describe "roster locks (B2)" do
    test "FIDE mode, after round 1: no reordering or moving, a new reserve can be added" do
      {t, _} = two_team_match()
      assert Compliance.fide_mode?(t)
      assert Tournaments.roster_locked?(t)

      assert {:error, :roster_locked_in_fide_mode} =
               Tournaments.move_player_board(t, player(t, "A 2"), :up)

      assert {:error, :roster_locked_in_fide_mode} =
               Tournaments.set_player_team(t, player(t, "A 1"), team(t, "B"))

      # Seated: cannot leave the team.
      assert {:error, :roster_locked_in_fide_mode} =
               Tournaments.set_player_team(t, player(t, "A 1"), nil)

      # Never seated (the reserve): can be taken off again.
      assert {:ok, _} = Tournaments.set_player_team(t, player(t, "A 4"), nil)

      {:ok, newcomer} =
        Tournaments.create_player(t.id, %{"name" => "New", "fide_rating" => "1500"})

      assert {:ok, added} = Tournaments.set_player_team(t, newcomer, team(t, "A"))
      assert added.board_order == 4
    end

    test "outside FIDE mode it is allowed, with a warning" do
      {t, _} = two_team_match()
      {:ok, t} = Tournaments.leave_fide_mode(t)

      refute Tournaments.roster_locked?(t)
      assert Tournaments.roster_change_warning?(t)
      assert {:ok, _} = Tournaments.move_player_board(t, player(t, "A 2"), :up)
    end

    test "the TRF lists a moved player under the team they played for" do
      {t, _} = two_team_match()
      fill_round!(t, 1)
      {:ok, t} = Tournaments.leave_fide_mode(t)
      moved = player(t, "A 1")
      {:ok, _} = Tournaments.set_player_team(t, moved, team(t, "B"))

      {:ok, text} = TrfExport.export(dated!(t), nil)
      lines = String.split(text, "\r\n")
      [a_line] = Enum.filter(lines, &(&1 =~ ~r/^310 .{3} A\s/))
      [b_line] = Enum.filter(lines, &(&1 =~ ~r/^310 .{3} B\s/))

      # A's line lists the player (after its own roster); B's does not.
      assert moved.pairing_number in ranks(a_line)
      refute moved.pairing_number in ranks(b_line)
    end
  end

  # The starting ranks of a `310` line: 4-column fields from column 74.
  defp ranks(line) do
    line
    |> String.slice(73..-1//1)
    |> String.split(" ", trim: true)
    |> Enum.map(&String.to_integer/1)
  end

  describe "a team that withdraws (A4)" do
    defp four_team_rr(opts \\ []) do
      {t, _} = team_round_robin(teams(4), [boards: 2, rounds_count: 3] ++ opts)
      pair_all!(t)
    end

    test "one action: players withdrawn, later matches forfeited, and back again" do
      t = four_team_rr()
      fill_round!(t, 1)
      t4 = team(t, "T4")

      assert {:ok, %{forfeited: forfeited}} = Tournaments.withdraw_team(t, t4, 2)
      assert length(forfeited) == 2
      assert Enum.all?(Tournaments.team_roster(t.id, t4.id), & &1.forfeit)

      for m <- forfeited do
        assert m.forfeited_to_team_id != t4.id
      end

      assert {:error, :already_withdrawn} = Tournaments.withdraw_team(t, Repo.reload!(t4), 2)

      assert {:ok, _} = Tournaments.reinstate_team(t, Repo.reload!(t4))
      refute Enum.any?(Tournaments.team_roster(t.id, t4.id), & &1.forfeit)

      assert Repo.all(
               from m in Match,
                 where:
                   m.id in ^Enum.map(forfeited, & &1.id) and not is_nil(m.forfeited_to_team_id)
             ) == []
    end

    test "a team round robin can annul a withdrawal under half its matches" do
      t = four_team_rr()
      fill_round!(t, 1)
      t4 = team(t, "T4")
      {:ok, _} = Tournaments.withdraw_team(t, t4, 2)
      for n <- 2..3, do: fill_round!(t, n)

      # Default: the results stand.
      t = Repo.reload!(t)
      refute Enum.any?(TeamStandings.standings(t), & &1.annulled?)

      {:ok, t} = Tournaments.update_tournament(t, %{"team_withdrawal_annul" => "true"})
      entries = TeamStandings.standings(t)
      last = List.last(entries)

      # 1 match played of 3 scheduled: under half - annulled, listed last.
      assert last.team.id == t4.id and last.annulled?
      assert last.mp == 0.0
      # T4's round-1 opponent no longer has those match points.
      others = Enum.reject(entries, & &1.annulled?)
      assert Enum.all?(others, fn e -> Enum.all?(e.records, &(&1.opponent_id != t4.id)) end)
    end
  end

  describe "the double forfeit (A5)" do
    test "both teams lose the match, and the decision can be withdrawn" do
      {t, _} = team_swiss(teams(4), rounds: 3)
      pair_next!(t)
      t = Repo.reload!(t)
      {match, _} = match_between(t, 1, "T1", "T3")

      assert {:ok, _} = TeamMatches.double_forfeit(t, match)
      {_m, boards} = match_between(t, 1, "T1", "T3")
      assert Enum.all?(boards, &(&1.result == "0-0FF"))

      scored = Enum.find(TeamStandings.matches(t), &(&1.match_id == match.id))
      assert {scored.mp_a, scored.mp_b} == {0.0, 0.0}

      t1 = Enum.find(TeamStandings.standings(t), &(&1.team.name == "T1"))
      assert {t1.won, t1.drawn, t1.lost} == {0, 0, 1}

      assert {:error, :already_forfeited} = TeamMatches.double_forfeit(t, Repo.reload!(match))
      assert {:ok, _} = TeamMatches.withdraw_forfeit(t, Repo.reload!(match))
      refute Repo.reload!(match).double_forfeit
      {_m, boards} = match_between(t, 1, "T1", "T3")
      assert Enum.all?(boards, &(&1.result == ""))
    end

    test "a match with a game played is not a double forfeit" do
      {t, _} = team_swiss(teams(4), rounds: 3)
      pair_next!(t)
      t = Repo.reload!(t)
      enter!(t, 1, "T1", "T3", ["1-0"])
      {match, _} = match_between(t, 1, "T1", "T3")
      assert {:error, :games_played} = TeamMatches.double_forfeit(t, match)
    end

    test "exported as a 330 `--` and read back as a double forfeit" do
      {t, _} = team_swiss(teams(4), rounds: 2)
      pair_next!(t)
      t = Repo.reload!(t)
      {match, _} = match_between(t, 1, "T1", "T3")
      {:ok, _} = TeamMatches.double_forfeit(t, match)
      enter!(t, 1, "T2", "T4", ["1-0", "0-1"])

      {:ok, text} = TrfExport.export(dated!(t), nil)
      assert Enum.any?(String.split(text, "\r\n"), &String.starts_with?(&1, "330 --"))

      {:ok, imported, _warnings} = TrfImport.import_text(text)
      assert Tournament.paired_as_teams?(imported)
      round = Tournaments.get_round(imported.id, 1)
      assert Enum.count(Tournaments.list_matches(round.id), & &1.double_forfeit) == 1
    end

    test "a backup keeps it" do
      {t, _} = team_swiss(teams(4), rounds: 2)
      pair_next!(t)
      t = Repo.reload!(t)
      {match, _} = match_between(t, 1, "T1", "T3")
      {:ok, _} = TeamMatches.double_forfeit(t, match)

      {:ok, [restored]} =
        TournamentImport.import(TournamentExport.export_tournament(t), user_scope())

      round = Tournaments.get_round(restored.id, 1)
      assert Enum.count(Tournaments.list_matches(round.id), & &1.double_forfeit) == 1
    end
  end

  describe "the team Swiss bye's value (A7)" do
    defp odd_swiss(attrs) do
      {t, _} = team_swiss(teams(3), [rounds: 2] ++ attrs)
      pair_next!(t)
      Repo.reload!(t)
    end

    test "by default a drawn match's points" do
      t = odd_swiss([])
      bye = Enum.find(TeamStandings.matches(t), & &1.bye?)
      assert {bye.mp_a, bye.gp_a} == {1.0, 1.0}
    end

    test "a set value scores the bye, and goes to and comes back from the TRF" do
      t = odd_swiss(team_pab_match_points: 2.0, team_pab_game_points: 1.5)
      bye = Enum.find(TeamStandings.matches(t), & &1.bye?)
      assert {bye.mp_a, bye.gp_a} == {2.0, 1.5}

      for m <- Tournaments.list_matches(Tournaments.get_round(t.id, 1).id), m.team_b_id do
        {_m, boards} = match_between(t, 1, team_name(t, m.team_a_id), team_name(t, m.team_b_id))
        Enum.each(boards, &Tournaments.update_pairing_result(&1, "1-0"))
      end

      {:ok, text} = TrfExport.export(dated!(t), nil)
      lines = String.split(text, "\r\n")
      assert Enum.any?(lines, &(String.starts_with?(&1, "362") and &1 =~ "P 2.0"))
      assert Enum.any?(lines, &String.starts_with?(&1, "320  2.0  1.5"))

      {:ok, imported, _} = TrfImport.import_text(text)
      assert {imported.team_pab_match_points, imported.team_pab_game_points} == {2.0, 1.5}
    end

    test "a file whose bye pays a draw imports as the default" do
      t = odd_swiss([])
      fill_round!(t, 1)
      {:ok, text} = TrfExport.export(dated!(t), nil)
      {:ok, imported, _} = TrfImport.import_text(text)
      assert {imported.team_pab_match_points, imported.team_pab_game_points} == {nil, nil}
    end
  end

  defp team_name(t, id),
    do: t.id |> Tournaments.list_teams() |> Enum.find(&(&1.id == id)) |> Map.get(:name)

  describe "team tie-breaks (A6)" do
    test "the catalogue offers what Ainalrami computes for teams; the defaults are unchanged" do
      codes = Tiebreaks.selectable("team-swiss") |> Enum.map(& &1.code)

      for code <- ~w(BHC1 MBH BH:GP EGMSB EGGSB EDE TBR BBE SSSC), do: assert(code in codes)
      assert Tiebreaks.fide_defaults("team-swiss") == ~w(MP GP DE BB SB)
    end

    test "each new code computes" do
      codes = ~w(MP BHC1 BHC2 MBH BH:GP EGMSB EGGSB EDE TBR BBE SSSC)
      {t, _} = team_swiss(teams(4), rounds: 2, tiebreaks: codes)
      pair_next!(t)
      fill_round!(Repo.reload!(t), 1)
      [first | _] = TeamStandings.standings(Repo.reload!(t))

      for code <- codes, do: assert(is_float(first.tiebreaks[code]), code)
    end

    test "Buchholz cuts are dropped in a round robin" do
      t = %Tournament{
        type: "team-roundrobin",
        pairing_system: "round_robin",
        tiebreaks: ~w(MP BHC1 BH:GP)
      }

      assert TeamStandings.effective_tiebreaks(t) == ["MP"]
    end
  end

  describe "Keizer and teams (B4)" do
    test "a new team tournament cannot be Keizer" do
      assert {:error, changeset} =
               Tournaments.create_tournament(%{
                 "name" => "Team Keizer",
                 "type" => "team-swiss",
                 "pairing_system" => "keizer",
                 "rounds_count" => 5
               })

      assert [{:pairing_system, {_, opts}}] = changeset.errors
      assert opts[:validation] == :team_keizer
    end

    test "an existing one keeps working" do
      t =
        Repo.insert!(%Tournament{
          name: "Old team Keizer",
          type: "team-swiss",
          pairing_system: "keizer",
          rounds_count: 5
        })

      assert {:ok, _} = Tournaments.update_tournament(t, %{"name" => "Renamed"})
    end
  end

  describe "standings count the rounds reached" do
    # T2 fields one player on two boards: Pair all writes a forfeit on its
    # empty seat in every round at once.
    defp short_team_rr do
      {t, _} =
        team_round_robin(
          [{"T1", [2100, 2000]}, {"T2", [2050]}, {"T3", [2000, 1900]}, {"T4", [1950, 1850]}],
          boards: 2,
          rounds_count: 3
        )

      pair_all!(t)
    end

    defp gp(t, name),
      do: t |> TeamStandings.standings() |> Enum.find(&(&1.team.name == name)) |> Map.get(:gp)

    # A team's game points in the matches of rounds 1..round, as written.
    defp gp_through(t, name, round) do
      id = team(t, name).id

      t
      |> TeamStandings.matches(through_round: round)
      |> Enum.flat_map(fn m ->
        cond do
          m.team_a_id == id -> [m.gp_a]
          m.team_b_id == id -> [m.gp_b]
          true -> []
        end
      end)
      |> Enum.sum()
    end

    test "before any result, only the current round's forfeits count" do
      t = short_team_rr()
      # Round 1 is the current round: its empty-seat forfeit (to T2's
      # opponent) counts, the later rounds' do not.
      for name <- ~w(T1 T2 T3 T4), do: assert(gp(t, name) == gp_through(t, name, 1), name)
      assert Enum.sum(for name <- ~w(T1 T2 T3 T4), do: gp(t, name)) <= 1.0
    end

    test "a round counts once it is reached, and the TRF of round 1 says round 1" do
      t = short_team_rr()
      fill_round!(t, 1)
      after_one = for name <- ~w(T1 T2 T3 T4), into: %{}, do: {name, gp_through(t, name, 1)}

      # Round 2 is now current: its forfeits count, round 3's not yet.
      for name <- ~w(T1 T2 T3 T4) do
        assert gp(t, name) == gp_through(t, name, 2), name
      end

      {:ok, text} = TrfExport.export(dated!(t), [1])

      for line <- String.split(text, "\r\n"), String.starts_with?(line, "310") do
        name = line |> String.slice(8, 32) |> String.trim()
        gp = line |> String.slice(61, 6) |> String.trim() |> String.to_float()
        assert gp == after_one[name]
      end
    end
  end

  describe "the TRF report of a team event" do
    test "202 lists the tie-breaks in C.07's spelling" do
      {t, _} = team_swiss(teams(4), rounds: 2, tiebreaks: ~w(MP GP DE BB SB))
      pair_next!(t)
      fill_round!(Repo.reload!(t), 1)
      {:ok, text} = TrfExport.export(dated!(t), nil)
      [line] = text |> String.split("\r\n") |> Enum.filter(&String.starts_with?(&1, "202"))
      assert line =~ "MPTS"
      assert line =~ "BC"
      assert line =~ "SB:MP"
      refute line =~ ~r/\bBB\b/
    end

    test "ainalrami -c can check the standings of a team file with FIDE's default tie-breaks" do
      {t, _} = team_swiss(teams(5), rounds: 2)
      pair_next!(t)
      fill_round!(Repo.reload!(t), 1)
      {:ok, text} = TrfExport.export(dated!(t), nil)

      path =
        Path.join(System.tmp_dir!(), "team_wf_check_#{System.unique_integer([:positive])}.trf")

      File.write!(path, text)
      on_exit(fn -> File.rm(path) end)

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          ExUnit.CaptureIO.capture_io(:stderr, fn -> Ainalrami.CLI.run([path, "-c"]) end)
          |> IO.write()
        end)

      assert out =~ "standings: all 5 ranks follow"
    end

    test "152 is written for an individual event once the colour is known, and only then" do
      t =
        Repo.insert!(%Tournament{
          name: "Colour",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 1,
          initial_colour: "black"
        })

      for n <- 1..2,
          do:
            {:ok, _} =
              Tournaments.create_player(t.id, %{"name" => "P#{n}", "fide_rating" => "1800"})

      {:ok, text} = TrfExport.export(dated!(t), nil)
      assert "152 B" in String.split(text, "\r\n")

      {:ok, engine} = TrfExport.export(dated!(t), nil, dialect: :engine)
      assert "XXC black1" in String.split(engine, "\r\n")
      refute Enum.any?(String.split(engine, "\r\n"), &String.starts_with?(&1, "152"))

      lot = t |> Ecto.Changeset.change(initial_colour: "lot") |> Repo.update!()
      {:ok, text} = TrfExport.export(dated!(lot), nil)
      refute Enum.any?(String.split(text, "\r\n"), &String.starts_with?(&1, "152"))
    end

    test "310 match points are the file's rounds' and 152 says the initial colour" do
      {t, _} = team_swiss(teams(4), rounds: 2)
      pair_next!(t)
      fill_round!(Repo.reload!(t), 1)
      pair_next!(Repo.reload!(t))
      fill_round!(Repo.reload!(t), 2)
      t = Repo.reload!(t)

      {:ok, text} = TrfExport.export(dated!(t), [1])
      lines = String.split(text, "\r\n")
      after_one = TeamStandings.standings(t, through_round: 1)
      leader = hd(after_one)

      line =
        Enum.find(
          lines,
          &(String.starts_with?(&1, "310") and String.slice(&1, 8, 32) =~ leader.team.name)
        )

      assert String.slice(line, 54, 6) |> String.trim() |> String.to_float() == leader.mp
      assert Enum.any?(lines, &String.starts_with?(&1, "152 "))

      # Round 2 sent on its own: what round 2 earned, and no rank.
      {:ok, text} = TrfExport.export(dated!(t), [2])
      round2 = TeamStandings.matches(t) |> Enum.filter(&(&1.round == 2))

      for line <- String.split(text, "
"),
          String.starts_with?(line, "310") do
        no = line |> String.slice(4, 3) |> String.trim() |> String.to_integer()
        team = Enum.find(Tournaments.list_teams(t.id), &(&1.pairing_number == no))

        {mp, gp} =
          Enum.reduce(round2, {0.0, 0.0}, fn m, {mp, gp} ->
            cond do
              m.team_a_id == team.id -> {mp + (m.mp_a || 0.0), gp + m.gp_a}
              m.team_b_id == team.id -> {mp + (m.mp_b || 0.0), gp + m.gp_b}
              true -> {mp, gp}
            end
          end)

        assert line |> String.slice(54, 6) |> String.trim() |> String.to_float() == mp
        assert line |> String.slice(61, 6) |> String.trim() |> String.to_float() == gp
        assert line |> String.slice(68, 3) |> String.trim() == ""
      end
    end
  end
end
