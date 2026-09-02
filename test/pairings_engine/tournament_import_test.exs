defmodule PairingsEngine.TournamentImportTest do
  # Each round-trip test performs a full transactional import (many
  # sequential inserts held on one connection) on top of an equally
  # write-heavy fixture - the single busiest writer in the suite. Kept
  # `async: false` to keep that write burst from contending with the rest
  # of the async pool for SQLite's single writer lock (see the
  # `busy_timeout` comment in config/test.exs for the general tradeoff).
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Audit, Repo, Standings, TournamentExport, TournamentImport, Tournaments}
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.Tournaments.{Collaborator, Tournament, Team, Player, Round, Pairing}
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

  # A non-trivial tournament: a team, 3 players (one with norm data, extra
  # points and a category), 2 rounds (a decisive game, a draw, and a
  # requested-half bye), and a forbidden pairing - enough surface to catch a
  # sloppy remap anywhere in the import pipeline.
  defp fixture(scope) do
    tournament =
      Repo.insert!(%Tournament{
        name: "Round-trip Test",
        type: "swiss",
        rounds_count: 2,
        tiebreaks: ~w(BH SB DE),
        points_win: 1.0,
        points_draw: 0.5,
        bye_value: 1.0,
        presence_value: 0.75,
        abs_value: 0.25,
        presence_on_allocated_bye: true,
        round_dates: ["2026-03-01", "2026-03-08"],
        categories: ["U20"],
        officials: %{"pairing_mode" => "computerized"},
        user_id: scope.user.id
      })

    team = Repo.insert!(%Team{tournament_id: tournament.id, name: "Team A", captain: "Cap"})

    a =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Alice",
        fide_rating: 2000,
        pairing_number: 1,
        team_id: team.id,
        birth_date: ~D[1990-05-12],
        extra_points: 0.5,
        category: "U20",
        norm_data: %{"title_claimed" => "IM", "remarks" => "strong event"}
      })

    b =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Bob",
        fide_rating: 1900,
        pairing_number: 2
      })

    c =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Carol",
        fide_rating: 1800,
        pairing_number: 3
      })

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 2,
      white_player_id: c.id,
      black_player_id: nil,
      result: "bye"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 1,
      white_player_id: b.id,
      black_player_id: c.id,
      result: "1/2-1/2"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 2,
      white_player_id: a.id,
      black_player_id: nil,
      result: "bye"
    })

    Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: c.id, round: 1, type: "pairing-allocated"},
      %{tournament_id: tournament.id, player_id: a.id, round: 2, type: "pairing-allocated"}
    ])

    Repo.insert_all("forbidden_pairings", [
      %{tournament_id: tournament.id, player_a_id: b.id, player_b_id: c.id}
    ])

    tournament
  end

  defp standings_signature(tournament) do
    tournament
    |> Standings.standings()
    |> Enum.map(fn e ->
      {e.player.name, e.points, e.extra_points, e.total, e.rank, e.tiebreaks}
    end)
    |> Enum.sort()
  end

  defp pairing_signatures(tournament_id) do
    tournament_id
    |> Tournaments.list_rounds()
    |> Enum.flat_map(fn r ->
      round = Tournaments.get_round(tournament_id, r.number)

      Enum.map(round.pairings, fn p ->
        {r.number, p.board, p.result, p.white_player && p.white_player.name,
         p.black_player && p.black_player.name}
      end)
    end)
    |> Enum.sort()
  end

  defp byes_signature(tournament_id) do
    Repo.all(
      from(b in "byes",
        join: p in Player,
        on: p.id == b.player_id,
        where: b.tournament_id == ^tournament_id,
        select: {p.name, b.round, b.type}
      )
    )
    |> Enum.sort()
  end

  defp forbidden_signature(tournament_id) do
    Repo.all(
      from(f in "forbidden_pairings",
        join: pa in Player,
        on: pa.id == f.player_a_id,
        join: pb in Player,
        on: pb.id == f.player_b_id,
        where: f.tournament_id == ^tournament_id,
        select: {pa.name, pb.name}
      )
    )
    |> Enum.sort()
  end

  ## ---------- round-trip integrity (the key correctness property) ----------

  test "export -> import reproduces identical standings, points and per-pairing results" do
    owner = user_scope()
    importer = user_scope()
    original = fixture(owner)

    envelope = TournamentExport.export_tournament(original)
    assert {:ok, [imported]} = TournamentImport.import(envelope, importer)

    # New tournament, owned by the importer, never the original id.
    assert imported.id != original.id
    assert imported.user_id == importer.user.id
    assert imported.name == original.name
    assert imported.tiebreaks == original.tiebreaks
    assert imported.round_dates == original.round_dates
    assert imported.categories == original.categories
    assert imported.officials == original.officials

    # SWAR-scoring fields (3-2-1 presence/absence values + the PreBye flag)
    # must survive a backup/restore - same fidelity class as birth_date.
    assert imported.presence_value == 0.75
    assert imported.abs_value == 0.25
    assert imported.presence_on_allocated_bye == true

    assert standings_signature(imported) == standings_signature(original)
    assert pairing_signatures(imported.id) == pairing_signatures(original.id)
    assert byes_signature(imported.id) == byes_signature(original.id)
    assert forbidden_signature(imported.id) == forbidden_signature(original.id)

    # Team and norm data followed the remap too.
    imported_alice = Enum.find(Tournaments.list_players(imported.id), &(&1.name == "Alice"))
    assert imported_alice.norm_data == %{"title_claimed" => "IM", "remarks" => "strong event"}
    assert imported_alice.extra_points == 0.5
    assert imported_alice.birth_date == ~D[1990-05-12]
    assert imported_alice.team_id != nil
    imported_team = Repo.get!(Team, imported_alice.team_id)
    assert imported_team.name == "Team A"
    assert imported_team.tournament_id == imported.id
  end

  test "round-trip re-derives status instead of trusting whatever the export snapshotted" do
    owner = user_scope()
    importer = user_scope()
    original = fixture(owner)

    # The fixture's 2 rounds are both fully scored (every pairing has a
    # result), but `original` was inserted directly via Repo.insert! rather
    # than through the normal write paths that call
    # `Tournaments.refresh_status!/1` - its own `status` column is still
    # the schema default, deliberately mismatched with reality, so this
    # proves the import re-derives status (see
    # `PairingsEngine.TournamentImport.do_import/2`) instead of carrying
    # over whatever `status` value the export happened to include.
    assert original.status == "setup"

    envelope = TournamentExport.export_tournament(original)
    assert {:ok, [imported]} = TournamentImport.import(envelope, importer)

    assert imported.status == "finished"
    assert Tournaments.get_tournament!(imported.id).status == "finished"
  end

  test "a fixed-table player keeps special_table across a round trip" do
    # `Player.sync_special_table/1` derives the flag from the PRESENCE of a
    # "fixed_board" key, on the stated assumption that writers which set
    # `special_table` directly - the SWAR importer, from HandyTable - never
    # include `fixed_board`. This exporter includes it always, even as nil,
    # which that assumption did not anticipate: the exported `true` was
    # overwritten with false on the way back in, so a SWAR-imported
    # fixed-table player lost the flag that keeps them on their table.
    owner = user_scope()
    importer = user_scope()
    original = fixture(owner)

    [player | _] = Tournaments.list_players(original.id)

    {:ok, _} =
      player
      |> Ecto.Changeset.change(special_table: true, fixed_board: nil)
      |> Repo.update()

    envelope = TournamentExport.export_tournament(original)
    assert {:ok, [imported]} = TournamentImport.import(envelope, importer)

    restored = Enum.find(Tournaments.list_players(imported.id), &(&1.name == player.name))

    assert restored.special_table == true,
           "a SWAR-style fixed-table player must not lose the flag on restore"
  end

  test "a player who is not on a fixed table stays that way" do
    owner = user_scope()
    importer = user_scope()
    original = fixture(owner)

    envelope = TournamentExport.export_tournament(original)
    assert {:ok, [imported]} = TournamentImport.import(envelope, importer)

    assert Enum.all?(Tournaments.list_players(imported.id), &(&1.special_table in [false, nil]))
  end

  test "round-trip on a partially-paired tournament re-derives status as running, not finished" do
    owner = user_scope()
    importer = user_scope()
    original = fixture(owner)
    {:ok, original} = Tournaments.update_tournament(original, %{"rounds_count" => 3})

    envelope = TournamentExport.export_tournament(original)
    assert {:ok, [imported]} = TournamentImport.import(envelope, importer)

    assert imported.status == "running"
  end

  test "importing into the same account that exported it still creates a brand-new tournament" do
    scope = user_scope()
    original = fixture(scope)

    envelope = TournamentExport.export_tournament(original)
    assert {:ok, [imported]} = TournamentImport.import(envelope, scope)

    assert imported.id != original.id
    assert imported.user_id == scope.user.id

    assert length(Tournaments.list_players(imported.id)) ==
             length(Tournaments.list_players(original.id))
  end

  test "every id is fresh - no player/team/round/pairing id is reused from the source" do
    owner = user_scope()
    importer = user_scope()
    original = fixture(owner)

    envelope = TournamentExport.export_tournament(original)
    assert {:ok, [imported]} = TournamentImport.import(envelope, importer)

    original_player_ids = MapSet.new(Tournaments.list_players(original.id), & &1.id)
    imported_player_ids = MapSet.new(Tournaments.list_players(imported.id), & &1.id)
    assert MapSet.disjoint?(original_player_ids, imported_player_ids)

    original_round_ids = MapSet.new(Tournaments.list_rounds(original.id), & &1.id)
    imported_round_ids = MapSet.new(Tournaments.list_rounds(imported.id), & &1.id)
    assert MapSet.disjoint?(original_round_ids, imported_round_ids)
  end

  ## ---------- importing every tournament ("all") ----------

  test "an envelope with multiple tournaments imports all of them as new tournaments" do
    owner = user_scope()
    importer = user_scope()
    t1 = fixture(owner)
    t2 = fixture(owner)

    envelope = TournamentExport.export_all(owner)
    assert {:ok, imported} = TournamentImport.import(envelope, importer)

    assert length(imported) == 2
    assert Enum.all?(imported, &(&1.user_id == importer.user.id))
    imported_ids = Enum.map(imported, & &1.id)
    refute t1.id in imported_ids
    refute t2.id in imported_ids

    # The importer now owns exactly these 2 tournaments.
    owned =
      Tournaments.list_tournaments(importer) |> Enum.map(fn {t, _count, _owner?} -> t.id end)

    assert Enum.sort(owned) == Enum.sort(imported_ids)
  end

  test "broadcasts the importer's tournament-list change once after a successful import" do
    owner = user_scope()
    importer = user_scope()
    fixture(owner)

    Phoenix.PubSub.subscribe(
      PairingsEngine.PubSub,
      Tournaments.user_tournaments_topic(importer.user.id)
    )

    envelope = TournamentExport.export_all(owner)
    assert {:ok, _imported} = TournamentImport.import(envelope, importer)

    user_id = importer.user.id
    assert_receive {:tournaments_changed, ^user_id}
    refute_receive {:tournaments_changed, ^user_id}
  end

  ## ---------- validation: bad envelopes are rejected cleanly ----------

  test "rejects a file with the wrong format tag" do
    scope = user_scope()
    assert {:error, reason} = TournamentImport.import(%{"format" => "something-else"}, scope)
    assert reason =~ "not an OpenPairings export"
  end

  test "rejects a file with an unsupported version" do
    scope = user_scope()

    envelope = %{"format" => "openpairings-export", "version" => 999, "tournaments" => []}
    assert {:error, reason} = TournamentImport.import(envelope, scope)
    assert reason =~ "Unsupported export version"
  end

  test "rejects a file with no tournaments" do
    scope = user_scope()

    envelope = %{"format" => "openpairings-export", "version" => 1, "tournaments" => []}
    assert {:error, reason} = TournamentImport.import(envelope, scope)
    assert reason =~ "no tournaments"
  end

  test "rejects a structurally nonsensical file without crashing" do
    scope = user_scope()

    assert {:error, _reason} = TournamentImport.import(%{"tournaments" => "not-a-list"}, scope)
    assert {:error, _reason} = TournamentImport.import("just a string", scope)
    assert {:error, _reason} = TournamentImport.import([1, 2, 3], scope)
  end

  test "an invalid tournament entry rolls the whole import back (no partial import)" do
    owner = user_scope()
    importer = user_scope()
    fixture(owner)

    envelope = TournamentExport.export_all(owner)
    # Corrupt the tournament's name to violate validate_required.
    bad_envelope =
      update_in(envelope, ["tournaments", Access.at(0), "tournament", "name"], fn _ -> "" end)

    assert {:error, _reason} = TournamentImport.import(bad_envelope, importer)
    assert Tournaments.list_tournaments(importer) == []
  end

  describe "fields that used to be silently dropped now survive the round trip" do
    test "the pairing shape (system, cycles, match format, categories) comes back intact" do
      owner = user_scope()
      importer = user_scope()

      original =
        Repo.insert!(%Tournament{
          name: "Shape Round Trip",
          type: "swiss",
          rounds_count: 4,
          user_id: owner.user.id,
          pairing_system: "keizer",
          rr_cycles: 2,
          keizer_top_value: 40,
          categories_enabled: true,
          categories: ["Open", "U18"],
          category_rules: %{"U18" => %{"kind" => "age_below", "value" => 18}},
          club_exclusion: "all",
          fed_exclusion: "listed",
          fed_exclusion_list: "BEL, NED",
          count_extra_points: true,
          extra_points_bands: "1400:1",
          publish_mode: "manual",
          publish_delay_minutes: 15,
          abs_value: 0.5,
          abs_jusque: 7,
          abs_nbfois: 2,
          absent_counts_as_vur: true,
          fide_homologated: true
        })

      envelope = TournamentExport.export_tournament(original)
      assert {:ok, [imported]} = TournamentImport.import(envelope, importer)
      imported = Repo.reload!(imported)

      # Before this, every one of these came back at its schema default -
      # most damagingly pairing_system, which silently became "swiss".
      assert imported.pairing_system == "keizer"
      assert imported.rr_cycles == 2
      assert imported.keizer_top_value == 40
      assert imported.categories_enabled
      assert imported.categories == ["Open", "U18"]
      assert imported.category_rules == %{"U18" => %{"kind" => "age_below", "value" => 18}}
      assert imported.club_exclusion == "all"
      assert imported.fed_exclusion == "listed"
      assert imported.fed_exclusion_list == "BEL, NED"
      assert imported.count_extra_points
      assert imported.extra_points_bands == "1400:1"
      assert imported.publish_mode == "manual"
      assert imported.publish_delay_minutes == 15
      assert imported.abs_value == 0.5
      assert imported.abs_jusque == 7
      assert imported.abs_nbfois == 2
      assert imported.absent_counts_as_vur
      assert imported.fide_homologated
    end

    test "manual ranking round-trips with its actual order, not just the flag" do
      owner = user_scope()
      importer = user_scope()

      original =
        Repo.insert!(%Tournament{
          name: "Manual Rank Round Trip",
          type: "swiss",
          rounds_count: 1,
          user_id: owner.user.id,
          manual_ranking: true,
          manual_ranking_stale: true
        })

      Repo.insert!(%Player{tournament_id: original.id, name: "Second", manual_rank: 2})
      Repo.insert!(%Player{tournament_id: original.id, name: "First", manual_rank: 1})

      envelope = TournamentExport.export_tournament(original)
      assert {:ok, [imported]} = TournamentImport.import(envelope, importer)
      imported = Repo.reload!(imported)

      assert imported.manual_ranking
      assert imported.manual_ranking_stale

      ranks =
        imported.id
        |> Tournaments.list_players()
        |> Map.new(&{&1.name, &1.manual_rank})

      # Previously the flag came back on with every rank nil - manual ranking
      # switched on but pointing at nothing.
      assert ranks == %{"First" => 1, "Second" => 2}
    end

    test "a player's fixed board and a round's published_at survive" do
      owner = user_scope()
      importer = user_scope()

      original =
        Repo.insert!(%Tournament{
          name: "Fixed Board Round Trip",
          type: "swiss",
          rounds_count: 1,
          user_id: owner.user.id,
          publish_mode: "manual"
        })

      Repo.insert!(%Player{tournament_id: original.id, name: "Wheelchair", fixed_board: 1001})

      published = DateTime.utc_now() |> DateTime.truncate(:second)
      Repo.insert!(%Round{tournament_id: original.id, number: 1, published_at: published})

      envelope = TournamentExport.export_tournament(original)
      assert {:ok, [imported]} = TournamentImport.import(envelope, importer)

      assert [player] = Tournaments.list_players(imported.id)
      assert player.fixed_board == 1001

      assert %Round{published_at: ^published} = Tournaments.get_round(imported.id, 1)
    end

    test "the match-format flag round-trips, and match_id is deliberately left behind" do
      owner = user_scope()
      importer = user_scope()

      original =
        Repo.insert!(%Tournament{
          name: "Match Format Round Trip",
          type: "swiss",
          rounds_count: 2,
          user_id: owner.user.id,
          swiss_match_format: true
        })

      a = Repo.insert!(%Player{tournament_id: original.id, name: "Alice"})
      b = Repo.insert!(%Player{tournament_id: original.id, name: "Bob"})
      round = Repo.insert!(%Round{tournament_id: original.id, number: 1})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id
      })

      envelope = TournamentExport.export_tournament(original)

      # `pairings.match_id` looks like a plain integer on the schema but is a
      # real FK into the unexported `matches` table (team scaffolding), so
      # exporting it would produce a dangling cross-tournament reference.
      exported_pairing =
        envelope
        |> get_in(["tournaments", Access.at(0), "rounds", Access.at(0), "pairings", Access.at(0)])

      refute Map.has_key?(exported_pairing, "match_id")

      assert {:ok, [imported]} = TournamentImport.import(envelope, importer)
      assert Repo.reload!(imported).swiss_match_format
      assert %Round{pairings: [_]} = Tournaments.get_round(imported.id, 1)
    end

    test "a hand-edited backup can't smuggle junk into the uncast fields" do
      owner = user_scope()
      importer = user_scope()
      fixture(owner)

      envelope = TournamentExport.export_all(owner)

      tampered =
        envelope
        |> put_in(
          ["tournaments", Access.at(0), "tournament", "manual_ranking_stale"],
          "not-a-boolean"
        )
        |> update_in(["tournaments", Access.at(0), "players"], fn players ->
          Enum.map(players, &Map.put(&1, "manual_rank", "not-an-integer"))
        end)

      assert {:ok, [imported]} = TournamentImport.import(tampered, importer)

      # Both bypass Ecto's cast, so they're coerced explicitly rather than
      # landing in the column verbatim under SQLite's dynamic typing.
      refute Repo.reload!(imported).manual_ranking_stale

      assert imported.id
             |> Tournaments.list_players()
             |> Enum.all?(&is_nil(&1.manual_rank))
    end
  end

  ## ---------- the hand-off blocks: audit trail and collaborators ----------

  describe "the audit trail travels with the tournament" do
    test "every row comes across, in order, with fresh ids and the original times" do
      owner = user_scope()
      importer = user_scope()
      original = fixture(owner)

      Audit.log(original.id, owner, "player.created", %{player_name: "Alice"})
      Audit.log(original.id, owner, "pairing.round_paired", %{round: 1, board_count: 2})
      before = audit_rows(original.id)

      assert {:ok, [imported]} = handoff(original, importer)
      after_rows = audit_rows(imported.id)

      assert Enum.map(after_rows, & &1.action) == Enum.map(before, & &1.action)
      assert Enum.map(after_rows, & &1.inserted_at) == Enum.map(before, & &1.inserted_at)

      # Fresh rows on a fresh tournament - nothing shared with the source.
      assert Enum.all?(after_rows, &(&1.tournament_id == imported.id))
      assert MapSet.disjoint?(MapSet.new(before, & &1.id), MapSet.new(after_rows, & &1.id))

      # And the source's own trail is exactly as long as it was: an export
      # reads, it does not move.
      assert length(audit_rows(original.id)) == 2
    end

    test "the actor arrives as a name, and never as a link to a local stranger" do
      owner = user_scope()
      importer = user_scope()
      original = fixture(owner)

      Audit.log(original.id, owner, "player.deleted", %{player_name: "Alice"})
      Audit.log(original.id, nil, "fide.sync_started", %{})

      assert {:ok, [imported]} = handoff(original, importer)
      [by_user, by_system] = audit_rows(imported.id)

      # `user_id` stays nil on purpose. Linking the row to whoever holds
      # that email here would attribute the deletion to somebody who never
      # touched this tournament - the same misattribution a raw id causes,
      # just arrived at more politely.
      assert by_user.user_id == nil
      assert by_user.details["imported_actor"] == owner.user.email
      refute Map.has_key?(by_system.details, "imported_actor")
    end

    test "a second hand-off does not degrade the actor to nothing" do
      owner = user_scope()
      middle = user_scope()
      last = user_scope()
      original = fixture(owner)

      Audit.log(original.id, owner, "player.deleted", %{player_name: "Alice"})

      assert {:ok, [once]} = handoff(original, middle)
      assert {:ok, [twice]} = handoff(once, last)

      [row] = audit_rows(twice.id)
      assert row.details["imported_actor"] == owner.user.email
    end

    test "player ids in details are remapped, and land on the same person" do
      owner = user_scope()
      importer = user_scope()
      original = fixture(owner)

      [alice, bob] =
        original.id
        |> Tournaments.list_players()
        |> Enum.filter(&(&1.name in ["Alice", "Bob"]))
        |> Enum.sort_by(& &1.name)

      Audit.log(original.id, owner, "player.updated", %{
        player_id: alice.id,
        player_name: "Alice",
        changed_fields: %{"fide_rating" => [2000, 2010]}
      })

      Audit.log(original.id, owner, "forbidden_pairing.added", %{
        player_a_id: alice.id,
        player_b_id: bob.id
      })

      assert {:ok, [imported]} = handoff(original, importer)
      [updated, forbidden] = audit_rows(imported.id)

      # The whole point of the remap: the id in the row must resolve to the
      # SAME PERSON on this machine, not to whoever inherited that number.
      assert player_name(updated.details["player_id"]) == "Alice"
      assert player_name(forbidden.details["player_a_id"]) == "Alice"
      assert player_name(forbidden.details["player_b_id"]) == "Bob"

      # And it is genuinely a different number - proof this is a remap and
      # not the source's id sitting there looking plausible.
      assert updated.details["player_id"] != alice.id
      assert forbidden.details["player_b_id"] != bob.id
    end

    test "an id pointing at something that did not travel is dropped, not carried stale" do
      owner = user_scope()
      importer = user_scope()
      original = fixture(owner)

      Audit.log(original.id, owner, "pairing.result_entered", %{
        pairing_id: 4213,
        round: 1,
        board: 1,
        white: "Alice",
        black: "Bob",
        to: "1-0"
      })

      Audit.log(original.id, owner, "snapshot.restored", %{snapshot_id: 77, restored_to: "R1"})

      Audit.log(original.id, owner, "pairing.result_changed", %{
        enrollment_id: 9,
        enrollment_label: "Board 1 phone",
        via: "mobile",
        board: 1
      })

      assert {:ok, [imported]} = handoff(original, importer)
      [entered, restored, changed] = audit_rows(imported.id)

      # Pairings are re-inserted with fresh ids, snapshots and enrolments do
      # not travel at all. A raw number here would point at a real row in
      # somebody else's tournament on this machine.
      refute Map.has_key?(entered.details, "pairing_id")
      refute Map.has_key?(restored.details, "snapshot_id")
      refute Map.has_key?(changed.details, "enrollment_id")

      # Everything readable is untouched - the sentence still reads.
      assert entered.details["white"] == "Alice"
      assert entered.details["to"] == "1-0"
      assert restored.details["restored_to"] == "R1"
      assert changed.details["enrollment_label"] == "Board 1 phone"
    end

    test "an identifier that belongs to a person rather than to a row survives" do
      owner = user_scope()
      importer = user_scope()
      original = fixture(owner)

      Audit.log(original.id, owner, "player.updated", %{
        player_name: "Alice",
        changed_fields: %{"fide_id" => [nil, 12_345_678], "national_id" => ["", "B1234"]}
      })

      assert {:ok, [imported]} = handoff(original, importer)
      [row] = audit_rows(imported.id)

      # A FIDE ID is FIDE's number for a human being; it means the same
      # thing on every machine in the world. Dropping it because the key
      # ends in "_id" would delete the very fact under dispute.
      assert row.details["changed_fields"]["fide_id"] == [nil, 12_345_678]
      assert row.details["changed_fields"]["national_id"] == ["", "B1234"]
    end

    test "an unrecognised id key is dropped rather than guessed at" do
      owner = user_scope()
      importer = user_scope()
      original = fixture(owner)

      Audit.log(original.id, owner, "player.created", %{player_name: "Alice"})

      envelope =
        original
        |> TournamentExport.export_tournament(include_handoff: true)
        |> update_in(["tournaments", Access.at(0), "audit_log", Access.at(0), "details"], fn d ->
          Map.merge(d, %{"invoice_id" => 12, "nested" => %{"widget_id" => 7, "keep" => "yes"}})
        end)

      assert {:ok, [imported]} = TournamentImport.import(envelope, importer)
      [row] = audit_rows(imported.id)

      # The default has to be "drop". A key nobody has classified is far
      # more likely to be a row reference than an external identifier, and
      # a gap in the record beats a false statement in it.
      refute Map.has_key?(row.details, "invoice_id")
      refute Map.has_key?(row.details["nested"], "widget_id")
      assert row.details["nested"]["keep"] == "yes"
      assert row.details["player_name"] == "Alice"
    end

    test "a player id that maps to nobody is dropped, not left dangling" do
      owner = user_scope()
      importer = user_scope()
      original = fixture(owner)

      # A row about a player who was deleted after it was written - the
      # trail keeps the name, but there is no longer an id to remap.
      Audit.log(original.id, owner, "player.deleted", %{
        player_id: 999_999,
        player_name: "Gone"
      })

      assert {:ok, [imported]} = handoff(original, importer)
      [row] = audit_rows(imported.id)

      refute Map.has_key?(row.details, "player_id")
      assert row.details["player_name"] == "Gone"
    end

    test "an ordinary envelope brings no audit rows with it" do
      owner = user_scope()
      importer = user_scope()
      original = fixture(owner)
      Audit.log(original.id, owner, "player.created", %{player_name: "Alice"})

      envelope = TournamentExport.export_tournament(original)
      assert {:ok, [imported]} = TournamentImport.import(envelope, importer)

      assert audit_rows(imported.id) == []
    end

    test "restoring a snapshot never re-plays the trail into the tournament" do
      owner = user_scope()
      original = fixture(owner)
      Audit.log(original.id, owner, "player.created", %{player_name: "Alice"})

      restore(original)

      # A restore is this tournament's own past. Its trail never left, so
      # re-inserting the copy in the payload would double every row - and
      # the restore itself is an audited action, which is how the trail
      # records that it happened.
      assert length(audit_rows(original.id)) == 1
    end
  end

  describe "collaborators arrive as invitations, not as access" do
    test "email and role come across; the link, the token and the acceptance do not" do
      owner = user_scope()
      importer = user_scope()
      original = fixture(owner)

      accepted = invite(original, "helper@example.com")
      Repo.update!(Ecto.Changeset.change(accepted, status: "accepted", invite_token: nil))

      assert {:ok, [imported]} = handoff(original, importer)
      [row] = Tournaments.list_collaborators(imported)

      assert row.email == "helper@example.com"
      assert row.role == "editor"

      # Pending even though the source row was accepted. "Accepted" was a
      # grant made on another machine to an account this one cannot see.
      assert row.status == "pending"
      assert row.user_id == nil

      # A fresh token: the source's is a live bearer link and is unique
      # across the table, so re-using it would put the same one on two
      # machines.
      assert is_binary(row.invite_token)
      assert row.invite_token != accepted.invite_token
      assert row.tournament_id == imported.id

      # The source's own row is untouched - still accepted, still theirs.
      assert Repo.reload!(accepted).status == "accepted"
    end

    test "holding the invited email grants nothing until the invitation is accepted" do
      owner = user_scope()
      importer = user_scope()
      helper = user_scope()
      original = fixture(owner)

      invite(original, helper.user.email)
      assert {:ok, [imported]} = handoff(original, importer)

      # The whole decision in one assertion: importing a file must not hand
      # the tournament to whoever happens to hold that address here.
      refute imported.id in tournament_ids(helper)

      [row] = Tournaments.list_collaborators(imported)
      assert {:ok, _} = Tournaments.accept_invitation(helper, row.id)

      # And it is a real invitation in the ordinary flow, not a lookalike -
      # the same accept/decline path unlocks it.
      assert imported.id in tournament_ids(helper)
    end

    test "an invitation from a file can still be accepted through its own link" do
      owner = user_scope()
      importer = user_scope()
      helper = user_scope()
      original = fixture(owner)

      invite(original, helper.user.email)
      assert {:ok, [imported]} = handoff(original, importer)
      [row] = Tournaments.list_collaborators(imported)

      assert %{id: found_id} = Tournaments.find_invitation_by_token(row.invite_token)
      assert found_id == row.id
      assert {:ok, _} = Tournaments.accept_invitation(helper, row.invite_token)
    end

    test "an ordinary envelope brings no collaborators with it" do
      owner = user_scope()
      importer = user_scope()
      original = fixture(owner)
      invite(original, "helper@example.com")

      envelope = TournamentExport.export_tournament(original)
      assert {:ok, [imported]} = TournamentImport.import(envelope, importer)

      assert Tournaments.list_collaborators(imported) == []
    end

    test "a row with no email to invite is skipped, not fatal to the import" do
      owner = user_scope()
      importer = user_scope()
      original = fixture(owner)
      invite(original, "helper@example.com")

      envelope =
        original
        |> TournamentExport.export_tournament(include_handoff: true)
        |> update_in(["tournaments", Access.at(0), "collaborators"], fn rows ->
          [%{"role" => "editor"} | rows]
        end)

      assert {:ok, [imported]} = TournamentImport.import(envelope, importer)
      assert [%{email: "helper@example.com"}] = Tournaments.list_collaborators(imported)
    end

    test "restoring a snapshot does not re-invite the team" do
      owner = user_scope()
      original = fixture(owner)
      invite(original, "helper@example.com")

      restore(original)

      # The team never left, so restoring must not duplicate it - and a
      # second row for the same address would violate the table's own
      # unique index anyway.
      assert [%{email: "helper@example.com"}] = Tournaments.list_collaborators(original)
    end
  end

  # `restore_into!/2`'s contract: the caller has already deleted the old
  # contents and wraps the call in a transaction (see `Snapshots.restore/3`,
  # whose `wipe_contents/1` this mirrors). The payload here deliberately
  # carries the hand-off blocks, which a real snapshot's never does - the
  # point is that a restore ignores them even when they are in front of it.
  defp restore(tournament) do
    [entry] =
      tournament
      |> TournamentExport.export_tournament(include_handoff: true)
      |> Map.fetch!("tournaments")

    Repo.transaction(fn ->
      Repo.delete_all(from b in "byes", where: b.tournament_id == ^tournament.id)
      Repo.delete_all(from f in "forbidden_pairings", where: f.tournament_id == ^tournament.id)
      Repo.delete_all(from r in Round, where: r.tournament_id == ^tournament.id)
      Repo.delete_all(from p in Player, where: p.tournament_id == ^tournament.id)
      Repo.delete_all(from t in Team, where: t.tournament_id == ^tournament.id)

      TournamentImport.restore_into!(tournament, entry)
    end)
  end

  defp handoff(tournament, importer) do
    tournament
    |> TournamentExport.export_tournament(include_handoff: true)
    |> TournamentImport.import(importer)
  end

  defp audit_rows(tournament_id) do
    Repo.all(
      from a in AuditLog,
        where: a.tournament_id == ^tournament_id,
        order_by: [asc: a.inserted_at, asc: a.id]
    )
  end

  defp player_name(player_id), do: Repo.get!(Player, player_id).name

  defp tournament_ids(scope) do
    scope |> Tournaments.list_tournaments() |> Enum.map(fn {t, _count, _owner?} -> t.id end)
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
end
