defmodule PairingsEngine.TrfImportTest do
  # async: false — writes a whole tournament (players, rounds, pairings) via
  # a real transaction; same reason swar_import_test.exs and
  # trf_export_test.exs are serial (SQLite has a single writer).
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, Trf, TrfExport, TrfImport, Tournaments}
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

  ## ---------- forfeits & every bye code ----------

  # Hand-built TRF (via Trf.serialize/1, so exact column math is never our
  # problem) covering every result kind import needs to handle: a played
  # win/loss (R1, Alpha/Bravo), a single forfeit (R2, Alpha/Charlie), a
  # double forfeit (R3, Alpha/Delta), a played 0-0 (R4, Alpha/Echo), every
  # TRF bye code except U (Bravo: F round 2, H round 3, Z round 4), a
  # pairing-allocated ("U") bye (Charlie, round 1), and — Foxtrot — a
  # playing code ("1") whose declared opponent (rank 99) doesn't exist at
  # all, exercising the single-sided fallback.
  #
  # Blank placeholder games (`opponent_rank: nil, colour: nil, result: nil`)
  # pad a player's list up to the round index their one real game belongs
  # at — Trf's `place_games/2` numbers rounds by list position, not by any
  # explicit round field.
  defp forfeit_and_bye_trf do
    blank = %{opponent_rank: nil, colour: nil, result: nil}

    Trf.serialize(%{
      tournament: %{name: "Forfeits and Byes", type: "swiss"},
      players: [
        %{
          rank: 1,
          name: "Alpha",
          points: 2.0,
          games: [
            %{opponent_rank: 2, colour: "w", result: "1"},
            %{opponent_rank: 3, colour: "w", result: "+"},
            %{opponent_rank: 4, colour: "w", result: "-"},
            %{opponent_rank: 5, colour: "w", result: "0"}
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

    rounds =
      Repo.all(
        Ecto.Query.from(r in Round,
          where: r.tournament_id == ^tournament.id,
          order_by: r.number,
          preload: [:pairings]
        )
      )

    [r1, r2, r3, r4] = rounds

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
    # kind (OpenPairings has no separate full-point-bye type — see
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

  ## ---------- points cross-check warning ----------

  test "a player whose TRF points column disagrees with the recomputed total is reported in warnings" do
    trf =
      Trf.serialize(%{
        tournament: %{name: "Points Mismatch", type: "swiss"},
        players: [
          %{
            rank: 1,
            name: "Overclaimed",
            # Declares 5.0, but the only game below is a single win (1.0) —
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
  # Windows-1252 encoded, not UTF-8 — an accented name then arrives as raw
  # single-byte CP1252, invalid as UTF-8 on its own (see
  # `docs/trf-import.md`). Built at the byte level rather than through
  # `Trf.serialize/1` (which only ever emits valid UTF-8): a well-formed TRF
  # is serialized with an ASCII placeholder name, then those placeholder
  # bytes are swapped for the raw CP1252 bytes of the accented name —
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
    # "Gaëtan" — ë is Windows-1252/Latin-1 byte 0xEB.
    trf = trf_with_cp1252_name("Gaetan", <<"Ga", 0xEB, "tan">>)

    assert {:ok, tournament, _warnings} = TrfImport.import_text(trf, user_scope())
    [player] = Tournaments.list_players(tournament.id)
    assert player.name == "Gaëtan"
  end

  test "a CP1252-encoded TRF file with a u-umlaut imports as proper UTF-8" do
    # "Gürkan" — ü is Windows-1252/Latin-1 byte 0xFC.
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

  # Both sides claim a win — illegal per Trf.validate_games!/1's
  # @legal_result_pairs (a "1" can only pair with a "0"). Trf.serialize/1
  # itself refuses to produce this in one call (it validates the whole
  # roster up front), so each player's line is serialized alone — with no
  # opponent in that call's roster, the mutual check has nothing to compare
  # against and passes — then the two lines are combined by hand into one
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
    assert %Trf.ValidationError{} = reason
    assert TrfImport.error_message(reason) =~ "invalid result"
  end

  # <<0, 255, 1, 2, 3>> is not itself valid UTF-8 (0xFF alone is not a legal
  # UTF-8 lead byte), so this exercises the CP1252 fallback (see
  # `TrfImport`'s `decode_content/1`) rather than the plain-UTF-8 path.
  # `SwarImport.cp1252_decode/1` never itself fails — every byte 0x00-0xFF
  # has *some* Windows-1252 mapping — so this always reaches TRF parsing,
  # which then rejects it for having no "001" player lines, same as any
  # other non-TRF text; it never raises.
  test "binary garbage that isn't valid UTF-8 falls back to CP1252 decoding and still doesn't crash" do
    assert {:error, reason} = TrfImport.import_text(<<0, 255, 1, 2, 3>>)
    assert TrfImport.error_message(reason) =~ "Could not read this TRF file"
  end

  # Two "001" lines sharing the same starting rank: every downstream step
  # keys players by rank via Map.new/2 (create_players/2's players_by_rank,
  # build_round/1's by_rank), which silently keeps only the last entry for
  # a repeated key — without this guard, "Second" would land in the
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

    # Nothing was written — not even a rolled-back tournament row lingering.
    refute Repo.exists?(Ecto.Query.from(t in Tournament, where: t.name == "Duplicate Ranks"))
  end
end
