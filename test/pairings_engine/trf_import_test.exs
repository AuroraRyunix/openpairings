defmodule PairingsEngine.TrfImportTest do
  # async: false - writes a whole tournament (players, rounds, pairings) via
  # a real transaction; same reason swar_import_test.exs and
  # trf_export_test.exs are serial (SQLite has a single writer).
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, TrfExport, TrfImport, Tournaments}
  alias Ainalrami.Trf
  alias PairingsEngine.Pairing, as: PairingCtx
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing}
  alias PairingsEngine.Accounts.{Scope, User}

  # Lightweight stand-in for AccountsFixtures.user_scope_fixture/0, same as
  # swar_import_test.exs and tournaments_test.exs use.
  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  ## ---------- round-trip: export an existing tournament, re-import it ----------

  # 3 players, 2 paired rounds, same shape as TrfExportTest's own fixture:
  #   R1: Alice (w) 1-0 Bob      Carol -- bye (pairing-allocated)
  #   R2: Bob   (w) 1/2-1/2 Carol   Alice -- bye (pairing-allocated)
  defp seeded_tournament do
    tournament =
      Repo.insert!(%Tournament{
        name: "TRF Import Round-trip",
        type: "swiss",
        rounds_count: 2,
        federation: "BEL",
        city: "Ghent",
        round_dates: ["2026-01-01", "2026-01-02"]
      })

    alice =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Alice",
        fide_rating: 2000,
        fide_id: 111,
        pairing_number: 1
      })

    bob =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Bob",
        fide_rating: 1900,
        pairing_number: 2
      })

    carol =
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
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: "1-0"
    })

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 2,
      white_player_id: carol.id,
      black_player_id: nil,
      result: "bye"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 1,
      white_player_id: bob.id,
      black_player_id: carol.id,
      result: "1/2-1/2"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 2,
      white_player_id: alice.id,
      black_player_id: nil,
      result: "bye"
    })

    {tournament, %{alice: alice, bob: bob, carol: carol}}
  end

  test "round-trip: export then re-import preserves players, rounds, results and points" do
    {tournament, _} = seeded_tournament()
    assert {:ok, text} = TrfExport.export(tournament)

    assert {:ok, imported, warnings} = TrfImport.import_text(text, user_scope())
    assert warnings == []
    assert imported.id != tournament.id
    assert imported.name == "TRF Import Round-trip"
    assert imported.federation == "BEL"
    assert imported.city == "Ghent"
    assert imported.pairing_system == "swiss"
    assert imported.round_dates == ["2026-01-01", "2026-01-02"]

    players = Tournaments.list_players(imported.id)
    assert length(players) == 3

    alice = Enum.find(players, &(&1.name == "Alice"))
    bob = Enum.find(players, &(&1.name == "Bob"))
    carol = Enum.find(players, &(&1.name == "Carol"))
    assert alice.fide_id == 111
    assert alice.fide_rating == 2000
    assert alice.pairing_number == 1
    assert bob.pairing_number == 2
    assert carol.pairing_number == 3

    assert PairingCtx.paired_rounds_count(imported.id) == 2

    rows = PairingCtx.trf_player_rows(imported, players)
    alice_row = Enum.find(rows, &(&1.rank == 1))
    bob_row = Enum.find(rows, &(&1.rank == 2))
    carol_row = Enum.find(rows, &(&1.rank == 3))

    # Alice: win (1.0) + pairing-allocated bye (bye_value, default 1.0) = 2.0
    assert alice_row.points == 2.0
    # Bob: loss (0.0) + draw (0.5) = 0.5
    assert bob_row.points == 0.5
    # Carol: pairing-allocated bye (1.0) + draw (0.5) = 1.5
    assert carol_row.points == 1.5

    assert imported.status == "finished"
  end

  test "round-trip is idempotent w.r.t. TRF text: re-exporting the import matches the original" do
    {tournament, _} = seeded_tournament()
    assert {:ok, original_text} = TrfExport.export(tournament)

    assert {:ok, imported, _warnings} = TrfImport.import_text(original_text, user_scope())
    assert {:ok, reexported_text} = TrfExport.export(imported)

    original = Trf.parse(original_text)
    reexported = Trf.parse(reexported_text)

    to_comparable = fn parsed ->
      parsed.players
      |> Enum.map(&{&1.rank, String.trim(&1.name), &1.points, &1.games})
      |> Enum.sort()
    end

    assert to_comparable.(original) == to_comparable.(reexported)
  end

  ## ---------- round-trip: an actual round-robin schedule ----------
  ##
  ## No test anywhere exercised `TrfExport`/`TrfImport` against a real
  ## `PairingsEngine.RoundRobin`-paired tournament before - the Berger
  ## schedule (an odd player count's structural "requested-zero" bye
  ## included), varied results, and points must all still agree once the
  ## file has gone out and come back.

  test "round-trip: a real 5-player round-robin schedule (with its structural bye) preserves pairings and points" do
    tournament =
      Repo.insert!(%Tournament{
        name: "RR Round-trip",
        type: "roundrobin",
        pairing_system: "round_robin",
        rr_cycles: 1,
        rounds_count: 9,
        round_dates: for(n <- 1..5, do: "2026-0#{n}-0#{n}")
      })

    for {name, rating} <- [
          {"Alice", 2000},
          {"Bob", 1900},
          {"Carol", 1800},
          {"Dave", 1700},
          {"Eve", 1600}
        ] do
      {:ok, _} =
        Tournaments.create_player(tournament.id, %{
          tournament_id: tournament.id,
          name: name,
          fide_rating: rating
        })
    end

    assert {:ok, 5} = PairingsEngine.RoundRobin.pair_all_rounds(tournament)
    tournament = Repo.reload!(tournament)

    # Vary the results (win, draw, mixed) round by round rather than
    # rubber-stamping every board "1-0" - a stronger check on whether
    # points genuinely survive the round-trip rather than every game
    # happening to be worth the same amount.
    all_pairings =
      Round
      |> where(tournament_id: ^tournament.id)
      |> order_by(:number)
      |> Repo.all()
      |> Repo.preload(:pairings)
      |> Enum.flat_map(& &1.pairings)
      |> Enum.sort_by(& &1.id)

    all_pairings
    |> Enum.with_index()
    |> Enum.each(fn {pairing, i} ->
      result = Enum.at(["1-0", "1/2-1/2", "0-1"], rem(i, 3))
      {:ok, _} = Tournaments.update_pairing_result(pairing, result)
    end)

    original_points =
      tournament
      |> PairingCtx.trf_player_rows(Tournaments.list_players(tournament.id))
      |> Map.new(&{&1.name, &1.points})

    assert {:ok, text} = TrfExport.export(tournament)
    assert {:ok, imported, warnings} = TrfImport.import_text(text, user_scope())
    assert warnings == []

    # `type` (FIDE-report classification) round-trips via the 092 label,
    # and `pairing_system` now round-trips too: TRF26's `192` encodes which
    # system paired the boards, which TRF16 had no field for at all - so
    # until 0.48.0 every import came back a fresh Swiss-continuable
    # tournament whatever it had been. Both are asserted here because the
    # pair of them is the thing that changed.
    assert imported.type == "roundrobin"
    assert imported.pairing_system == "round_robin"
    assert imported.rr_cycles == 1

    assert PairingCtx.paired_rounds_count(imported.id) == 5

    imported_players = Tournaments.list_players(imported.id)
    assert length(imported_players) == 5

    imported_points =
      imported
      |> PairingCtx.trf_player_rows(imported_players)
      |> Map.new(&{&1.name, &1.points})

    assert imported_points == original_points

    # The structural bye: exactly one player per round, none twice, no
    # `pairings` row for it - same shape check `round_robin_test.exs`
    # exercises pre-export, now checked survives the TRF round-trip too.
    imported_byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^imported.id,
          select: %{player_id: b.player_id, round: b.round, type: b.type}
      )

    assert length(imported_byes) == 5
    assert Enum.all?(imported_byes, &(&1.type == "requested-zero"))
    assert imported_byes |> Enum.map(& &1.round) |> Enum.sort() == [1, 2, 3, 4, 5]

    bye_player_ids = Enum.map(imported_byes, & &1.player_id) |> Enum.sort()
    assert Enum.uniq(bye_player_ids) == bye_player_ids

    # Re-exporting the import must match the original TRF text exactly
    # (same idempotency check the Swiss fixture above already makes).
    assert {:ok, reexported_text} = TrfExport.export(imported)

    to_comparable = fn parsed ->
      parsed.players
      |> Enum.map(&{&1.rank, String.trim(&1.name), &1.points, &1.games})
      |> Enum.sort()
    end

    assert to_comparable.(Trf.parse(text)) == to_comparable.(Trf.parse(reexported_text))
  end

  ## ---------- forfeits & every bye code ----------

  # Hand-built TRF (via Trf.serialize/1, so exact column math is never our
  # problem) covering every result kind import needs to handle: a played
  # win/loss (R1, Alpha/Bravo), a single forfeit (R2, Alpha/Charlie), a
  # double forfeit (R3, Alpha/Delta), a played 0-0 (R4, Alpha/Echo), every
  # TRF bye code except U (Bravo: F round 2, H round 3, Z round 4), a
  # pairing-allocated ("U") bye (Charlie, round 1), and - Foxtrot - a
  # playing code ("1") whose declared opponent (rank 99) doesn't exist at
  # all, exercising the single-sided fallback.
  #
  # Blank placeholder games (`opponent_rank: nil, colour: nil, result: nil`)
  # pad a player's list up to the round index their one real game belongs
  # at - Trf's `place_games/2` numbers rounds by list position, not by any
  # explicit round field.
  #
  # Round 5 (Alpha/Golf, "="/"0") is VCL.13's asymmetric result - an
  # arbiter's disciplinary point adjustment on an otherwise-drawn game.
  test "a blank interior round still gets a Round row, so numbering stays contiguous" do
    # A round with no results anywhere is legal input, and skipping it left
    # Round rows numbered 1 and 3 with no 2. Several readers index rounds
    # POSITIONALLY rather than by number - games_per_player/3 maps over the
    # ordered rows and Trf.place_games/2 writes them back with
    # Enum.with_index(1) - so round 3's game came out in round 2's columns
    # while the dates still came from rounds 1 and 2.
    blank = %{opponent_rank: nil, colour: nil, result: nil}

    text =
      Trf.serialize(%{
        tournament: %{name: "Hole", type: "swiss"},
        players: [
          %{
            rank: 1,
            name: "Alpha",
            points: 2.0,
            games: [
              %{opponent_rank: 2, colour: "w", result: "1"},
              blank,
              %{opponent_rank: 2, colour: "b", result: "1"}
            ]
          },
          %{
            rank: 2,
            name: "Bravo",
            points: 0.0,
            games: [
              %{opponent_rank: 1, colour: "b", result: "0"},
              blank,
              %{opponent_rank: 1, colour: "w", result: "0"}
            ]
          }
        ]
      })

    assert {:ok, imported, _warnings} = TrfImport.import_text(text, user_scope())

    numbers =
      Round
      |> where(tournament_id: ^imported.id)
      |> Repo.all()
      |> Enum.map(& &1.number)
      |> Enum.sort()

    assert numbers == [1, 2, 3],
           "round 2 is blank but interior - skipping it leaves a hole: #{inspect(numbers)}"
  end

  defp forfeit_and_bye_trf do
    blank = %{opponent_rank: nil, colour: nil, result: nil}

    Trf.serialize(%{
      tournament: %{name: "Forfeits and Byes", type: "swiss"},
      players: [
        %{
          rank: 1,
          name: "Alpha",
          points: 2.5,
          games: [
            %{opponent_rank: 2, colour: "w", result: "1"},
            %{opponent_rank: 3, colour: "w", result: "+"},
            %{opponent_rank: 4, colour: "w", result: "-"},
            %{opponent_rank: 5, colour: "w", result: "0"},
            %{opponent_rank: 7, colour: "w", result: "="}
          ]
        },
        %{
          rank: 2,
          name: "Bravo",
          points: 1.5,
          games: [
            %{opponent_rank: 1, colour: "b", result: "0"},
            %{opponent_rank: nil, colour: nil, result: "F"},
            %{opponent_rank: nil, colour: nil, result: "H"},
            %{opponent_rank: nil, colour: nil, result: "Z"}
          ]
        },
        %{
          rank: 3,
          name: "Charlie",
          points: 1.0,
          games: [
            %{opponent_rank: nil, colour: nil, result: "U"},
            %{opponent_rank: 1, colour: "b", result: "-"}
          ]
        },
        %{
          rank: 4,
          name: "Delta",
          points: 0.0,
          games: [blank, blank, %{opponent_rank: 1, colour: "b", result: "-"}]
        },
        %{
          rank: 5,
          name: "Echo",
          points: 0.0,
          games: [blank, blank, blank, %{opponent_rank: 1, colour: "b", result: "0"}]
        },
        %{
          rank: 6,
          name: "Foxtrot",
          points: 1.0,
          games: [%{opponent_rank: 99, colour: "w", result: "1"}]
        },
        %{
          rank: 7,
          name: "Golf",
          points: 0.0,
          games: [blank, blank, blank, blank, %{opponent_rank: 1, colour: "b", result: "0"}]
        }
      ]
    })
  end

  test "forfeits and every TRF bye code import to the right pairing/bye rows" do
    assert {:ok, tournament, warnings} =
             TrfImport.import_text(forfeit_and_bye_trf(), user_scope())

    assert warnings == []

    players = Tournaments.list_players(tournament.id)
    alpha = Enum.find(players, &(&1.name == "Alpha"))
    bravo = Enum.find(players, &(&1.name == "Bravo"))
    charlie = Enum.find(players, &(&1.name == "Charlie"))
    delta = Enum.find(players, &(&1.name == "Delta"))
    echo = Enum.find(players, &(&1.name == "Echo"))
    foxtrot = Enum.find(players, &(&1.name == "Foxtrot"))
    golf = Enum.find(players, &(&1.name == "Golf"))

    rounds =
      Repo.all(
        Ecto.Query.from(r in Round,
          where: r.tournament_id == ^tournament.id,
          order_by: r.number,
          preload: [:pairings]
        )
      )

    [r1, r2, r3, r4, r5] = rounds

    find_for = fn round, player ->
      Enum.find(
        round.pairings,
        &(&1.white_player_id == player.id or &1.black_player_id == player.id)
      )
    end

    # Round 1: Alpha beats Bravo (played win/loss); Charlie gets a
    # pairing-allocated ("U") bye; Foxtrot's claimed win against a
    # nonexistent opponent (rank 99) falls back to the same kind of bye.
    r1_pairing = find_for.(r1, alpha)
    assert r1_pairing.white_player_id == alpha.id
    assert r1_pairing.black_player_id == bravo.id
    assert r1_pairing.result == "1-0"

    assert find_for.(r1, charlie).result == "bye"
    assert find_for.(r1, foxtrot).result == "bye"

    # Round 2: Alpha forfeit-wins vs Charlie ("+"/"-" -> "1-0FF"); Bravo's
    # unpaired "F" (full-point bye) collapses to the same "bye" Pairing row
    # kind (OpenPairings has no separate full-point-bye type - see
    # docs/trf-import.md).
    r2_pairing = find_for.(r2, alpha)
    assert r2_pairing.white_player_id == alpha.id
    assert r2_pairing.black_player_id == charlie.id
    assert r2_pairing.result == "1-0FF"
    assert find_for.(r2, bravo).result == "bye"

    # Round 3: Alpha/Delta double forfeit ("-"/"-" -> "0-0FF").
    r3_pairing = find_for.(r3, alpha)
    assert r3_pairing.white_player_id == alpha.id
    assert r3_pairing.black_player_id == delta.id
    assert r3_pairing.result == "0-0FF"

    # Round 4: Alpha/Echo played 0-0 ("0"/"0" -> "0-0", distinct from the
    # double-forfeit "0-0FF" above).
    r4_pairing = find_for.(r4, alpha)
    assert r4_pairing.white_player_id == alpha.id
    assert r4_pairing.black_player_id == echo.id
    assert r4_pairing.result == "0-0"

    # Round 5: Alpha/Golf, "="/"0" -> "1/2-0" - VCL.13's asymmetric result.
    r5_pairing = find_for.(r5, alpha)
    assert r5_pairing.white_player_id == alpha.id
    assert r5_pairing.black_player_id == golf.id
    assert r5_pairing.result == "1/2-0"

    byes =
      Repo.all(
        Ecto.Query.from(b in "byes",
          where: b.tournament_id == ^tournament.id,
          select: %{player_id: b.player_id, round: b.round, type: b.type}
        )
      )

    # Bravo: "H" (round 3) -> requested-half, "Z" (round 4) -> requested-zero.
    assert Enum.any?(
             byes,
             &(&1.player_id == bravo.id and &1.round == 3 and &1.type == "requested-half")
           )

    assert Enum.any?(
             byes,
             &(&1.player_id == bravo.id and &1.round == 4 and &1.type == "requested-zero")
           )
  end

  ## ---------- the engine's whole result vocabulary reaches single_sided/2 ----------

  # `single_sided/2` decides what an unpaired round entry BECOMES, and it
  # does so from a private three-way list of result codes - the second
  # private copy of the played-code vocabulary this module has carried.
  # The first one, `@playing_codes`, drifted: it was written as `~w(1 = 0 + -)`
  # and never learned TRF16's unrated twins `W`/`D`/`L`, so an unrated game
  # stopped being a game at all.
  #
  # This drives EVERY code `Ainalrami.Trf` accepts through a real import and
  # asserts what each one becomes. It is deliberately built from
  # `Trf.playing_codes/0 ++ Trf.bye_codes/0` rather than from a list written
  # out here: a hand-written list would need updating by hand the day the
  # engine grows a code, which is the exact failure being guarded against.
  # A code added upstream and not bucketed here fails this test (and the
  # module's own compile-time check) instead of raising FunctionClauseError
  # partway through an arbiter's file.
  #
  # The three expected buckets are stated as POINT VALUES because that is
  # what the buckets mean - a full point, a half, or nothing - and the
  # declared points column below is checked against the recomputed total by
  # the importer itself, so `warnings == []` is a second, independent
  # assertion that each code landed on a row worth what the code says.
  @full_point_codes ~w(U F 1 + W)
  @half_point_codes ~w(H = D)
  @zero_point_codes ~w(Z 0 - L)

  test "every result code the engine accepts is bucketed by the value it stands for" do
    codes = @full_point_codes ++ @half_point_codes ++ @zero_point_codes

    assert Enum.sort(codes) == Enum.sort(Trf.playing_codes() ++ Trf.bye_codes()),
           "this test no longer covers Ainalrami.Trf's vocabulary - " <>
             "engine: #{inspect(Trf.playing_codes() ++ Trf.bye_codes())}, here: #{inspect(codes)}"

    # One player per code, each unpaired in round 1. A bye code is unpaired
    # by carrying no opponent; a PLAYING code cannot be serialized that way
    # (`Trf.validate_game!/5` refuses "0000 - 1" as an illegal row), so it
    # points at rank 99, which no player has - the dangling reference
    # `single_sided/2`'s doc calls out, and the shape a TRF06-vintage file
    # uses for a bye.
    players =
      codes
      |> Enum.with_index(1)
      |> Enum.map(fn {code, rank} ->
        game =
          if code in Trf.bye_codes(),
            do: %{opponent_rank: nil, colour: nil, result: code},
            else: %{opponent_rank: 99, colour: "w", result: code}

        %{
          rank: rank,
          name: "Code #{code}",
          points: expected_points(code),
          games: [game]
        }
      end)

    trf =
      Trf.serialize(%{tournament: %{name: "Whole Vocabulary", type: "swiss"}, players: players})

    assert {:ok, tournament, warnings} = TrfImport.import_text(trf, user_scope())
    assert warnings == []

    imported = Tournaments.list_players(tournament.id)

    [round] =
      Repo.all(
        Ecto.Query.from(r in Round,
          where: r.tournament_id == ^tournament.id,
          preload: [:pairings]
        )
      )

    byes =
      Repo.all(
        Ecto.Query.from(b in "byes",
          where: b.tournament_id == ^tournament.id,
          select: %{player_id: b.player_id, type: b.type}
        )
      )

    for code <- codes do
      player = Enum.find(imported, &(&1.name == "Code #{code}"))
      assert player, "#{code} did not import as a player at all"

      pairing = Enum.find(round.pairings, &(&1.white_player_id == player.id))
      bye = Enum.find(byes, &(&1.player_id == player.id))

      case bucket(code) do
        :full ->
          # OpenPairings has one "full points, no game" row: a pairing with
          # no black player (see docs/trf-import.md).
          assert pairing, "#{code} should have become a pairing-row bye"
          assert pairing.black_player_id == nil
          assert pairing.result == "bye"
          refute bye, "#{code} should not also produce a byes-table row"

        :half ->
          assert bye, "#{code} should have become a byes-table row"
          assert bye.type == "requested-half"
          refute pairing, "#{code} should not also produce a pairing row"

        :zero ->
          assert bye, "#{code} should have become a byes-table row"
          assert bye.type == "requested-zero"
          refute pairing, "#{code} should not also produce a pairing row"
      end
    end
  end

  defp bucket(code) do
    cond do
      code in @full_point_codes -> :full
      code in @half_point_codes -> :half
      code in @zero_point_codes -> :zero
    end
  end

  defp expected_points(code) do
    case bucket(code) do
      :full -> 1.0
      :half -> 0.5
      :zero -> 0.0
    end
  end

  ## ---------- TRF06 (FIDE's Annexure-B, 2006) ----------

  # Column-identical to TRF16 (verified against both the 2006 and 2016
  # specs directly) - the one real difference is TRF06 predates the
  # F/H/U/Z bye codes: a bye is a dangling playing code against opponent
  # 0000, and a genuinely blank round ("not paired") can be followed by
  # real games in later rounds (a late entrant). VCL.11 recommends, not
  # requires, supporting this - no separate importer needed, `Trf.parse/1`
  # already tolerates both shapes.
  #
  # Built with exact 1-indexed column placement (not hand-typed spacing,
  # which is exactly how the earlier "opponentless bye" bug surfaced while
  # verifying this by hand) - mirrors the `place_col/3` the parser's own
  # tests use, now in Ainalrami's `test/ainalrami/trf_test.exs`.
  describe "a result the file records as not known" do
    # `?` is ITDX's unknown-result code, which the letter sent to FIDE TEC on
    # 2026-09-08 commits this software to supporting. Ainalrami reads it as of
    # v0.25.0 and deliberately keeps it out of `playing_codes/0`, because that
    # list says what may be WRITTEN. Nothing here may write a result nobody
    # knows - but this importer has to recognise it as a GAME, or it repeats
    # the `W`/`D`/`L` drift documented in `trf_import.ex`: a code missing from
    # that guard stops being a game and is reinterpreted as a bye, losing the
    # opponent. `?` would have gone one worse and raised FunctionClauseError
    # in `single_sided/2`, which has no fallback clause.
    test "keeps the pairing, leaves the result blank, and says so" do
      scope = user_scope()

      lines = [
        trf06_player_line(1, "Alpha, One", "0.0", {2, "w", "?"}, nil),
        trf06_player_line(2, "Bravo, Two", "0.0", {1, "b", "?"}, nil)
      ]

      trf = Enum.join(lines, "\r\n") <> "\r\n"

      assert {:ok, tournament, warnings} = TrfImport.import_text(trf, scope)

      round =
        tournament.id |> Tournaments.list_rounds() |> hd() |> Repo.preload(:pairings)

      # One real board with two seats - NOT a bye, which is what a code
      # missing from the game guard silently becomes.
      assert [pairing] = round.pairings
      refute is_nil(pairing.white_player_id)
      refute is_nil(pairing.black_player_id)

      # And no result invented for it. "" is this app's "not recorded".
      assert pairing.result in [nil, ""]

      assert Enum.any?(warnings, &(&1 =~ "not known"))
    end

    test "an ordinary result in the same file is untouched" do
      scope = user_scope()
      # The control. A change to the game guard that broke normal imports
      # would still pass the test above.
      lines = [
        trf06_player_line(1, "Alpha, One", "1.0", {2, "w", "1"}, nil),
        trf06_player_line(2, "Bravo, Two", "0.0", {1, "b", "0"}, nil)
      ]

      trf = Enum.join(lines, "\r\n") <> "\r\n"

      assert {:ok, tournament, warnings} = TrfImport.import_text(trf, scope)

      round =
        tournament.id |> Tournaments.list_rounds() |> hd() |> Repo.preload(:pairings)

      assert [pairing] = round.pairings
      assert pairing.result == "1-0"

      refute Enum.any?(warnings, &(&1 =~ "not known"))
    end
  end

  defp place_trf_col(line, position, text) do
    text = to_string(text)
    needed = position - 1 + String.length(text)
    line = if String.length(line) < needed, do: String.pad_trailing(line, needed), else: line
    {before, rest} = String.split_at(line, position - 1)
    {_, after_} = String.split_at(rest, String.length(text))
    before <> text <> after_
  end

  defp trf06_round_block(line, round_number, opponent, colour, result) do
    base = 92 + (round_number - 1) * 10

    line
    |> place_trf_col(
      base,
      (opponent && String.pad_leading(to_string(opponent), 4)) || "0000"
    )
    |> place_trf_col(base + 5, colour || "-")
    |> place_trf_col(base + 7, result || "")
  end

  defp trf06_player_line(rank, name, points, round1, round2) do
    line =
      ""
      |> place_trf_col(1, "001")
      |> place_trf_col(5, String.pad_leading(to_string(rank), 4))
      |> place_trf_col(15, name)
      |> place_trf_col(81, String.pad_leading(points, 4))
      |> place_trf_col(86, String.pad_leading(to_string(rank), 4))

    line =
      if round1,
        do: trf06_round_block(line, 1, elem(round1, 0), elem(round1, 1), elem(round1, 2)),
        else: line

    if round2,
      do: trf06_round_block(line, 2, elem(round2, 0), elem(round2, 1), elem(round2, 2)),
      else: line
  end

  test "a genuine TRF06-vintage file (no F/H/U/Z bye codes, a dangling code for a bye) imports correctly" do
    lines = [
      "012 TRF06 Vintage Test",
      "032 BEL",
      "062    3",
      "092 Individual: Swiss System",
      # Alpha beats Bravo in round 1, then a dangling "1" (win-value bye,
      # TRF06's only way to express a full-point bye) in round 2.
      trf06_player_line(1, "Alpha, One", "2.0", {2, "w", "1"}, {nil, nil, "1"}),
      # Bravo loses to Alpha, then loses to Charlie.
      trf06_player_line(2, "Bravo, Two", "0.0", {1, "b", "0"}, {3, "w", "0"}),
      # Charlie is a late entrant: round 1 genuinely blank ("not paired"),
      # a real game in round 2 - the exact case that used to get silently
      # dropped by the old parse_games/1.
      trf06_player_line(3, "Charlie, Three", "1.0", nil, {2, "b", "1"})
    ]

    trf06 = Enum.join(lines, "\r\n") <> "\r\n"

    assert {:ok, tournament, warnings} = TrfImport.import_text(trf06, user_scope())
    assert warnings == []

    players = Tournaments.list_players(tournament.id)
    alpha = Enum.find(players, &(&1.name == "Alpha, One"))
    bravo = Enum.find(players, &(&1.name == "Bravo, Two"))
    charlie = Enum.find(players, &(&1.name == "Charlie, Three"))

    rounds =
      Repo.all(
        Ecto.Query.from(r in Round,
          where: r.tournament_id == ^tournament.id,
          order_by: r.number,
          preload: [:pairings]
        )
      )

    assert [r1, r2] = rounds

    find_for = fn round, player ->
      Enum.find(
        round.pairings,
        &(&1.white_player_id == player.id or &1.black_player_id == player.id)
      )
    end

    r1_pairing = find_for.(r1, alpha)
    assert r1_pairing.white_player_id == alpha.id
    assert r1_pairing.black_player_id == bravo.id
    assert r1_pairing.result == "1-0"

    # Charlie's genuinely blank round 1 means no pairing at all for round 1
    # - not a bye, not an error, simply absent (a late entrant).
    refute find_for.(r1, charlie)

    # Round 2: Alpha's dangling win-value code becomes a pairing-row bye
    # (same representation F/U already collapse into - no black player);
    # Bravo loses to Charlie.
    alpha_r2 = find_for.(r2, alpha)
    assert alpha_r2.result == "bye"
    assert alpha_r2.black_player_id == nil

    bravo_r2 = find_for.(r2, bravo)
    assert bravo_r2.white_player_id == bravo.id
    assert bravo_r2.black_player_id == charlie.id
    assert bravo_r2.result == "0-1"
  end

  ## ---------- points cross-check warning ----------

  test "a player whose TRF points column disagrees with the recomputed total is reported in warnings" do
    trf =
      Trf.serialize(%{
        tournament: %{name: "Points Mismatch", type: "swiss"},
        players: [
          %{
            rank: 1,
            name: "Overclaimed",
            # Declares 5.0, but the only game below is a single win (1.0) -
            # a stale/incorrect points column, same as a late correction an
            # arbiter forgot to re-total.
            points: 5.0,
            games: [%{opponent_rank: 2, colour: "w", result: "1"}]
          },
          %{
            rank: 2,
            name: "Accurate",
            points: 0.0,
            games: [%{opponent_rank: 1, colour: "b", result: "0"}]
          }
        ]
      })

    assert {:ok, _tournament, warnings} = TrfImport.import_text(trf, user_scope())

    assert [%{player_name: "Overclaimed", trf_points: 5.0, computed_points: 1.0}] = warnings
  end

  ## ---------- encoding fallback (CP1252 / BOM) ----------

  # Real-world TRF files from Windows chess software are frequently
  # Windows-1252 encoded, not UTF-8 - an accented name then arrives as raw
  # single-byte CP1252, invalid as UTF-8 on its own (see
  # `docs/trf-import.md`). Built at the byte level rather than through
  # `Trf.serialize/1` (which only ever emits valid UTF-8): a well-formed TRF
  # is serialized with an ASCII placeholder name, then those placeholder
  # bytes are swapped for the raw CP1252 bytes of the accented name -
  # same byte length, so the fixed-width name column (TRF cols 15-47) is
  # unaffected.
  defp trf_with_cp1252_name(placeholder, cp1252_bytes) do
    text =
      Trf.serialize(%{
        tournament: %{name: "CP1252 Import", type: "swiss"},
        players: [%{rank: 1, name: placeholder, points: 0.0, games: []}]
      })

    [before, rest] = :binary.split(text, placeholder)
    before <> cp1252_bytes <> rest
  end

  test "a CP1252-encoded TRF file (accented name as raw Windows-1252 bytes) imports as proper UTF-8" do
    # "Gaëtan" - ë is Windows-1252/Latin-1 byte 0xEB.
    trf = trf_with_cp1252_name("Gaetan", <<"Ga", 0xEB, "tan">>)

    assert {:ok, tournament, _warnings} = TrfImport.import_text(trf, user_scope())
    [player] = Tournaments.list_players(tournament.id)
    assert player.name == "Gaëtan"
  end

  test "a CP1252-encoded TRF file with a u-umlaut imports as proper UTF-8" do
    # "Gürkan" - ü is Windows-1252/Latin-1 byte 0xFC.
    trf = trf_with_cp1252_name("Gurkan", <<"G", 0xFC, "rkan">>)

    assert {:ok, tournament, _warnings} = TrfImport.import_text(trf, user_scope())
    [player] = Tournaments.list_players(tournament.id)
    assert player.name == "Gürkan"
  end

  test "a UTF-8 TRF file with a leading BOM imports cleanly" do
    text =
      Trf.serialize(%{
        tournament: %{name: "BOM Import", type: "swiss"},
        players: [%{rank: 1, name: "Boûtchon", points: 0.0, games: []}]
      })

    trf = <<0xEF, 0xBB, 0xBF>> <> text

    assert {:ok, tournament, _warnings} = TrfImport.import_text(trf, user_scope())
    [player] = Tournaments.list_players(tournament.id)
    assert player.name == "Boûtchon"
  end

  ## ---------- error paths: never a 500 ----------

  test "garbage content that parses to zero players is a friendly error, not a crash" do
    assert {:error, reason} =
             TrfImport.import_text("this is not a TRF file\r\njust some text\r\n")

    assert TrfImport.error_message(reason) =~ "Could not read this TRF file"
  end

  test "empty content is a friendly error" do
    assert {:error, reason} = TrfImport.import_text("")
    assert TrfImport.error_message(reason) =~ "Could not read this TRF file"
  end

  # Both sides claim a win - illegal per Trf.validate_games!/1's
  # @legal_result_pairs (a "1" can only pair with a "0"). Trf.serialize/1
  # itself refuses to produce this in one call (it validates the whole
  # roster up front), so each player's line is serialized alone - with no
  # opponent in that call's roster, the mutual check has nothing to compare
  # against and passes - then the two lines are combined by hand into one
  # file, which only becomes "mutually illegal" once both are parsed
  # together.
  defp illegal_combo_trf do
    only_p1 =
      Trf.serialize(%{
        tournament: %{name: "Illegal", type: "swiss"},
        players: [
          %{
            rank: 1,
            name: "Player One",
            points: 1.0,
            games: [%{opponent_rank: 2, colour: "w", result: "1"}]
          }
        ]
      })

    only_p2 =
      Trf.serialize(%{
        tournament: %{name: "Illegal", type: "swiss"},
        players: [
          %{
            rank: 2,
            name: "Player Two",
            points: 1.0,
            games: [%{opponent_rank: 1, colour: "b", result: "1"}]
          }
        ]
      })

    p2_line = only_p2 |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "001"))

    only_p1 <> p2_line <> "\r\n"
  end

  test "an illegal mutual result combination surfaces as a ValidationError, formatted as a friendly message" do
    assert {:error, reason} = TrfImport.import_text(illegal_combo_trf())
    assert %Ainalrami.Trf.ValidationError{} = reason
    assert TrfImport.error_message(reason) =~ "invalid result"
  end

  # <<0, 255, 1, 2, 3>> is not itself valid UTF-8 (0xFF alone is not a legal
  # UTF-8 lead byte), so this exercises the CP1252 fallback (see
  # `TrfImport`'s `decode_content/1`) rather than the plain-UTF-8 path.
  # `PairingsEngine.Encoding.cp1252_decode/1` never itself fails - every byte
  # 0x00-0xFF has *some* Windows-1252 mapping - so this always reaches TRF
  # parsing, which then rejects it for having no "001" player lines, same as
  # any other non-TRF text; it never raises.
  test "binary garbage that isn't valid UTF-8 falls back to CP1252 decoding and still doesn't crash" do
    assert {:error, reason} = TrfImport.import_text(<<0, 255, 1, 2, 3>>)
    assert TrfImport.error_message(reason) =~ "Could not read this TRF file"
  end

  # Two "001" lines sharing the same starting rank: every downstream step
  # keys players by rank via Map.new/2 (create_players/2's players_by_rank,
  # build_round/1's by_rank), which silently keeps only the last entry for
  # a repeated key - without this guard, "Second" would land in the
  # database as an orphan player row (referenced by nobody's games) while
  # "First"'s own rank slot is silently handed to "Second". Caught before
  # any row is written, so this is a clean rollback and a friendly flash,
  # never a partially-imported tournament or a 500.
  test "a TRF file with two players sharing the same starting rank is a friendly error, not a silent orphan" do
    trf =
      Trf.serialize(%{
        tournament: %{name: "Duplicate Ranks", type: "swiss"},
        players: [
          %{rank: 1, name: "First", points: 0.0, games: []},
          %{rank: 1, name: "Second", points: 0.0, games: []}
        ]
      })

    assert {:error, reason} = TrfImport.import_text(trf, user_scope())
    assert TrfImport.error_message(reason) =~ "duplicate starting rank"
    assert TrfImport.error_message(reason) =~ "1"

    # Nothing was written - not even a rolled-back tournament row lingering.
    refute Repo.exists?(Ecto.Query.from(t in Tournament, where: t.name == "Duplicate Ranks"))
  end

  ## ---------- build_structs/1 (pure, no Repo) ----------

  test "build_structs/1 builds the same field values import_text/2 persists, without touching the database" do
    {tournament, _} = seeded_tournament()
    assert {:ok, text} = TrfExport.export(tournament)

    tournament_count_before = Repo.aggregate(Tournament, :count)
    player_count_before = Repo.aggregate(Player, :count)

    assert {:ok, {built_tournament, built_players}} = TrfImport.build_structs(text)

    assert tournament_count_before == Repo.aggregate(Tournament, :count)
    assert player_count_before == Repo.aggregate(Player, :count)

    assert built_tournament.id == nil
    assert built_tournament.name == "TRF Import Round-trip"
    assert built_tournament.federation == "BEL"
    assert built_tournament.city == "Ghent"
    assert built_tournament.round_dates == ["2026-01-01", "2026-01-02"]

    assert length(built_players) == 3
    alice = Enum.find(built_players, &(&1.name == "Alice"))
    assert alice.id == nil
    assert alice.fide_id == 111
    assert alice.fide_rating == 2000
    assert alice.pairing_number == 1
  end

  test "build_structs/1 returns the same friendly error as import_text/2 for unparseable content" do
    assert {:error, reason} =
             TrfImport.build_structs("this is not a TRF file\r\njust some text\r\n")

    assert TrfImport.error_message(reason) =~ "Could not read this TRF file"
  end

  test "build_structs/1 decodes CP1252-encoded content the same way import_text/2 does" do
    trf = trf_with_cp1252_name("Gaetan", <<"Ga", 0xEB, "tan">>)

    assert {:ok, {_tournament, players}} = TrfImport.build_structs(trf)
    assert [%{name: "Gaëtan"}] = players
  end

  ## ---------- round verification (FIDE VCL4THP Q54) ----------

  # One builder for every verification test below, so that an illegal file
  # and its control differ in the thing under test and in NOTHING else. A
  # fixture written out twice by hand can pass for a reason nobody looked
  # at - the two files differing somewhere other than the round the test
  # names - and a check that cannot be shown to stay quiet is not evidence
  # that it fires.
  #
  # `number_of_rounds: 5` on every fixture is deliberate. None of these
  # rounds is then the tournament's LAST, so FIDE's final-round exception
  # (two players above half the score so far may meet despite an absolute
  # colour clash) can never fire and quietly change an answer underneath a
  # test that is about something else.
  defp verification_trf(games_by_rank, tournament \\ %{}, opts \\ []) do
    names = ~w(Alpha Bravo Charlie Delta Echo Foxtrot)

    players =
      for {rank, games} <- Enum.sort(games_by_rank) do
        %{
          rank: rank,
          name: "#{Enum.at(names, rank - 1)}, Player",
          # Computed rather than written by hand, so no fixture also trips
          # the points cross-check and puts a second kind of warning in
          # what these tests are counting.
          points: Enum.reduce(games, 0.0, &(&2 + Trf.points_for_game(&1))),
          games: games
        }
      end

    Trf.serialize(
      %{
        tournament:
          Map.merge(
            %{name: "Verification", type: "swiss", number_of_rounds: 5},
            tournament
          ),
        players: players
      },
      opts
    )
  end

  defp game(opponent, colour, result),
    do: %{opponent_rank: opponent, colour: colour, result: result}

  defp pairing_bye, do: %{opponent_rank: nil, colour: nil, result: "U"}

  defp illegal_rounds(warnings), do: Enum.filter(warnings, &(&1.kind == :illegal_round))

  # 4 players, 2 rounds, every game a draw - so all four are on the same
  # score for round 2 and sit in one bracket, where every pair's legality
  # is actually examined. Round 1 is 1 v 2 and 3 v 4 in both versions; only
  # round 2 differs.
  defp rematch_fixture(:illegal),
    do: %{
      1 => [game(2, "w", "="), game(2, "b", "=")],
      2 => [game(1, "b", "="), game(1, "w", "=")],
      3 => [game(4, "w", "="), game(4, "b", "=")],
      4 => [game(3, "b", "="), game(3, "w", "=")]
    }

  defp rematch_fixture(:legal),
    do: %{
      1 => [game(2, "w", "="), game(3, "b", "=")],
      2 => [game(1, "b", "="), game(4, "w", "=")],
      3 => [game(4, "w", "="), game(1, "w", "=")],
      4 => [game(3, "b", "="), game(2, "b", "=")]
    }

  test "a round that pairs two players who have already met is reported" do
    assert {:ok, _tournament, warnings} =
             TrfImport.import_text(verification_trf(rematch_fixture(:illegal)), user_scope())

    findings = illegal_rounds(warnings)

    assert length(findings) == 2, "expected both rematched boards: #{inspect(findings)}"
    assert Enum.all?(findings, &(&1.reason == :rematch))
    assert Enum.all?(findings, &(&1.round == 2))
    assert Enum.all?(findings, &(&1.met_in_round == 1))

    assert Enum.sort(Enum.map(findings, & &1.players)) == [
             ["Alpha, Player", "Bravo, Player"],
             ["Charlie, Player", "Delta, Player"]
           ]
  end

  # The control the test above needs to mean anything: the same four
  # players, the same round 1, a round 2 that is merely a different legal
  # pairing rather than the one this engine would have chosen. Anything
  # reported here would mean the check fires on the fixture's shape, or on
  # disagreement with our own pairing, rather than on the rematch.
  test "the same file paired legally reports nothing" do
    assert {:ok, _tournament, warnings} =
             TrfImport.import_text(verification_trf(rematch_fixture(:legal)), user_scope())

    assert illegal_rounds(warnings) == []
  end

  # 6 players, 3 rounds, every game a draw. Rounds 1 and 2 give players
  # 1-3 White twice and players 4-6 Black twice, which is FIDE's own
  # definition of an ABSOLUTE colour preference (C.04.3: the same colour in
  # the two latest rounds, and a colour difference past +/-1). Round 3 is
  # the only thing that differs between the two versions.
  defp colour_fixture(round3) do
    %{
      1 => [game(4, "w", "="), game(6, "w", "=")],
      2 => [game(5, "w", "="), game(4, "w", "=")],
      3 => [game(6, "w", "="), game(5, "w", "=")],
      4 => [game(1, "b", "="), game(2, "b", "=")],
      5 => [game(2, "b", "="), game(3, "b", "=")],
      6 => [game(3, "b", "="), game(1, "b", "=")]
    }
    |> Map.new(fn {rank, games} -> {rank, games ++ [Map.fetch!(colour_round3(round3), rank)]} end)
  end

  # 1 v 2 (both due Black) and 5 v 6 (both due White) are the two illegal
  # boards; 3 v 4 pairs a Black-due player with a White-due one and is
  # there to prove the check is not simply flagging every board in a round
  # it dislikes. None of the three is a rematch.
  defp colour_round3(:illegal),
    do: %{
      1 => game(2, "w", "="),
      2 => game(1, "b", "="),
      3 => game(4, "w", "="),
      4 => game(3, "b", "="),
      5 => game(6, "w", "="),
      6 => game(5, "b", "=")
    }

  defp colour_round3(:legal),
    do: %{
      1 => game(5, "b", "="),
      2 => game(6, "b", "="),
      3 => game(4, "b", "="),
      4 => game(3, "w", "="),
      5 => game(1, "w", "="),
      6 => game(2, "w", "=")
    }

  test "a round that pairs two players who are both due the same colour is reported" do
    assert {:ok, _tournament, warnings} =
             TrfImport.import_text(verification_trf(colour_fixture(:illegal)), user_scope())

    findings = illegal_rounds(warnings)

    assert length(findings) == 2, "expected exactly the two clashing boards: #{inspect(findings)}"
    assert Enum.all?(findings, &(&1.reason == :colour))
    assert Enum.all?(findings, &(&1.round == 3))

    by_players = Map.new(findings, &{&1.players, &1.colour})

    # The colour each pair was due, which is what makes the message
    # readable - and what proves the finding is about the right two boards
    # rather than about any two boards.
    assert by_players == %{
             ["Alpha, Player", "Bravo, Player"] => "b",
             ["Echo, Player", "Foxtrot, Player"] => "w"
           }
  end

  test "the same six players paired so that no colour clashes reports nothing" do
    assert {:ok, _tournament, warnings} =
             TrfImport.import_text(verification_trf(colour_fixture(:legal)), user_scope())

    assert illegal_rounds(warnings) == []
  end

  # `dialect: :trf26` because a round-limited prohibition is a `260` record
  # and TRF16's `XXP` has nowhere to put the range - which is the whole
  # point of the control below.
  defp forbidden_trf(first, last) do
    verification_trf(
      rematch_fixture(:legal),
      %{forbidden_pairs: [{[1, 3], first, last}]},
      dialect: :trf26
    )
  end

  test "a round that pairs two players the arbiter prohibited is reported" do
    assert {:ok, _tournament, warnings} =
             TrfImport.import_text(forbidden_trf(1, 5), user_scope())

    assert [finding] = illegal_rounds(warnings)
    assert finding.reason == :forbidden
    assert finding.round == 2
    assert finding.players == ["Alpha, Player", "Charlie, Player"]
  end

  # The control, and it is a sharper one than "a different pair": the same
  # two players, the same board, the same file but for the two digits that
  # limit the prohibition to round 1. They meet in round 2, where the rule
  # no longer applies, so there is nothing to report. This is what proves
  # the check reads the file's own `260` ranges rather than the widened
  # whole-event rows `import_forbidden_pairings/3` writes to the database.
  test "a prohibition that has expired by the round they meet in reports nothing" do
    assert {:ok, _tournament, warnings} =
             TrfImport.import_text(forbidden_trf(1, 1), user_scope())

    assert illegal_rounds(warnings) == []
  end

  # 5 players, so every round has a pairing-allocated bye. Round 1 is the
  # same in both: 1 beats 2, 3 beats 4, and Echo takes the bye. In round 2
  # Echo takes it again, which C.2 forbids outright.
  defp bye_fixture(:illegal),
    do: %{
      1 => [game(2, "w", "1"), game(3, "b", "=")],
      2 => [game(1, "b", "0"), game(4, "w", "=")],
      3 => [game(4, "w", "1"), game(1, "w", "=")],
      4 => [game(3, "b", "0"), game(2, "b", "=")],
      5 => [pairing_bye(), pairing_bye()]
    }

  defp bye_fixture(:legal),
    do: %{
      1 => [game(2, "w", "1"), game(3, "b", "=")],
      2 => [game(1, "b", "0"), game(5, "w", "=")],
      3 => [game(4, "w", "1"), game(1, "w", "=")],
      4 => [game(3, "b", "0"), pairing_bye()],
      5 => [pairing_bye(), game(2, "b", "=")]
    }

  test "a player given the pairing-allocated bye twice is reported" do
    assert {:ok, _tournament, warnings} =
             TrfImport.import_text(verification_trf(bye_fixture(:illegal)), user_scope())

    assert [finding] = illegal_rounds(warnings)
    assert finding.reason == :bye
    assert finding.round == 2
    assert finding.players == ["Echo, Player"]
    assert finding.bye_reason == :pairing_bye
  end

  test "the same round with the bye moved to a player who has not had one reports nothing" do
    assert {:ok, _tournament, warnings} =
             TrfImport.import_text(verification_trf(bye_fixture(:legal)), user_scope())

    assert illegal_rounds(warnings) == []
  end

  # Requirement one of Q54, and the one worth stating as its own test: an
  # arbiter recovering a historical event needs the tournament far more
  # than they need our opinion of it. The illegal round is recreated
  # exactly as the file records it.
  test "a file with an illegal round still imports in full" do
    assert {:ok, tournament, warnings} =
             TrfImport.import_text(verification_trf(rematch_fixture(:illegal)), user_scope())

    assert illegal_rounds(warnings) != []

    rounds =
      Round
      |> where(tournament_id: ^tournament.id)
      |> order_by(:number)
      |> Repo.all()
      |> Repo.preload(:pairings)

    assert Enum.map(rounds, & &1.number) == [1, 2]
    assert Enum.map(rounds, &length(&1.pairings)) == [2, 2]

    by_number = Map.new(rounds, &{&1.number, &1})
    names = Map.new(Repo.all(where(Player, tournament_id: ^tournament.id)), &{&1.id, &1.name})

    round_two_boards =
      by_number[2].pairings
      |> Enum.map(&Enum.sort([names[&1.white_player_id], names[&1.black_player_id]]))
      |> Enum.sort()

    assert round_two_boards == [
             ["Alpha, Player", "Bravo, Player"],
             ["Charlie, Player", "Delta, Player"]
           ]
  end

  # Requirement three: verify only what can be judged. A round robin's
  # schedule is fixed before a move is played and a double one rematches
  # every pair by design, so judging it against the Dutch criteria would
  # report a correct file as broken - which is how an arbiter learns to
  # ignore the notice that matters.
  test "a file that says it is not a Dutch Swiss is not judged by Dutch-system rules" do
    illegal = rematch_fixture(:illegal)

    # The same illegal round 2 throughout. The baseline says it is found at
    # all, so a silent variant below is the gate working rather than the
    # fixture having gone stale.
    assert {:ok, _tournament, swiss} =
             TrfImport.import_text(verification_trf(illegal), user_scope())

    assert illegal_rounds(swiss) != []

    # `092` in words, the only signal a TRF16 file carries.
    assert {:ok, _tournament, by_label} =
             TrfImport.import_text(
               verification_trf(illegal, %{type: "roundrobin"}),
               user_scope()
             )

    assert illegal_rounds(by_label) == []

    # `192` in FIDE's own code, which decides wherever it is present -
    # including for the systems this app has none of. `CUSTOM_SWISS` is
    # what this app's own export writes for a Keizer tournament.
    assert {:ok, _tournament, by_code} =
             TrfImport.import_text(
               verification_trf(illegal, %{type_code: "CUSTOM_SWISS"}),
               user_scope()
             )

    assert illegal_rounds(by_code) == []

    # `_BAKU` is a note about acceleration, not a different system, so it
    # must not switch the check off - which is the failure a naive
    # membership test on the raw code would have.
    assert {:ok, _tournament, baku} =
             TrfImport.import_text(
               verification_trf(illegal, %{type_code: "FIDE_DUTCH_2026_BAKU"}),
               user_scope()
             )

    assert illegal_rounds(baku) != []
  end
end
