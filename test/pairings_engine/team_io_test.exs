defmodule PairingsEngine.TeamIoTest do
  @moduledoc """
  What a team round robin looks like on the way out of the app: the TRF team
  section, the JSON backup, and the refusal to publish.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Publishing.QueueEntry

  alias PairingsEngine.{
    Publishing,
    Repo,
    TeamStandings,
    TournamentExport,
    TournamentImport,
    Tournaments,
    TrfExport,
    TrfImport
  }

  alias PairingsEngine.Tournaments.{Match, Tournament}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "team#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp played_example(scope) do
    {t, _} =
      team_round_robin(
        [
          {"Antwerp Knights", [2210, 2105, 1990]},
          {"Brugse SK", [2150, 2000]},
          {"Charleroi", [1900, 1850]},
          {"Deurne", [1800, 1750]}
        ],
        user_id: scope.user.id,
        start_date: "2026-09-01",
        end_date: "2026-09-03",
        round_dates: ["2026-09-01", "2026-09-02", "2026-09-03"],
        city: "Gent",
        federation: "BEL"
      )

    t = pair_all!(t)
    enter!(t, 1, "Antwerp Knights", "Deurne", ["1-0", "1/2-1/2"])
    enter!(t, 1, "Brugse SK", "Charleroi", ["0-1", "1-0"])
    enter!(t, 2, "Deurne", "Charleroi", ["1-0", "0-1"])
    Repo.reload!(t)
  end

  describe "TRF export" do
    test "writes the team section: one 013 record per team, starting ranks in board order" do
      t = played_example(user_scope())
      {:ok, text} = TrfExport.export(t, nil, dialect: :engine)
      parsed = Ainalrami.Trf.parse(text)

      expected =
        for team <- Tournaments.list_teams(t.id) do
          ranks =
            t.id
            |> Tournaments.team_roster(team.id)
            |> Enum.map(& &1.pairing_number)
            |> Enum.reject(&is_nil/1)

          %{name: team.name, player_ranks: ranks}
        end

      assert parsed.teams == expected
      assert text =~ ~r/^082 4\r?$/m
      # The reserve of Antwerp never played, so has no number and no 001 line.
      assert Enum.map(parsed.teams, &length(&1.player_ranks)) == [2, 2, 2, 2]
    end

    test "a board forfeited for want of a player is an unplayed forfeit win, not a game" do
      {t, _} =
        team_round_robin([{"Full", [2000, 1900]}, {"Short", [1950]}],
          start_date: "2026-09-01",
          end_date: "2026-09-01",
          round_dates: ["2026-09-01"]
        )

      t = pair_all!(t)
      {_match, [b1, _b2]} = match_between(t, 1, "Full", "Short")
      {:ok, _} = Tournaments.update_pairing_result(b1, "1/2-1/2")

      {:ok, text} = TrfExport.export(Repo.reload!(t), nil, dialect: :engine)
      parsed = Ainalrami.Trf.parse(text)

      # No opponent, so no opponent column: `Pairing.bye_safe_result/2` writes
      # the point without a playing code, exactly as it does for an
      # individual board whose seat was vacated. Nothing reaches the rating
      # report as a game.
      full_2 = Enum.find(parsed.players, &(&1.name == "Full 2"))
      assert [%{result: "F", opponent_rank: nil}] = full_2.games
      assert full_2.points == 1.0
    end

    test "individual games still go out on the 001 lines" do
      t = played_example(user_scope())
      {:ok, text} = TrfExport.export(t, nil, dialect: :engine)
      parsed = Ainalrami.Trf.parse(text)

      assert length(parsed.players) == 8

      antwerp_1 =
        Enum.find(parsed.players, &String.starts_with?(&1.name, "Antwerp Knights 1"))

      [r1 | _] = antwerp_1.games
      assert {r1.colour, r1.result} == {"w", "1"}
    end

    test "an individual tournament's file has no team record" do
      t =
        Repo.insert!(%Tournament{
          name: "Open",
          type: "swiss",
          rounds_count: 1,
          start_date: "2026-09-01",
          end_date: "2026-09-01"
        })

      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Solo", "fide_rating" => "2000"})
      {:ok, text} = TrfExport.export(t, nil, dialect: :engine)

      refute text =~ ~r/^013 /m
      assert text =~ ~r/^082 0\r?$/m
    end

    test "round trip: importing the file brings the teams and board orders back" do
      scope = user_scope()
      t = played_example(scope)
      {:ok, text} = TrfExport.export(t, nil, dialect: :engine)

      {:ok, imported, warnings} = TrfImport.import_text(text, scope)

      assert Enum.any?(
               warnings,
               &(&1[:kind] == :note and &1.text =~ "teams and their board orders")
             )

      rosters =
        for team <- Tournaments.list_teams(imported.id) do
          {team.name, imported.id |> Tournaments.team_roster(team.id) |> Enum.map(& &1.name)}
        end

      assert rosters == [
               {"Antwerp Knights", ["Antwerp Knights 1", "Antwerp Knights 2"]},
               {"Brugse SK", ["Brugse SK 1", "Brugse SK 2"]},
               {"Charleroi", ["Charleroi 1", "Charleroi 2"]},
               {"Deurne", ["Deurne 1", "Deurne 2"]}
             ]
    end
  end

  describe "JSON backup" do
    test "teams, their order and the matches survive export and import, and so do the standings" do
      owner = user_scope()
      t = played_example(owner)
      {:ok, t} = Tournaments.update_tournament(t, %{team_match_points_win: 3.0})

      envelope = TournamentExport.export_tournament(t)
      assert {:ok, [imported]} = TournamentImport.import(envelope, user_scope())
      imported = Repo.reload!(imported)

      assert {imported.team_boards, imported.team_match_points_win} == {2, 3.0}

      assert Enum.map(Tournaments.list_teams(imported.id), &{&1.name, &1.seed, &1.pairing_number}) ==
               Enum.map(Tournaments.list_teams(t.id), &{&1.name, &1.seed, &1.pairing_number})

      summary = fn tournament ->
        tournament
        |> TeamStandings.standings()
        |> Enum.map(&{&1.team.name, &1.rank, &1.mp, &1.gp, &1.tiebreaks})
      end

      assert summary.(imported) == summary.(t)

      original_matches =
        Repo.aggregate(
          from(m in Match, join: r in assoc(m, :round), where: r.tournament_id == ^t.id),
          :count
        )

      imported_matches =
        Repo.aggregate(
          from(m in Match, join: r in assoc(m, :round), where: r.tournament_id == ^imported.id),
          :count
        )

      assert imported_matches == original_matches

      # Every board of the copy points at a match of the copy.
      round = Tournaments.get_round(imported.id, 1)
      match_ids = round.id |> Tournaments.list_matches() |> MapSet.new(& &1.id)
      assert Enum.all?(round.pairings, &MapSet.member?(match_ids, &1.match_id))
    end
  end

  describe "publishing" do
    test "a team tournament cannot be switched on" do
      t = played_example(user_scope())
      assert {:error, :team_tournament} = Tournaments.set_publish_to_openresults(t, true)
      refute Repo.reload!(t).publish_to_openresults
    end

    test "one already switched on is never queued, and a send is refused" do
      t = played_example(user_scope())
      t = t |> Ecto.Changeset.change(publish_to_openresults: true) |> Repo.update!()

      :ok = Publishing.enqueue(t)
      :ok = Publishing.enqueue_id(t.id)
      refute Repo.exists?(from q in QueueEntry, where: q.tournament_id == ^t.id)

      Publishing.put_endpoint("https://results.example.test")
      Publishing.put_token("test-token")

      assert {:error, message} = Publishing.publish(t)
      assert message == Publishing.team_refusal()

      # It can still be switched off.
      assert {:ok, _} = Tournaments.set_publish_to_openresults(t, false)
    end

    test "an individual tournament still queues as before" do
      t =
        Repo.insert!(%Tournament{
          name: "Open",
          type: "swiss",
          rounds_count: 1,
          publish_to_openresults: true
        })

      :ok = Publishing.enqueue_id(t.id)
      assert Repo.exists?(from q in QueueEntry, where: q.tournament_id == ^t.id)
    end
  end
end
