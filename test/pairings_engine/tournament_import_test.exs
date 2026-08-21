defmodule PairingsEngine.TournamentImportTest do
  # Each round-trip test performs a full transactional import (many
  # sequential inserts held on one connection) on top of an equally
  # write-heavy fixture - the single busiest writer in the suite. Kept
  # `async: false` to keep that write burst from contending with the rest
  # of the async pool for SQLite's single writer lock (see the
  # `busy_timeout` comment in config/test.exs for the general tradeoff).
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, Standings, TournamentExport, TournamentImport, Tournaments}
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
end
