defmodule PairingsEngine.TournamentExportTest do
  # Several tests here insert a second/third full tournament (teams, players,
  # rounds, byes, forbidden pairings) per test. Kept `async: false` for the
  # same reason as PairingsEngine.TournamentImportTest - see the comment
  # there and the `busy_timeout` note in config/test.exs.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Audit, Mobile, Repo, TournamentExport}
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.Tournaments.{Collaborator, Tournament, Team, Player, Round, Pairing}
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

  # Every schema the envelope carries, paired with the two lists that decide
  # each of its fields: what is exported, and what is deliberately left out.
  # One list, walked by both guards below, so adding a schema to the envelope
  # is one entry here rather than a test somebody forgets to extend.
  #
  # Tournament had this guard from the start. Round and Pairing did not, and
  # two fields went missing through the gap: `pairings.hidden` was dropped,
  # so a backup/restore silently UN-HID every hidden board (a disclosure, not
  # a lost preference), and `rounds.explanation` too - that one stays
  # dropped, deliberately, because the blob holds DB player ids and
  # re-importing would attribute every bracket to the wrong people while
  # looking entirely plausible.
  #
  # AuditLog and Collaborator joined when the hand-off blocks arrived. A new
  # column on either (`audit_logs.severity`, say) must hit the same wall
  # rather than being dropped in silence: the audit trail is the arbiter's
  # evidence and the collaborator list is who may touch the event, and both
  # are worse things to lose quietly than a tiebreak setting.
  defp guarded_schemas do
    [
      {Tournament, TournamentExport.tournament_fields(),
       TournamentExport.excluded_tournament_fields(),
       "@tournament_fields / @excluded_tournament_fields"},
      {Round, TournamentExport.round_fields(), TournamentExport.round_excluded(),
       "@round_fields / @round_excluded"},
      {Pairing, pairing_exported_fields(), TournamentExport.pairing_excluded(),
       "pairing_map/1 / @pairing_excluded"},
      {AuditLog, TournamentExport.audit_fields(), TournamentExport.audit_excluded(),
       "@audit_fields / @audit_excluded"},
      {Collaborator, TournamentExport.collaborator_fields(),
       TournamentExport.collaborator_excluded(), "@collaborator_fields / @collaborator_excluded"}
    ]
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

    assert t_data["forbidden_pairings"] == [
             %{"player_a_id" => a.id, "player_b_id" => b.id, "soft" => false}
           ]
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
    test "every exported schema's fields are either exported or deliberately excluded" do
      for {schema, exported, excluded, list_name} <- guarded_schemas() do
        all = schema.__schema__(:fields) |> MapSet.new()
        accounted = MapSet.union(MapSet.new(exported), MapSet.new(excluded))
        unaccounted = MapSet.difference(all, accounted)

        assert MapSet.size(unaccounted) == 0,
               "#{inspect(schema)} fields neither exported nor deliberately excluded: " <>
                 "#{inspect(MapSet.to_list(unaccounted))}. Add each to #{list_name} " <>
                 "(with a reason) in PairingsEngine.TournamentExport."
      end
    end

    test "no schema's two lists overlap, and neither names a field that doesn't exist" do
      for {schema, exported, excluded, list_name} <- guarded_schemas() do
        all = schema.__schema__(:fields) |> MapSet.new()
        exported = MapSet.new(exported)
        excluded = MapSet.new(excluded)

        assert MapSet.intersection(exported, excluded) |> MapSet.size() == 0,
               "#{inspect(schema)}: #{list_name} claim the same field both ways: " <>
                 inspect(MapSet.to_list(MapSet.intersection(exported, excluded)))

        for {label, set} <- [{"exported", exported}, {"excluded", excluded}] do
          stale = MapSet.difference(set, all)

          assert MapSet.size(stale) == 0,
                 "#{inspect(schema)}'s #{label} list names fields that are not on the " <>
                   "schema: " <> inspect(MapSet.to_list(stale))
        end
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

      for field <- ~w(id user_id public_slug registration_open
                      deleted_at archived_at swar_guid) do
        refute Map.has_key?(t_map, field),
               "#{field} must not be exported - see @excluded_tournament_fields"
      end
    end
  end

  describe "the hand-off blocks" do
    test "an ordinary export carries neither block at all" do
      scope = user_scope()
      {tournament, %{a: a}} = fixture(scope)
      Audit.log(tournament.id, scope, "player.created", %{player_id: a.id, player_name: "Alice"})
      invite(tournament, "helper@example.com")

      [t_data] = TournamentExport.export_tournament(tournament)["tournaments"]

      # Absent, not empty: a snapshot payload and a "Duplicate tournament"
      # copy both go through this same call, and neither is a hand-off. An
      # empty list would read as "this event had no audit trail and no
      # collaborators", which is a different (and false) claim.
      refute Map.has_key?(t_data, "audit_log")
      refute Map.has_key?(t_data, "collaborators")
    end

    test "a hand-off export carries this tournament's audit rows, oldest first" do
      scope = user_scope()
      {tournament, %{a: a}} = fixture(scope)

      Audit.log(tournament.id, scope, "player.created", %{player_id: a.id, player_name: "Alice"})
      Audit.log(tournament.id, scope, "pairing.round_paired", %{round: 1, board_count: 2})

      rows = handoff_entry(tournament)["audit_log"]

      assert Enum.map(rows, & &1["action"]) == ["player.created", "pairing.round_paired"]
      assert Enum.all?(rows, &is_binary(&1["inserted_at"]))
    end

    test "the acting user travels as a display string, never as a user id" do
      scope = user_scope()
      {tournament, _} = fixture(scope)
      Audit.log(tournament.id, scope, "tournament.settings_updated", %{changed_fields: %{}})
      Audit.log(tournament.id, nil, "fide.sync_started", %{})

      [by_user, by_system] = handoff_entry(tournament)["audit_log"]

      # The email is the whole point: a `user_id` from another instance
      # either dangles or, worse, lands on a stranger who happens to hold
      # that id here.
      assert by_user["actor"] == scope.user.email
      refute Map.has_key?(by_user, "user_id")

      # A system row has no actor to name, and inventing one would be a
      # false statement about who acted.
      assert by_system["actor"] == nil
    end

    test "only this tournament's own rows travel - not another event's, not the machine's" do
      scope = user_scope()
      {tournament, _} = fixture(scope)
      {other, _} = fixture(scope)

      Audit.log(tournament.id, scope, "player.deleted", %{player_name: "Mine"})
      Audit.log(other.id, scope, "player.deleted", %{player_name: "Not mine"})
      Audit.log_system(scope, "backup.downloaded", %{filename: "all.json"})

      rows = handoff_entry(tournament)["audit_log"]

      assert Enum.map(rows, & &1["details"]["player_name"]) == ["Mine"]

      # A machine-wide row (`tournament_id IS NULL`) is a fact about the
      # installation - a role granted, a backup taken. It is not this
      # tournament's record and must not leave with it.
      refute Enum.any?(rows, &(&1["action"] == "backup.downloaded"))
    end

    test "collaborators travel as an invitation's ingredients and nothing more" do
      scope = user_scope()
      {tournament, _} = fixture(scope)
      accepted = invite(tournament, "Accepted@Example.com")

      Repo.update!(Ecto.Changeset.change(accepted, status: "accepted", invite_token: nil))
      invite(tournament, "pending@example.com")

      rows = handoff_entry(tournament)["collaborators"]
      emails = rows |> Enum.map(& &1["email"]) |> Enum.sort()

      # Both kinds travel. On the far side they become the same thing - a
      # pending invitation - so the distinction the source drew disappears
      # by construction, and dropping the pending ones would lose people the
      # owner had already decided to invite.
      assert emails == ["accepted@example.com", "pending@example.com"]
      assert Enum.all?(rows, &(&1["role"] == "editor"))

      for row <- rows, field <- ~w(id user_id invite_token status inserted_at updated_at) do
        refute Map.has_key?(row, field),
               "#{field} must not travel with a collaborator - see @collaborator_excluded"
      end
    end

    test "a hand-off envelope is still plain JSON, with no structs left in it" do
      scope = user_scope()
      {tournament, %{a: a}} = fixture(scope)
      Audit.log(tournament.id, scope, "player.created", %{player_id: a.id, player_name: "Alice"})
      invite(tournament, "helper@example.com")

      envelope = TournamentExport.export_tournament(tournament, include_handoff: true)

      assert envelope |> Jason.encode!() |> Jason.decode!() == envelope
    end

    test "a mobile enrolment never travels - not its token, not its code" do
      scope = user_scope()
      {tournament, _} = fixture(scope)
      {:ok, enrollment} = Mobile.create_enrollment(tournament.id, label: "Arbiter's phone")

      json =
        tournament
        |> TournamentExport.export_tournament(include_handoff: true)
        |> Jason.encode!()

      # These two ARE the access. A code minted on the hosted copy must not
      # start working on a laptop because a file moved, so nothing about the
      # enrolment may appear anywhere in the envelope - not under its own
      # key, not smuggled inside an audit row's details.
      refute json =~ enrollment.token
      refute json =~ enrollment.code
      refute json =~ "Arbiter's phone"
      assert :mobile_enrollments in TournamentExport.excluded_tables()
    end
  end

  # Skips `Tournaments.add_collaborator/3` on purpose: that path sends an
  # invitation email, which these tests have no reason to exercise.
  defp invite(tournament, email) do
    %Collaborator{tournament_id: tournament.id}
    |> Collaborator.changeset(%{
      email: email,
      status: "pending",
      invite_token: "tok-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp handoff_entry(tournament) do
    tournament
    |> TournamentExport.export_tournament(include_handoff: true)
    |> Map.fetch!("tournaments")
    |> hd()
  end
end
