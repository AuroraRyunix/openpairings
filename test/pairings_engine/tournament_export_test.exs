defmodule PairingsEngine.TournamentExportTest do
  # Several tests here insert a second/third full tournament (teams, players,
  # rounds, byes, forbidden pairings) per test. Kept `async: false` for the
  # same reason as PairingsEngine.TournamentImportTest — see the comment
  # there and the `busy_timeout` note in config/test.exs.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, TournamentExport}
  alias PairingsEngine.Tournaments.{Tournament, Team, Player, Round, Pairing}
  alias PairingsEngine.Accounts.{Scope, User}

  # See PairingsEngine.TournamentsTest for why this bypasses the full
  # register/confirm fixture under async execution.
  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp fixture(scope) do
    tournament =
      Repo.insert!(%Tournament{
        name: "Export Shape Test",
        type: "swiss",
        rounds_count: 2,
        tiebreaks: ~w(BH SB),
        user_id: scope.user.id
      })

    team = Repo.insert!(%Team{tournament_id: tournament.id, name: "Team A", captain: "Cap"})

    a =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Alice",
        pairing_number: 1,
        team_id: team.id,
        norm_data: %{"title_claimed" => "IM"}
      })

    b = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob", pairing_number: 2})

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: a.id, round: 2, type: "requested-half"}
    ])

    Repo.insert_all("forbidden_pairings", [
      %{tournament_id: tournament.id, player_a_id: a.id, player_b_id: b.id}
    ])

    {tournament, %{a: a, b: b, team: team, round: round}}
  end

  test "export_tournament/1 wraps a single tournament in a versioned envelope" do
    scope = user_scope()
    {tournament, _} = fixture(scope)

    envelope = TournamentExport.export_tournament(tournament)

    assert envelope["format"] == "openpairings-export"
    assert envelope["version"] == 1
    assert %DateTime{} = envelope["exported_at"] |> DateTime.from_iso8601() |> elem(1)
    assert [t_data] = envelope["tournaments"]
    assert t_data["tournament"]["name"] == "Export Shape Test"
  end

  test "the tournament map carries settings but never the owning user id" do
    scope = user_scope()
    {tournament, _} = fixture(scope)

    [t_data] = TournamentExport.export_tournament(tournament)["tournaments"]

    refute Map.has_key?(t_data["tournament"], "user_id")
    refute Map.has_key?(t_data["tournament"], "id")
    assert t_data["tournament"]["tiebreaks"] == ["BH", "SB"]
    assert t_data["tournament"]["rounds_count"] == 2
  end

  test "teams, players, rounds/pairings, byes and forbidden pairings all round-trip into the JSON shape" do
    scope = user_scope()
    {tournament, %{a: a, b: b, team: team}} = fixture(scope)

    [t_data] = TournamentExport.export_tournament(tournament)["tournaments"]

    assert [team_json] = t_data["teams"]
    assert team_json["id"] == team.id
    assert team_json["name"] == "Team A"

    players_by_name = Map.new(t_data["players"], &{&1["name"], &1})
    assert players_by_name["Alice"]["id"] == a.id
    assert players_by_name["Alice"]["team_id"] == team.id
    assert players_by_name["Alice"]["norm_data"] == %{"title_claimed" => "IM"}
    assert players_by_name["Bob"]["team_id"] == nil

    assert [round_json] = t_data["rounds"]
    assert round_json["number"] == 1
    assert [pairing_json] = round_json["pairings"]
    assert pairing_json["white_player_id"] == a.id
    assert pairing_json["black_player_id"] == b.id
    assert pairing_json["result"] == "1-0"

    assert t_data["byes"] == [%{"player_id" => a.id, "round" => 2, "type" => "requested-half"}]
    assert t_data["forbidden_pairings"] == [%{"player_a_id" => a.id, "player_b_id" => b.id}]
  end

  test "the whole envelope survives a real JSON encode/decode round-trip" do
    scope = user_scope()
    {tournament, _} = fixture(scope)

    envelope = TournamentExport.export_tournament(tournament)
    decoded = envelope |> Jason.encode!() |> Jason.decode!()

    assert decoded == envelope
  end

  test "export_all/1 wraps every tournament the scope's user owns, and nobody else's" do
    scope = user_scope()
    other_scope = user_scope()

    {t1, _} = fixture(scope)
    {t2, _} = fixture(scope)
    {_other, _} = fixture(other_scope)

    envelope = TournamentExport.export_all(scope)
    names = Enum.map(envelope["tournaments"], & &1["tournament"]["name"])

    assert length(envelope["tournaments"]) == 2
    assert Enum.all?([t1.name, t2.name], &(&1 in names))
  end
end
