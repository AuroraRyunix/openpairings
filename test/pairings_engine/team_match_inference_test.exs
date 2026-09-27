defmodule PairingsEngine.TeamMatchInferenceTest do
  @moduledoc """
  A team tournament exported to TRF and imported again gets its matches back
  (`PairingsEngine.TeamMatchInference`), and a file whose boards do not form
  clean matches is imported without guessing.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  import ExUnit.CaptureIO

  alias PairingsEngine.{Repo, TeamStandings, TeamMatches, Tournaments, TrfExport, TrfImport}
  alias PairingsEngine.Tournaments.{Match, Pairing, Player, Tournament}
  alias Ainalrami.{CLI, Trf}

  # Every result of a round, board by board, where none is recorded yet.
  defp fill_round!(t, number) do
    Tournaments.get_round(t.id, number).pairings
    |> Enum.filter(&(&1.result == ""))
    |> Enum.each(fn p ->
      result = Enum.at(["1-0", "1/2-1/2", "0-1", "1-0", "0-1"], rem(p.board + number, 5))
      {:ok, _} = Tournaments.update_pairing_result(p, result)
    end)
  end

  # Each round's matches, as a reader of the Pairings page sees them.
  defp summary(t) do
    names = t.id |> Tournaments.list_players() |> Map.new(&{&1.id, &1.name})
    teams = t.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1.name})

    for round <-
          Repo.all(
            from r in PairingsEngine.Tournaments.Round,
              where: r.tournament_id == ^t.id,
              order_by: r.number,
              preload: [:pairings]
          ) do
      matches =
        for m <- Tournaments.list_matches(round.id) do
          boards =
            round.pairings
            |> Enum.filter(&(&1.match_id == m.id))
            |> Enum.sort_by(& &1.board)
            |> Enum.map(
              &{&1.board, names[&1.white_player_id], names[&1.black_player_id], &1.result}
            )

          {m.board, teams[m.team_a_id], teams[m.team_b_id], boards}
        end

      {round.number, matches}
    end
  end

  defp standings(t) do
    t
    |> TeamStandings.standings()
    |> Enum.map(&{&1.team.name, &1.rank, &1.mp, &1.gp, &1.tiebreaks})
  end

  defp round_trip(t) do
    t = Repo.reload!(t)

    dates =
      for n <- 1..t.rounds_count,
          do: "2026-09-#{String.pad_leading(Integer.to_string(n), 2, "0")}"

    t =
      t
      |> Ecto.Changeset.change(
        start_date: hd(dates),
        end_date: List.last(dates),
        round_dates: dates
      )
      |> Repo.update!()

    {:ok, text} = TrfExport.export(t, nil)
    {:ok, imported, warnings} = TrfImport.import_text(text)
    {Repo.reload!(imported), Enum.map(warnings, & &1.text)}
  end

  describe "round trips" do
    test "a team round robin comes back with identical matches, byes, forfeits and standings" do
      {t, _} =
        team_round_robin(
          [
            {"Antwerp", [2200, 2100, 2000]},
            {"Brugge", [2150, 2050, 1950]},
            # Two players on a three-board team: board 3 is a forfeit win.
            {"Charleroi", [2100, 2000]},
            {"Deurne", [2050, 1950, 1850]},
            {"Eupen", [2000, 1900, 1800]}
          ],
          boards: 3,
          rounds_count: 5
        )

      t = pair_all!(t)
      for n <- 1..5, do: fill_round!(t, n)

      {imported, warnings} = round_trip(t)

      assert Tournament.team_round_robin?(imported)
      assert imported.team_boards == 3
      assert summary(imported) == summary(t)
      assert standings(imported) == standings(t)
      assert Enum.any?(warnings, &(&1 =~ "each round's matches were rebuilt"))
      # Five teams: every round has its Berger bye.
      assert Enum.all?(summary(imported), fn {_n, ms} -> Enum.any?(ms, &(elem(&1, 2) == nil)) end)
    end

    test "a team Swiss comes back with identical matches, pairs on by teams, and pairs the same next round" do
      {t, _} =
        team_swiss(
          for(i <- 1..5, do: {"T#{i}", [2100 - i * 20, 2000 - i * 20]}) ++ [{"Short", [1500]}],
          rounds: 5,
          tiebreaks: ~w(MP GP BH SB EMGSB)
        )

      for n <- 1..3 do
        pair_next!(t)
        fill_round!(Repo.reload!(t), n)
      end

      t = Repo.reload!(t)
      {imported, _warnings} = round_trip(t)

      assert imported.team_pairing_mode == "teams"
      assert summary(imported) == summary(t)
      assert standings(imported) == standings(t)

      pair_next!(t)
      pair_next!(imported)
      assert List.last(summary(imported)) == List.last(summary(t))
    end

    test "a team Swiss with an odd field reads the team without boards as the bye, and says so" do
      {t, _} = team_swiss(for(i <- 1..5, do: {"T#{i}", [2000 - i, 1900 - i]}), rounds: 3)

      for n <- 1..2 do
        pair_next!(t)
        fill_round!(Repo.reload!(t), n)
      end

      {imported, warnings} = round_trip(Repo.reload!(t))

      assert summary(imported) == summary(Repo.reload!(t))
      # This app's own export now writes TRF-2026's `320` record, so the bye
      # comes back from that record rather than being assumed.
      assert Enum.any?(
               warnings,
               &(&1 =~ "the file's 320 record gives it the pairing-allocated bye")
             )
    end
  end

  describe "TRF-2026 team records (310, 362, 320, 330)" do
    # A minimal TRF-2026 team-swiss file: three teams, two boards, one round
    # - "One" (2, 3; 1 a reserve who sat out) beats "Two" (4, 5) 1.5-0.5;
    # "Three" (6, 7) has no boards at all - not even a per-player `001` game
    # column for the round, the same shape this app's own export leaves a
    # team with nobody paired that round (`Pairing.trf_player_rows/2`),
    # rather than a `U` bye on each of its players (which reads as each
    # player having a board with no opponent, not as the team having none -
    # `TeamMatchInference.classify/2`). The `310` numbers are deliberately
    # not file order (Three is 1, One 2, Two 3), the same trick Ainalrami's
    # own `TrfTeamRecordsTest` uses, so a test that passed by coincidence of
    # matching order would fail here.
    defp trf26_team_data(extra_tournament \\ %{}) do
      g = fn opp, colour, result -> %{opponent_rank: opp, colour: colour, result: result} end
      none = %{opponent_rank: nil, colour: "-", result: ""}

      players = [
        {1, [none]},
        {2, [g.(4, "w", "1")]},
        {3, [g.(5, "b", "=")]},
        {4, [g.(2, "b", "0")]},
        {5, [g.(3, "w", "=")]},
        {6, []},
        {7, []}
      ]

      %{
        tournament:
          Map.merge(
            %{
              name: "Team records import",
              type: "Team-Swiss-System",
              number_of_rounds: 1,
              team_point_system: %{win: 3.0, draw: 1.0, loss: 0.0}
            },
            extra_tournament
          ),
        players:
          for {rank, games} <- players do
            %{rank: rank, name: "P#{rank}", points: 0.0, games: games}
          end,
        teams: [
          %{
            number: 2,
            name: "One",
            match_points: 3.0,
            game_points: 1.5,
            final_rank: 2,
            player_ranks: [1, 2, 3]
          },
          %{
            number: 3,
            name: "Two",
            match_points: 0.0,
            game_points: 0.5,
            final_rank: 3,
            player_ranks: [4, 5]
          },
          %{
            number: 1,
            name: "Three",
            match_points: 3.0,
            game_points: 2.0,
            final_rank: 1,
            player_ranks: [6, 7]
          }
        ]
      }
    end

    defp note_texts(warnings), do: for(%{kind: :note, text: text} <- warnings, do: text)

    test "362 sets the team match-point values" do
      {:ok, imported, _warnings} = trf26_team_data() |> Trf.serialize() |> TrfImport.import_text()

      assert imported.team_match_points_win == 3.0
      assert imported.team_match_points_draw == 1.0
      assert imported.team_match_points_loss == 0.0
    end

    test "a 320 record gives the pairing-allocated bye without guessing, even to 013's file order" do
      data =
        trf26_team_data(%{team_pab: %{match_points: 3.0, game_points: 2.0, teams: [1]}})

      {:ok, imported, warnings} =
        data |> Trf.serialize() |> TrfImport.import_text()

      assert Tournament.team_swiss?(imported)
      teams = imported.id |> Tournaments.list_teams() |> Map.new(&{&1.name, &1})

      round = Tournaments.get_round(imported.id, 1)
      matches = Tournaments.list_matches(round.id)
      bye_match = Enum.find(matches, &is_nil(&1.team_b_id))

      assert bye_match.team_a_id == teams["Three"].id

      texts = note_texts(warnings)
      assert Enum.any?(texts, &(&1 =~ "the file's 320 record gives it the pairing-allocated bye"))
      refute Enum.any?(texts, &(&1 =~ "assumed"))
      refute Enum.any?(texts, &(&1 =~ "taken to have had"))
    end

    # A file where "One" and "Two" both have no boards at all this round -
    # nothing in `data.players`' `games` references either - and a 4th and
    # 5th team ("Filler"/"Rival") play a genuine board so the round itself
    # still registers as paired (`TrfImport.paired_rounds_from_data/1`
    # needs at least one real result somewhere; a lone `U` on a boardless
    # team's own player would read as that team having a board with no
    # opponent, not as the team having none - the same reason
    # `trf26_team_data/1`'s "Three" carries no game entry at all).
    defp trf26_forfeit_data(forfeited_matches) do
      data = trf26_team_data(%{forfeited_matches: forfeited_matches})

      data =
        put_in(
          data.players,
          for %{rank: rank} = p <- data.players do
            if rank in 1..5, do: %{p | games: []}, else: p
          end
        )

      filler = %{
        rank: 8,
        name: "F1",
        points: 1.0,
        games: [%{opponent_rank: 9, colour: "w", result: "1"}]
      }

      rival = %{
        rank: 9,
        name: "F2",
        points: 0.0,
        games: [%{opponent_rank: 8, colour: "b", result: "0"}]
      }

      %{
        data
        | players: data.players ++ [filler, rival],
          teams:
            data.teams ++
              [
                %{number: 4, name: "Filler", player_ranks: [8]},
                %{number: 5, name: "Rival", player_ranks: [9]}
              ]
      }
    end

    test "a 330 record forfeits a match neither team has a board for" do
      data = trf26_forfeit_data([%{type: "+-", round: 1, white: 2, black: 3}])
      {:ok, imported, warnings} = data |> Trf.serialize() |> TrfImport.import_text()

      teams = imported.id |> Tournaments.list_teams() |> Map.new(&{&1.name, &1})
      round = Tournaments.get_round(imported.id, 1)
      match = Enum.find(Tournaments.list_matches(round.id), &(&1.team_b_id == teams["Two"].id))

      assert match.team_a_id == teams["One"].id
      assert match.forfeited_to_team_id == teams["One"].id

      boards =
        round.pairings |> Enum.filter(&(&1.match_id == match.id)) |> Enum.sort_by(& &1.board)

      assert boards != []
      assert Enum.all?(boards, &(&1.result == "1-0FF"))

      texts = note_texts(warnings)
      assert Enum.any?(texts, &(&1 =~ "the file's 330 record forfeits it to One"))
    end

    test "an unresolvable 330 (a double forfeit) is left exactly as it would be without one" do
      data = trf26_forfeit_data([%{type: "--", round: 1, white: 2, black: 3}])
      {:ok, imported, warnings} = data |> Trf.serialize() |> TrfImport.import_text()

      refute Tournament.paired_as_teams?(imported)
      texts = note_texts(warnings)
      assert Enum.any?(texts, &(&1 =~ "does not say which of them had the pairing-allocated bye"))
    end

    test "exports a 362, a 320 bye and 310 team numbers, ranks, match and game points" do
      {t, _} =
        team_swiss(for(i <- 1..5, do: {"T#{i}", [2000 - i, 1900 - i]}),
          rounds: 2,
          tiebreaks: ~w(MPTS GPTS)
        )

      pair_next!(t)
      fill_round!(Repo.reload!(t), 1)

      t =
        Repo.reload!(t)
        |> Ecto.Changeset.change(
          start_date: "2026-09-01",
          end_date: "2026-09-02",
          round_dates: ["2026-09-01", "2026-09-02"]
        )
        |> Repo.update!()

      {:ok, text} = TrfExport.export(t, nil)
      lines = String.split(text, "\r\n")

      assert Enum.any?(lines, &String.starts_with?(&1, "362"))
      assert Enum.any?(lines, &String.starts_with?(&1, "320"))
      assert Enum.count(lines, &String.starts_with?(&1, "310")) == 5

      # Ainalrami's own checker agrees the file's team ranks follow its
      # standings order - the same check `ainalrami -c` runs on a file an
      # arbiter submits.
      path =
        Path.join(
          System.tmp_dir!(),
          "team_export_check_#{System.unique_integer([:positive])}.trf"
        )

      File.write!(path, text)
      on_exit(fn -> File.rm(path) end)

      out =
        capture_io(fn -> capture_io(:stderr, fn -> CLI.run([path, "-c"]) end) |> IO.write() end)

      assert out =~ "standings: all 5 ranks follow"
    end
  end

  describe "files that do not form clean matches" do
    # A four-team round robin with one board of round `number` moved to a
    # player of a third team.
    defp tampered_round_robin(number) do
      {t, _} =
        team_round_robin(
          [{"A", [2100, 2000]}, {"B", [2050, 1950]}, {"C", [2000, 1900]}, {"D", [1950, 1850]}],
          rounds_count: 3
        )

      t = pair_all!(t)
      for n <- 1..3, do: fill_round!(t, n)
      mix_teams!(t, number)
      t
    end

    # Board 2 of match 1 gets a player of another match's team.
    defp mix_teams!(t, number) do
      round = Tournaments.get_round(t.id, number)
      [m1, m2 | _] = Tournaments.list_matches(round.id)
      board = Enum.find(round.pairings, &(&1.match_id == m1.id and rem(&1.board, 2) == 0))
      intruder = Enum.find(round.pairings, &(&1.match_id == m2.id and rem(&1.board, 2) == 0))

      Repo.update_all(from(p in Pairing, where: p.id == ^board.id),
        set: [black_player_id: intruder.black_player_id]
      )

      Repo.update_all(from(p in Pairing, where: p.id == ^intruder.id),
        set: [black_player_id: board.black_player_id]
      )
    end

    test "a round robin round with mixed teams is imported without matches, and the notice names it" do
      t = tampered_round_robin(2)
      {imported, warnings} = round_trip(t)

      [{1, r1}, {2, r2}, {3, r3}] = summary(imported)
      assert r1 != [] and r3 != []
      assert r2 == []
      assert r1 == summary(t) |> Enum.at(0) |> elem(1)

      assert Enum.any?(
               warnings,
               &(&1 =~ ~r/^Round 2: no matches were rebuilt - .* has boards against both/)
             )

      # Its games count for no team, and the Pairings page's list has them.
      round2 = Tournaments.get_round(imported.id, 2)
      assert length(TeamMatches.unattached_boards(imported, round2)) == 4
    end

    test "a team Swiss with one unclear round rebuilds no match and carries on player by player" do
      {t, _} = team_swiss(for(i <- 1..4, do: {"T#{i}", [2000 - i, 1900 - i]}), rounds: 3)

      for n <- 1..2 do
        pair_next!(t)
        fill_round!(Repo.reload!(t), n)
      end

      mix_teams!(Repo.reload!(t), 2)
      {imported, warnings} = round_trip(Repo.reload!(t))

      assert imported.team_pairing_mode == "players"
      refute Tournament.paired_as_teams?(imported)

      assert Repo.aggregate(
               from(m in Match,
                 join: r in assoc(m, :round),
                 where: r.tournament_id == ^imported.id
               ),
               :count
             ) == 0

      assert Enum.any?(
               warnings,
               &(&1 =~ "rounds 2" or &1 =~ "round 2 could not be read as matches")
             )

      assert Enum.any?(warnings, &(&1 =~ "continues player by player"))
      assert Enum.any?(warnings, &(&1 =~ ~r/^Round 2: .* has boards against both/))
    end

    test "colours that do not alternate down the boards are not a match" do
      {t, _} = team_round_robin([{"A", [2100, 2000]}, {"B", [2050, 1950]}], rounds_count: 1)
      t = pair_all!(t)
      fill_round!(t, 1)

      # Board 2 seated the wrong way round.
      [_b1, b2] = Tournaments.get_round(t.id, 1).pairings |> Enum.sort_by(& &1.board)

      Repo.update_all(from(p in Pairing, where: p.id == ^b2.id),
        set: [white_player_id: b2.black_player_id, black_player_id: b2.white_player_id]
      )

      {imported, warnings} = round_trip(t)
      assert [{1, []}] = summary(imported)
      assert Enum.any?(warnings, &(&1 =~ "the colours do not alternate down the boards"))
    end

    test "board orders that do not line up are not a match" do
      {t, _} = team_round_robin([{"A", [2100, 2000]}, {"B", [2050, 1950]}], rounds_count: 1)
      t = pair_all!(t)
      fill_round!(t, 1)

      # B's two players trade boards, keeping the colours: B 2 on board 1, B 1 on board 2.
      [b1, b2] = Tournaments.get_round(t.id, 1).pairings |> Enum.sort_by(& &1.board)

      Repo.update_all(from(p in Pairing, where: p.id == ^b1.id),
        set: [black_player_id: b2.white_player_id]
      )

      Repo.update_all(from(p in Pairing, where: p.id == ^b2.id),
        set: [white_player_id: b1.black_player_id]
      )

      {imported, warnings} = round_trip(t)
      assert [{1, []}] = summary(imported)
      assert Enum.any?(warnings, &(&1 =~ "board orders do not line up"))
    end

    test "a team Swiss round where two teams have no boards cannot say who had the bye" do
      {t, _} = team_swiss(for(i <- 1..4, do: {"T#{i}", [2000 - i, 1900 - i]}), rounds: 3)
      pair_next!(t)
      fill_round!(Repo.reload!(t), 1)

      round = Tournaments.get_round(t.id, 1)
      [m1 | _] = Tournaments.list_matches(round.id)
      Repo.delete_all(from p in Pairing, where: p.match_id == ^m1.id)

      {imported, warnings} = round_trip(Repo.reload!(t))
      assert imported.team_pairing_mode == "players"

      assert Enum.any?(
               warnings,
               &(&1 =~ "does not say which of them had the pairing-allocated bye")
             )
    end

    test "a player on no team is not a team board" do
      {t, _} = team_round_robin([{"A", [2100, 2000]}, {"B", [2050, 1950]}], rounds_count: 1)
      t = pair_all!(t)
      fill_round!(t, 1)

      b2 = Repo.one!(from p in Player, where: p.tournament_id == ^t.id and p.name == "B 2")
      b2 |> Ecto.Changeset.change(team_id: nil) |> Repo.update!()

      {imported, warnings} = round_trip(t)
      assert [{1, []}] = summary(imported)
      assert Enum.any?(warnings, &(&1 =~ "B 2 plays a board but is on no team"))
    end
  end
end
