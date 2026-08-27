defmodule PairingsEngine.TournamentExportTest do
  # Several tests here insert a second/third full tournament (teams, players,
  # rounds, byes, forbidden pairings) per test. Kept `async: false` for the
  # same reason as PairingsEngine.TournamentImportTest - see the comment
  # there and the `busy_timeout` note in config/test.exs.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, TournamentExport}
  alias PairingsEngine.Tournaments.{Tournament, Team, Player, Round, Pairing}
  alias PairingsEngine.Accounts.{Scope, User}

  # `pairing_map/1` builds its map inline rather than from a module
  # attribute, so the guard reads the keys off a real exported pairing. That
  # is stricter than a list would be: it checks what the function ACTUALLY
  # emits, not what a list next to it claims.
  defp pairing_exported_fields do
    scope = user_scope()
    tournament = tournament_with_one_hidden_pairing(scope)

    TournamentExport.export_tournament(tournament)
    |> Map.fetch!("tournaments")
    |> hd()
    |> Map.fetch!("rounds")
    |> hd()
    |> Map.fetch!("pairings")
    |> hd()
    |> Map.keys()
    |> Enum.map(&String.to_atom/1)
  end

  # One round, two boards, one of them hidden - the smallest shape that can
  # tell "hidden round-trips" from "everything defaults to false".
  defp tournament_with_one_hidden_pairing(scope) do
    tournament =
      Repo.insert!(%Tournament{
        name: "Hidden Board",
        type: "swiss",
        rounds_count: 1,
        user_id: scope.user.id
      })

    players =
      for n <- 1..4 do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "P#{n}",
          pairing_number: n
        })
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})
    [a, b, c, d] = players

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      hidden: true
    })

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 2,
      white_player_id: c.id,
      black_player_id: d.id,
      hidden: false
    })

    tournament
  end

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

  describe "the exported field list must not rot behind the schema" do
    # This is the regression guard for a real, long-lived bug: the export's
    # @tournament_fields list had drifted far behind the schema, most
    # damagingly missing `pairing_system` - so a JSON backup of a Keizer or
    # round-robin tournament silently restored as a Swiss one. Adding a
    # schema field now forces a deliberate choice: export it, or list it in
    # @excluded_tournament_fields with a reason.
    test "every tournament schema field is either exported or deliberately excluded" do
      all = Tournament.__schema__(:fields) |> MapSet.new()
      exported = TournamentExport.tournament_fields() |> MapSet.new()
      excluded = TournamentExport.excluded_tournament_fields() |> MapSet.new()

      unaccounted = all |> MapSet.difference(exported) |> MapSet.difference(excluded)

      assert MapSet.size(unaccounted) == 0,
             "these tournament schema fields are neither exported nor listed as deliberately " <>
               "excluded: #{inspect(MapSet.to_list(unaccounted))}. Add each to " <>
               "@tournament_fields or @excluded_tournament_fields (with a reason) in " <>
               "PairingsEngine.TournamentExport."
    end

    test "the two lists never overlap, and neither names a field that doesn't exist" do
      all = Tournament.__schema__(:fields) |> MapSet.new()
      exported = TournamentExport.tournament_fields() |> MapSet.new()
      excluded = TournamentExport.excluded_tournament_fields() |> MapSet.new()

      assert MapSet.intersection(exported, excluded) |> MapSet.size() == 0

      for {label, set} <- [{"exported", exported}, {"excluded", excluded}] do
        stale = MapSet.difference(set, all)

        assert MapSet.size(stale) == 0,
               "#{label} list names fields that are not on the schema: " <>
                 inspect(MapSet.to_list(stale))
      end
    end

    # The same guard for Round and Pairing, which did not have one - and two
    # fields went missing through the gap. `pairings.hidden` was dropped, so
    # a backup/restore silently UN-HID every hidden board, which is a
    # disclosure rather than a lost preference. `rounds.explanation` was
    # dropped too; that one stays dropped, deliberately, because the blob
    # holds DB player ids and re-importing would attribute every bracket to
    # the wrong people while looking entirely plausible.
    #
    # Neither was caught by anything. The Tournament guard above existed the
    # whole time and was simply never extended to the other two schemas.
    test "every round and pairing schema field is either exported or deliberately excluded" do
      for {schema, exported, excluded, list_name} <- [
            {Round, TournamentExport.round_fields(), TournamentExport.round_excluded(),
             "@round_fields / @round_excluded"},
            {Pairing, pairing_exported_fields(), TournamentExport.pairing_excluded(),
             "pairing_map/1 / @pairing_excluded"}
          ] do
        all = schema.__schema__(:fields) |> MapSet.new()
        accounted = MapSet.union(MapSet.new(exported), MapSet.new(excluded))
        unaccounted = MapSet.difference(all, accounted)

        assert MapSet.size(unaccounted) == 0,
               "#{inspect(schema)} fields neither exported nor deliberately excluded: " <>
                 "#{inspect(MapSet.to_list(unaccounted))}. Add each to #{list_name} " <>
                 "(with a reason) in PairingsEngine.TournamentExport."
      end
    end

    test "a hidden pairing survives export and re-import" do
      scope = user_scope()
      tournament = tournament_with_one_hidden_pairing(scope)

      exported = TournamentExport.export_tournament(tournament)

      pairings =
        exported["tournaments"]
        |> hd()
        |> Map.fetch!("rounds")
        |> hd()
        |> Map.fetch!("pairings")

      assert Enum.any?(pairings, &(&1["hidden"] == true)),
             "a hidden pairing must round-trip as hidden - restoring it visible " <>
               "publishes a board the arbiter deliberately withheld"

      assert Enum.any?(pairings, &(&1["hidden"] == false)),
             "and a visible one must stay visible"
    end

    test "the pairing-shape fields that made this a real bug are actually exported" do
      scope = user_scope()

      tournament =
        Repo.insert!(%Tournament{
          name: "Keizer Backup",
          type: "swiss",
          pairing_system: "keizer",
          rr_cycles: 2,
          rounds_count: 3,
          user_id: scope.user.id
        })

      exported = TournamentExport.export_tournament(tournament)
      t_map = hd(exported["tournaments"])["tournament"]

      assert t_map["pairing_system"] == "keizer"
      assert t_map["rr_cycles"] == 2
    end

    test "identity and sharing state are NOT exported" do
      scope = user_scope()
      {tournament, _} = fixture(scope)

      t_map =
        tournament
        |> TournamentExport.export_tournament()
        |> get_in(["tournaments", Access.at(0), "tournament"])

      for field <- ~w(id user_id public_slug public_pages_enabled registration_open
                      deleted_at archived_at swar_guid) do
        refute Map.has_key?(t_map, field),
               "#{field} must not be exported - see @excluded_tournament_fields"
      end
    end
  end
end
