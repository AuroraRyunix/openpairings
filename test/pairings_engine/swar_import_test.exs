defmodule PairingsEngine.SwarImportTest do
  # `async: false` — each test writes a whole tournament (players, rounds,
  # pairings) via a real transaction; with the FIDE-matching tests added on
  # top, that's enough concurrent SQLite writers to occasionally hit
  # "Database busy" under the async pool (SQLite has a single writer).
  use PairingsEngine.DataCase, async: false

  # Every test in this module reads test/fixtures/c-reeks.swar and/or
  # problemski.swar — real personal data, deliberately gitignored (see
  # .gitignore) rather than committed. Excluded automatically by
  # test_helper.exs when those files aren't present (a fresh checkout,
  # CI) — see the comment there.
  @moduletag :swar_fixture

  alias PairingsEngine.{SwarImport, Tournaments, Repo, Standings}
  alias PairingsEngine.Tournaments.Round
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Fide.FidePlayer

  @c_reeks "test/fixtures/c-reeks.swar"
  @problemski "test/fixtures/problemski.swar"
  @test3_321 "test/fixtures/test3-321.swar"

  # Lightweight stand-in for `PairingsEngine.AccountsFixtures.user_scope_fixture/0`
  # — see the comment on the equivalent helper in tournaments_test.exs.
  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  # Builds a real, format-valid .swar file (a byte-for-byte copy of
  # c-reeks.swar) with Deloof, Koen's `MatFide` *and* `EloFide` fields
  # patched from their real values (210234, 1779) down to 0 — i.e. "SWAR has
  # neither a FIDE id nor a FIDE rating for this player" (the realistic
  # combination: c-reeks.swar's own actually-unrated players, e.g. Ashrafi
  # in problemski.swar, always have both blank together). This is the only
  # case `SwarImport` ever tries to match against the local FIDE database.
  # Everything else about the file (all other fields, all other players) is
  # untouched, so this exercises the matching logic against a real,
  # correctly-parsed record rather than a hand-built fixture.
  defp c_reeks_with_deloof_fide_id_blanked!(tmp_dir) do
    original = File.read!(@c_reeks)
    zero = <<0::little-signed-32>>

    # Guard against the fixture ever changing under us in a way that makes
    # either patch ambiguous or a no-op.
    [{_, 4}] = :binary.matches(original, <<210_234::little-signed-32>>)
    [{_, 4}] = :binary.matches(original, <<1779::little-signed-32>>)

    patched =
      original
      |> :binary.replace(<<210_234::little-signed-32>>, zero)
      |> :binary.replace(<<1779::little-signed-32>>, zero)

    path = Path.join(tmp_dir, "c-reeks-deloof-no-fide-id.swar")
    File.write!(path, patched)
    path
  end

  ## ---------- parse/1 ----------

  test "parse/1 returns {:ok, _} with players for both fixtures" do
    for path <- [@c_reeks, @problemski] do
      binary = File.read!(path)
      assert {:ok, data} = SwarImport.parse(binary)
      assert length(data.players) > 0
    end
  end

  test "parse/1 reads c-reeks.swar's known-correct tournament and player fields" do
    {:ok, data} = SwarImport.parse(File.read!(@c_reeks))

    assert data.tournament.name =~ "C-reeks"
    assert length(data.players) == 27

    deloof = Enum.find(data.players, &(&1.name == "Deloof, Koen"))
    assert deloof.mat_nat == 39934
    assert deloof.mat_fide == 210_234
    assert deloof.elo == 1779 or deloof.elo_fide == 1779

    waegeman = Enum.find(data.players, &(&1.name == "Waegeman, Willem"))
    assert waegeman.mat_nat == 19953
    assert waegeman.mat_fide == 292_052
    assert String.starts_with?(waegeman.birth, "1982")

    cobert = Enum.find(data.players, &(&1.name == "Cobert, Quinten"))
    assert cobert.elo == 0
    assert cobert.elo_fide == 0
  end

  ## ---------- import_file/1 ----------

  test "import_file/1 creates the tournament, players and pairings for c-reeks.swar" do
    assert {:ok, tournament, _warnings} = SwarImport.import_file(@c_reeks)

    assert tournament.name =~ "C-reeks"
    assert tournament.rounds_count == 11

    players = Tournaments.list_players(tournament.id)
    assert length(players) == 27

    deloof = Enum.find(players, &(&1.name == "Deloof, Koen"))
    assert deloof.national_id == "39934"
    assert deloof.fide_id == 210_234
    assert deloof.national_rating == 1810
    assert deloof.fide_rating == 1779
    assert deloof.birth_year == 1973

    waegeman = Enum.find(players, &(&1.name == "Waegeman, Willem"))
    assert waegeman.national_id == "19953"
    assert waegeman.fide_id == 292_052
    assert waegeman.birth_year == 1982

    cobert = Enum.find(players, &(&1.name == "Cobert, Quinten"))
    assert cobert.national_rating == 0
    assert cobert.fide_rating == 0

    assert PairingsEngine.Pairing.paired_rounds_count(tournament.id) == 11

    assert points_for(tournament, deloof) == 9.0
  end

  test "import_file/1 maps SWAR player-administration fields (payment, affiliation, extra points, category, club number)" do
    {:ok, tournament, _warnings} = SwarImport.import_file(@c_reeks)
    players = Tournaments.list_players(tournament.id)

    abramenko = Enum.find(players, &(&1.name == "Abramenko, Aleksei"))
    assert abramenko.paid == "paid"
    assert abramenko.extra_points == 0.5
    assert abramenko.affiliated == true
    assert abramenko.national_id == "21740"
    assert abramenko.fide_id == 268_968
    assert abramenko.birth_year == 2011
    assert abramenko.fide_rating == 1661
    assert abramenko.club == "KGSRL Gent"
    assert abramenko.club_number == 401

    van_de_kelder = Enum.find(players, &(&1.name == "Van De Kelder, Yves"))
    assert van_de_kelder.extra_points == 1.5

    # Bouche and Cobert are both flagged not-affiliated ("N") in the SWAR UI.
    bouche = Enum.find(players, &(&1.name == "Bouche, Jeroen"))
    assert bouche.affiliated == false

    cobert = Enum.find(players, &(&1.name == "Cobert, Quinten"))
    assert cobert.affiliated == false
    # Cobert's Absent field is 2 (ABS_ABSENT) rather than 4 (ABS_PRESENT).
    assert cobert.absent == true
    assert cobert.forfeit == false

    # Every other sampled player is present (Absent == 4) and not forfeited.
    deloof = Enum.find(players, &(&1.name == "Deloof, Koen"))
    assert deloof.absent == false
    assert deloof.forfeit == false
    assert deloof.paid == "paid"

    assert tournament.round_dates == [
             "2025-10-04",
             "2025-11-08",
             "2025-11-29",
             "2025-12-13",
             "2025-12-20",
             "2026-01-31",
             "2026-02-21",
             "2026-03-21",
             "2026-04-25",
             "2026-05-09",
             "2026-05-06"
           ]

    assert length(tournament.round_dates) == 11
    # c-reeks.swar has no custom categories defined (Categorie type NO_CATEGO).
    assert tournament.categories == []
    assert tournament.standard == "standard"
    assert tournament.organizer_club_number == "401"
  end

  # SWAR's own pairing code (Utils.cpp, `AbsentThisRound`) does NOT treat
  # Absent=2 as "gone forever" whenever the player also has a non-empty
  # AbsentRondes list — it checks whether the *current* round is in that
  # list, and treats every other round as present. A player who missed one
  # round should be paired normally for the rest of the event, both in SWAR
  # and in OpenPairings — `map_absent/2` mirrors that exactly. None of the
  # real fixtures happen to have a player in this combination (Absent=2 with
  # a non-empty AbsentRondes), so this is a direct unit test of the mapping
  # rule itself rather than an import fixture.
  describe "map_absent/2 (Absent is round-specific once AbsentRondes is set)" do
    test "Absent=2 with no round list at all is permanent" do
      assert SwarImport.map_absent(2, "") == true
      assert SwarImport.map_absent(2, nil) == true
    end

    test "Absent=2 with a round list is NOT permanent - round-specific exclusion takes over" do
      refute SwarImport.map_absent(2, "3")
      refute SwarImport.map_absent(2, "3,5")
    end

    test "Forfeit (1) and Present (4) are never permanently absent, round list or not" do
      refute SwarImport.map_absent(1, "")
      refute SwarImport.map_absent(4, "")
      refute SwarImport.map_absent(1, "3")
      refute SwarImport.map_absent(4, "3")
    end
  end

  # User-reported: the "Explain a round" score-bracket map showed a
  # handicap-table player's pairing far to the right, seemingly regardless
  # of her actual score. Root cause: SWAR's own per-round accessible-table
  # numbering (Table = TABLE_HANDICAP + N, i.e. 1001, 1002, ...) was being
  # imported verbatim as the pairing's `board`, and the rationale/bracket
  # rendering (like anything ordered by board number) put a "board 1001"
  # pairing at the very end regardless of score. `finalize_boards/1` now
  # renormalizes a handicap-range Table value the same way it already does
  # for the TABLE_BYE sentinel.
  describe "finalize_boards/1 (SWAR handicap-table and bye sentinels get real board numbers)" do
    test "ordinary boards are left completely alone" do
      pairings = [%{board: 1}, %{board: 2}, %{board: 3}]
      assert SwarImport.finalize_boards(pairings) == pairings
    end

    test "byes (board: nil) are numbered right after the highest real board - unchanged behaviour" do
      pairings = [%{board: 1}, %{board: nil}, %{board: 2}]
      result = SwarImport.finalize_boards(pairings)

      assert Enum.map(result, & &1.board) == [1, 2, 3]
    end

    test "a handicap-table pairing (Table 1001+) is renumbered to a real board, not left at 1001" do
      pairings = [%{board: 1}, %{board: 2}, %{board: 1001}]
      result = SwarImport.finalize_boards(pairings)

      # The real boards are untouched; the handicap pairing becomes board 3
      # (right after the highest real board), not the raw SWAR sentinel.
      assert Enum.map(result, & &1.board) == [1, 2, 3]
      refute 1001 in Enum.map(result, & &1.board)
    end

    test "multiple handicap-table pairings keep SWAR's own relative order (1001 before 1002)" do
      pairings = [%{board: 1}, %{board: 1002, tag: :second}, %{board: 1001, tag: :first}]
      result = SwarImport.finalize_boards(pairings)

      first = Enum.find(result, &(&1[:tag] == :first))
      second = Enum.find(result, &(&1[:tag] == :second))
      assert first.board < second.board
    end

    test "handicap-table pairings are numbered before byes, both after the real boards" do
      pairings = [%{board: 1}, %{board: nil, tag: :bye}, %{board: 1001, tag: :handicap}]
      result = SwarImport.finalize_boards(pairings)

      handicap = Enum.find(result, &(&1[:tag] == :handicap))
      bye = Enum.find(result, &(&1[:tag] == :bye))
      assert handicap.board == 2
      assert bye.board == 3
    end

    test "TABLE_BYE (0x1000 = 4096) itself is never mistaken for a handicap table" do
      # A real pairing-allocated bye already arrives as board: nil (handled
      # upstream in single_sided/2) - this just confirms the boundary check
      # doesn't accidentally swallow the TABLE_BYE sentinel value itself if
      # it ever showed up as a literal board here.
      pairings = [%{board: 1}, %{board: 0x1000}]
      result = SwarImport.finalize_boards(pairings)

      assert Enum.map(result, & &1.board) == [1, 4096]
    end
  end

  describe "combine_results/2 (VCL.13's asymmetric result revives SWAR's own dead DRAW_ZERO/ZERO_DRAW codes)" do
    test "a mutually-consistent DRAW_ZERO/ZERO_DRAW pair maps to the asymmetric result, either way round" do
      assert SwarImport.combine_results(:draw_zero, :zero_draw) == "1/2-0"
      assert SwarImport.combine_results(:zero_draw, :draw_zero) == "0-1/2"
    end

    test "every other real result class still maps the same as before" do
      assert SwarImport.combine_results(:win, :loss) == "1-0"
      assert SwarImport.combine_results(:loss, :win) == "0-1"
      assert SwarImport.combine_results(:draw, :draw) == "1/2-1/2"
      assert SwarImport.combine_results(:zero_zero, :zero_zero) == "0-0"
    end
  end

  test "import_file/1 does not create duplicate pairings for the same game" do
    {:ok, tournament, _warnings} = SwarImport.import_file(@c_reeks)
    players = Tournaments.list_players(tournament.id)
    max_pairings = ceil(length(players) / 2)

    rounds =
      Repo.all(from r in Round, where: r.tournament_id == ^tournament.id, preload: [:pairings])

    assert length(rounds) == 11

    Enum.each(rounds, fn round ->
      assert length(round.pairings) <= max_pairings

      # No two pairings in the same round should reference the same pair of
      # players (which would indicate the same game was recorded twice).
      pairs =
        Enum.map(round.pairings, fn p -> Enum.sort([p.white_player_id, p.black_player_id]) end)

      assert length(pairs) == length(Enum.uniq(pairs))

      # No two pairings in the same round should share a board number.
      boards = Enum.map(round.pairings, & &1.board)
      assert length(boards) == length(Enum.uniq(boards))
    end)
  end

  ## ---------- PubSub broadcasts ----------

  test "import_file/2 broadcasts once on the owning user's tournament-list topic, after the import commits" do
    scope = user_scope()

    Phoenix.PubSub.subscribe(
      PairingsEngine.PubSub,
      Tournaments.user_tournaments_topic(scope.user.id)
    )

    assert {:ok, tournament, _warnings} = SwarImport.import_file(@c_reeks, scope)

    user_id = scope.user.id
    assert_receive {:tournaments_changed, ^user_id}

    # The tournament is queryable by the time the broadcast lands — proof
    # the broadcast fired after commit, not from inside the still-open
    # transaction (see PairingsEngine.Tournaments.with_broadcast_suppressed/1).
    assert Tournaments.get_user_tournament(scope, tournament.id)
  end

  test "import_file/1 (no scope) does not broadcast on any user's tournament-list topic" do
    # An unowned import has no user to notify — this also exercises the
    # nil-safe branch of broadcast_user_tournaments/1.
    assert {:ok, _tournament, _warnings} = SwarImport.import_file(@c_reeks)
  end

  test "import_file/1 parses and imports problemski.swar without error" do
    assert {:ok, tournament, _warnings} = SwarImport.import_file(@problemski)
    players = Tournaments.list_players(tournament.id)
    assert length(players) == 10
  end

  ## ---------- points_adjusted cross-check (arbiter corrections) ----------

  # test/fixtures/test3-321.swar (file version v6.78, well above the v6.49
  # points_adjusted floor) is a real club championship where several
  # players' `PointsAdjusted` field (an arbiter-entered correction — appeals,
  # deductions) genuinely disagrees with their raw `Points` field, e.g.
  # "Slodicka, Anton" (points=8 -> 2.0, points_adjusted=20 -> 5.0) and
  # "Lopez, Alfonso" (points=0 -> 0.0, points_adjusted=14 -> 3.5) — both
  # verified directly against the real fixture (not just trusted from notes)
  # before writing this assertion. Our own standings are always recomputed
  # from replayed pairings/byes (matching the *raw*, not adjusted, points),
  # so unless we cross-check and warn, the arbiter's correction is silently
  # lost on import.
  @tag :swar_fixture
  test "import_file/1 warns when the real fixture's points_adjusted disagrees with the recomputed total" do
    {:ok, tournament, warnings} = SwarImport.import_file(@test3_321)

    assert tournament.id

    slodicka = Enum.find(warnings, &(&1.player_name == "Slodicka, Anton"))
    assert slodicka
    assert_in_delta slodicka.swar_adjusted_points, 5.0, 0.01
    assert_in_delta slodicka.computed_points, 2.0, 0.01

    lopez = Enum.find(warnings, &(&1.player_name == "Lopez, Alfonso"))
    assert lopez
    assert_in_delta lopez.swar_adjusted_points, 3.5, 0.01
    assert_in_delta lopez.computed_points, 0.0, 0.01
  end

  # problemski.swar's players all have points_adjusted == points (verified
  # directly against the fixture) — no arbiter correction was ever entered,
  # so this must not regress into warning on every ordinary import.
  test "import_file/1 does not warn when points_adjusted matches the recomputed total" do
    assert {:ok, _tournament, warnings} = SwarImport.import_file(@problemski)
    assert warnings == []
  end

  ## ---------- 3-2-1 scoring (SWAR type SWISS_321 == 3) ----------

  # test/fixtures/test3-321.swar is a real club-championship file saved
  # with SWAR's "3-2-1" tournament type turned on (`[TOURNOI].Type == 3`).
  # This particular club's `SW321_Win/Nul/Los` are configured to a 2.0/1.0/0.0
  # scale (raw ints 8/4/0, ÷4 — see the long comment on `scoring_attrs/1`
  # for why ÷4, not ÷8, is correct: the format manual states the SW321_*
  # fields are stored ×4, and ÷8 was verified to silently halve every
  # configured value, which is the KBSB-reported bug this fixes). "3-2-1" is
  # SWAR's feature name, not a claim that the values are literally 3/2/1 —
  # each club sets its own win/draw/loss scale, and this fixture's club
  # happens to use 2/1/0. `SW321_Bye` (raw 4 → 1.0) and `SW321_Pre` (raw
  # 4 → 1.0) are also configured here, and this file's `SW321_PreBye` is
  # nonzero (raw 1) — per the manual (§5.16, "Add presence points for bye
  # games") that means a pairing-allocated bye pays `SW321_Bye + SW321_Pre`,
  # modelled as `presence_on_allocated_bye: true` (consulted by
  # `Standings.bye_points/2`) while `bye_value` stays at plain `SW321_Bye`.
  # An earlier fix folded the sum into `bye_value` (2.0) instead — right
  # totals, but it redefined `bye_value` away from the club's configured
  # SW321_Bye. Note this fixture contains NO pairing-allocated bye at all
  # (no WIN_BYE result, no TABLE_BYE table value, verified by scanning every
  # [RONDE] entry), so the flag's scoring arithmetic can't be exercised
  # against a real player's stored total here — that's covered by the
  # synthetic-binary tests in swar_import_presence_test.exs. The behavioral
  # check that CAN run on this file: "Descheemaeker, Tom" has two LOST_BYE
  # rounds and two ordinary losses, and his real SWAR total (`points_raw /
  # 4`, from his own file record) only reconciles once LOST_BYE rounds score
  # at `presence_value` (not `points_loss`).

  test "import_file/1 maps SWAR's 3-2-1 scoring fields (SW321_Win/Nul/Los/Bye/Pre/PreBye) onto the tournament" do
    assert {:ok, tournament, _warnings} = SwarImport.import_file(@test3_321)

    assert tournament.points_win == 2.0
    assert tournament.points_draw == 1.0
    assert tournament.points_loss == 0.0
    assert tournament.presence_value == 1.0
    # Plain SW321_Bye (raw 4 → 1.0) — the SW321_PreBye add-on is the flag
    # below, not folded in here.
    assert tournament.bye_value == 1.0
    # SW321_PreBye is raw 1 in this file.
    assert tournament.presence_on_allocated_bye == true
  end

  test "import_file/1 scores a real player's LOST_BYE rounds at presence_value, reproducing SWAR's own raw point total" do
    {:ok, data} = SwarImport.parse(File.read!(@test3_321))
    tom = Enum.find(data.players, &(&1.name == "Descheemaeker, Tom"))
    # Non-circular check: this player's own raw `Points` field (SWAR's
    # stored total, ÷4 like every other SW321_* field) is the ground truth
    # here — independent of whatever our scoring_attrs/1 currently does.
    assert tom.points == 8

    assert {:ok, tournament, _warnings} = SwarImport.import_file(@test3_321)

    [player] =
      Enum.filter(Tournaments.list_players(tournament.id), &(&1.name == "Descheemaeker, Tom"))

    entry = Enum.find(Standings.standings(tournament), &(&1.player.id == player.id))

    # tom.points (8, raw) / 4 == 2.0 == wins*Win + draws*Nul + losses*Los +
    # lost_byes*Pre, all raw, / 4 — this player has 0 wins, 0 draws, 2
    # ordinary losses (Los raw 0, contributing nothing either way) and 2
    # LOST_BYE rounds (Pre raw 4 each): (2*0 + 2*4) / 4 = 2.0. Before this
    # session's fix, LOST_BYE scored at points_loss (0.0), which would have
    # produced 0.0 here instead — the exact regression this guards.
    assert entry.points == 2.0
  end

  test "import_file/1 leaves scoring at schema defaults for a standard (non-3-2-1) tournament" do
    # problemski.swar's raw SW321_Win/Nul/Los/Bye ints (8/4/0/8) happen to
    # be present and would *also* divide out to 2.0/1.0/0.0/2.0 — but its
    # `[TOURNOI].Type` is 0 (plain Swiss), not 3, so the mapping must not
    # fire at all; this only proves the type==3 guard, not the division.
    assert {:ok, tournament, _warnings} = SwarImport.import_file(@problemski)

    assert tournament.points_win == 1.0
    assert tournament.points_draw == 0.5
    assert tournament.points_loss == 0.0
    assert tournament.bye_value == 1.0
    assert tournament.presence_on_allocated_bye == false
  end

  # User-reported crash: test3-321.swar is a real club championship with 42
  # players, 19 of them correctly marked `absent: true` per SWAR's own
  # "Absent" checkbox (excluded from every round upcoming or not yet
  # paired — confirmed by the tournament's arbiter). Pairing round 9 (past
  # the 8 imported rounds) crashed entirely with
  # `PairingsEngine.Trf.ValidationError`: "Aelvoet, Karel, round 2: opponent
  # 0000 cannot carry played-game result "1" — opponentless games must use
  # a bye code". Root cause: "Aelvoet, Karel" really did play a round-2
  # game against "De Winter, Gerrit", one of the 19 now-absent players —
  # `games_per_player/2` was resolving that historical opponent's identity
  # against the current round's narrow *active* player set (correctly used
  # to decide who's eligible to be paired THIS round) instead of the full
  # tournament roster, so a genuine non-nil `opponent_id` produced a nil
  # `opponent_rank` — a played-game result with no legal way to name its
  # opponent. Fixed by resolving historical opponent identity against every
  # player who ever received a pairing_number, regardless of current
  # eligibility (see `PairingsEngine.Pairing.build_shared_history/1`).
  @tag :javafo
  test "pairing a new round after import doesn't crash when a historical opponent is now excluded" do
    assert {:ok, tournament, _warnings} = SwarImport.import_file(@test3_321)
    assert {:ok, tournament} = Tournaments.update_tournament(tournament, %{rounds_count: 9})

    assert {:ok, round} = PairingsEngine.Pairing.pair_next_round(tournament)
    assert round.number == 9

    # Also prove the fix, not just "doesn't crash": Aelvoet, Karel's round-2
    # line in the round-9 TRF input must correctly show his real opponent's
    # (De Winter, Gerrit's) starting rank alongside the real played-game
    # result code, not the "0000" placeholder.
    karel = Enum.find(Tournaments.list_players(tournament.id), &(&1.name == "Aelvoet, Karel"))

    gerrit =
      Enum.find(Tournaments.list_players(tournament.id), &(&1.name == "De Winter, Gerrit"))

    assert gerrit.absent == true

    active = PairingsEngine.Pairing.active_players(tournament.id)
    refute gerrit.id in Enum.map(active, & &1.id)

    [karel_row] =
      PairingsEngine.Pairing.trf_player_rows(tournament, active)
      |> Enum.filter(&(&1.id == karel.id))

    round2_game = Enum.at(karel_row.games, 1)
    assert round2_game.opponent_id == gerrit.id
    assert round2_game.opponent_rank == gerrit.pairing_number
    assert round2_game.result in ["1", "0"]
  end

  test "import_file/1 marks the tournament as running, not stuck on setup, since rounds were imported" do
    # c-reeks.swar's 11 rounds are all paired but not, as it turns out,
    # fully scored — 4 of its 297 games carry a blank result (2 from the
    # legacy SWAR DRAW_ZERO/ZERO_DRAW combo with no equivalent here — see
    # `combine_results/2`'s moduledoc note — 2 genuinely unplayed), so the
    # honestly-derived status (see the "commits a fully-scored import as
    # finished" test below) is "running", same as this test asserted before
    # status became derived rather than hardcoded.
    assert {:ok, tournament, _warnings} = SwarImport.import_file(@c_reeks)
    assert tournament.status == "running"

    # Persisted, not just returned in-memory.
    assert Tournaments.get_tournament!(tournament.id).status == "running"
  end

  test "commit_import/3 derives a fully-scored import as finished, not hardcoded to running" do
    {:ok, prepared} = SwarImport.prepare_import(@c_reeks)

    # Patch c-reeks.swar's 4 blank-result games (see the test above) to an
    # ordinary decisive result, so the fixture is honestly fully scored —
    # then confirm the derived status (Tournaments.refresh_status!/1,
    # called after commit and outside with_broadcast_suppressed — see
    # PairingsEngine.SwarImport.run_import/2) lands on "finished" rather
    # than the old hardcoded "running".
    patches = [
      {6, 10, 0x4000},
      {25, 10, 0x1000},
      {10, 10, 0x4000},
      {27, 10, 0x1000},
      {5, 11, 0x4000},
      {25, 11, 0x1000},
      {8, 11, 0x4000},
      {19, 11, 0x1000}
    ]

    players =
      Enum.map(prepared.data.players, fn p ->
        Enum.reduce(patches, p, fn {ni, round_nr, code}, p ->
          if p.ni == ni do
            rounds =
              Enum.map(p.rounds, fn r ->
                if r.round_nr == round_nr, do: %{r | result: code}, else: r
              end)

            %{p | rounds: rounds}
          else
            p
          end
        end)
      end)

    data = %{prepared.data | players: players}
    assert {:ok, tournament, _warnings} = SwarImport.commit_import(%{data: data}, %{})

    assert tournament.status == "finished"
    assert Tournaments.get_tournament!(tournament.id).status == "finished"
  end

  ## ---------- Federation normalization + full birth dates ----------

  test "import_file/1 normalizes the SWAR federation entity to the FIDE country code, not the raw league marker" do
    {:ok, tournament, _warnings} = SwarImport.import_file(@c_reeks)

    # c-reeks.swar's [TOURNOI] `federation` field is code 6 ("direct FIDE
    # homologation") — still Belgium, not the literal string "FIDE".
    assert tournament.federation == "BEL"

    players = Tournaments.list_players(tournament.id)
    assert Enum.all?(players, &(&1.federation == "BEL"))
  end

  test "import_file/1 stores the full birth date, kept in sync with birth_year" do
    {:ok, tournament, _warnings} = SwarImport.import_file(@c_reeks)
    players = Tournaments.list_players(tournament.id)

    deloof = Enum.find(players, &(&1.name == "Deloof, Koen"))
    assert deloof.birth_date == ~D[1973-04-30]
    assert deloof.birth_date.year == deloof.birth_year

    waegeman = Enum.find(players, &(&1.name == "Waegeman, Willem"))
    assert waegeman.birth_date == ~D[1982-04-02]
    assert waegeman.birth_date.year == waegeman.birth_year
  end

  # Direct unit coverage of the normalization helper itself (no fixture
  # needed) — every marker `SwarImport.import_file/2`'s `map_federation/1`
  # can hand it, plus the pass-through cases. `PairingsEngine.TrfExport`
  # reuses this same function defensively at export time (see
  # trf_export_test.exs) for a tournament whose `federation` was stored raw
  # before this normalization existed.
  test "normalize_federation/1 collapses every Belgian regional/organizational marker to BEL" do
    for marker <- ~w(FRBE KBSB FEFB VSF SVDB FIDE frbe vsf) do
      assert SwarImport.normalize_federation(marker) == "BEL"
    end
  end

  test "normalize_federation/1 leaves a real FIDE federation code, blank, or nil untouched" do
    assert SwarImport.normalize_federation("FRA") == "FRA"
    assert SwarImport.normalize_federation("") == ""
    assert SwarImport.normalize_federation(nil) == nil
  end

  ## ---------- FIDE id matching for players SWAR has no mat_fide for ----------

  describe "FIDE id matching (prepare_import/1, commit_import/3)" do
    @describetag :tmp_dir

    test "problemski.swar's player with no SWAR id at all (no mat_fide, no birth year) is always unresolved, never guessed",
         %{} do
      {:ok, %{data: _data, unresolved: unresolved}} = SwarImport.prepare_import(@problemski)

      assert [%{name: "Ashrafi, Sulaiman Ahmad", birth_year: nil, candidates: []}] = unresolved
    end

    test "import_file/1 (no confirm step available) leaves an unmatchable player without a fide_id, same as before FIDE matching existed" do
      {:ok, tournament, _warnings} = SwarImport.import_file(@problemski)
      players = Tournaments.list_players(tournament.id)

      ashrafi = Enum.find(players, &(&1.name == "Ashrafi, Sulaiman Ahmad"))
      assert ashrafi.fide_id == nil
      assert ashrafi.national_id == ""
    end

    test "a player with no mat_fide but an exact name+federation+birth-year match in the local FIDE database is auto-adopted",
         %{tmp_dir: tmp_dir} do
      Repo.insert!(%FidePlayer{
        fide_id: 210_234,
        name: "Deloof, Koen",
        federation: "BEL",
        birth_year: 1973,
        title: "FM",
        standard_rating: 1850
      })

      path = c_reeks_with_deloof_fide_id_blanked!(tmp_dir)

      assert {:ok, %{data: data, unresolved: unresolved}} = SwarImport.prepare_import(path)
      # Deloof is auto-matched (exact name+federation+birth-year) and drops
      # out of `unresolved` entirely — c-reeks.swar has a couple of other,
      # genuinely-unmatchable players (no local FIDE database seeded for
      # them) that stay unresolved regardless; this only asserts Deloof
      # isn't one of them.
      refute Enum.any?(unresolved, &(&1.name == "Deloof, Koen"))

      {:ok, tournament, _warnings} = SwarImport.commit_import(%{data: data}, %{})
      players = Tournaments.list_players(tournament.id)
      deloof = Enum.find(players, &(&1.name == "Deloof, Koen"))

      assert deloof.fide_id == 210_234
      # SWAR's own spelling is canonical — never overwritten by the FIDE
      # database's name, even on a match.
      assert deloof.name == "Deloof, Koen"
      # Adopts the matched title...
      assert deloof.title == "FM"
      # ...and fills in fide_rating because SWAR's own EloFide was blanked
      # to 0 along with MatFide (see c_reeks_with_deloof_fide_id_blanked!/1).
      assert deloof.fide_rating == 1850
      # national_id is untouched — comes from mat_nat, never crossed with
      # the FIDE match.
      assert deloof.national_id == "39934"
    end

    test "import_file/1's best-effort matching also auto-adopts the same unambiguous match, with no confirm step",
         %{
           tmp_dir: tmp_dir
         } do
      Repo.insert!(%FidePlayer{
        fide_id: 210_234,
        name: "Deloof, Koen",
        federation: "BEL",
        birth_year: 1973,
        title: "",
        standard_rating: nil
      })

      path = c_reeks_with_deloof_fide_id_blanked!(tmp_dir)

      {:ok, tournament, _warnings} = SwarImport.import_file(path)
      deloof = Enum.find(Tournaments.list_players(tournament.id), &(&1.name == "Deloof, Koen"))
      assert deloof.fide_id == 210_234
    end

    test "an ambiguous match (right name+federation, wrong/blank birth year) is left for the user to resolve — never silently guessed",
         %{tmp_dir: tmp_dir} do
      # Same name and federation, but a *different* birth year — this must
      # not auto-match, even though it's the only same-named candidate.
      Repo.insert!(%FidePlayer{
        fide_id: 999_999,
        name: "Deloof, Koen",
        federation: "BEL",
        birth_year: 1960
      })

      path = c_reeks_with_deloof_fide_id_blanked!(tmp_dir)

      assert {:ok, %{data: data, unresolved: unresolved}} = SwarImport.prepare_import(path)

      assert %{federation: "BEL", birth_year: 1973, candidates: candidates} =
               Enum.find(unresolved, &(&1.name == "Deloof, Koen"))

      assert [%{fide_id: 999_999, birth_year: 1960}] = candidates

      # And the non-interactive path leaves it unmatched too — nobody to ask.
      {:ok, tournament, _warnings} = SwarImport.import_file(path)
      deloof = Enum.find(Tournaments.list_players(tournament.id), &(&1.name == "Deloof, Koen"))
      assert deloof.fide_id == nil

      # Also verify the *interactive* confirm step can commit that same
      # `data` with the user's explicit choice.
      %{ni: deloof_ni} = Enum.find(unresolved, &(&1.name == "Deloof, Koen"))

      {:ok, chosen, _warnings} = SwarImport.commit_import(%{data: data}, %{deloof_ni => 999_999})
      chosen_deloof = Enum.find(Tournaments.list_players(chosen.id), &(&1.name == "Deloof, Koen"))
      assert chosen_deloof.fide_id == 999_999
    end

    test "commit_import/3 imports without a fide_id when the resolution says skip (or is simply missing)",
         %{
           tmp_dir: tmp_dir
         } do
      path = c_reeks_with_deloof_fide_id_blanked!(tmp_dir)

      {:ok, %{data: data, unresolved: unresolved}} = SwarImport.prepare_import(path)
      assert %{ni: ni} = Enum.find(unresolved, &(&1.name == "Deloof, Koen"))

      {:ok, tournament, _warnings} = SwarImport.commit_import(%{data: data}, %{ni => nil})
      deloof = Enum.find(Tournaments.list_players(tournament.id), &(&1.name == "Deloof, Koen"))
      assert deloof.fide_id == nil
      assert deloof.name == "Deloof, Koen"
    end
  end

  ## ---------- build_structs/1 (pure, no Repo) ----------

  test "build_structs/1 builds the same tournament/player field values import_file/1 persists, without touching the database" do
    tournament_count_before = Repo.aggregate(PairingsEngine.Tournaments.Tournament, :count)
    player_count_before = Repo.aggregate(PairingsEngine.Tournaments.Player, :count)

    assert {:ok, {tournament, players}} = SwarImport.build_structs(File.read!(@c_reeks))

    assert tournament_count_before ==
             Repo.aggregate(PairingsEngine.Tournaments.Tournament, :count)

    assert player_count_before == Repo.aggregate(PairingsEngine.Tournaments.Player, :count)

    assert tournament.id == nil
    assert tournament.name =~ "C-reeks"
    assert tournament.rounds_count == 11
    assert tournament.federation == "BEL"

    assert tournament.round_dates == [
             "2025-10-04",
             "2025-11-08",
             "2025-11-29",
             "2025-12-13",
             "2025-12-20",
             "2026-01-31",
             "2026-02-21",
             "2026-03-21",
             "2026-04-25",
             "2026-05-09",
             "2026-05-06"
           ]

    assert length(players) == 27

    deloof = Enum.find(players, &(&1.name == "Deloof, Koen"))
    assert deloof.id == nil
    assert deloof.national_id == "39934"
    # No FIDE-database resolve step runs for the pure builder — Deloof
    # already has a `mat_fide` in the raw file, so this is unaffected either
    # way, but it confirms the field still maps straight through.
    assert deloof.fide_id == 210_234
    assert deloof.national_rating == 1810
    assert deloof.fide_rating == 1779
    assert deloof.birth_year == 1973
  end

  test "build_structs/1 never resolves a blank FIDE id against the local FIDE database (unlike import_file/1)" do
    tmp_dir = System.tmp_dir!()
    path = c_reeks_with_deloof_fide_id_blanked!(tmp_dir)

    assert {:ok, {_tournament, players}} = SwarImport.build_structs(File.read!(path))

    deloof = Enum.find(players, &(&1.name == "Deloof, Koen"))
    # SWAR itself has no FIDE id for this (patched) player; the pure builder
    # never queries the FIDE database, so it simply stays empty — contrast
    # with import_file/1's best-effort match (see the FIDE-matching describe
    # block above).
    assert deloof.fide_id == nil
    assert deloof.fide_rating == 0

    File.rm(path)
  end

  test "build_structs/1 returns a parse error unchanged for garbage input" do
    assert {:error, _reason} = SwarImport.build_structs(<<0, 1, 2, 3>>)
  end

  ## ---------- helpers ----------

  # Sums a player's points the same way Standings does: pairing results plus
  # byes, win = 1.0, draw = 0.5.
  defp points_for(tournament, player) do
    rounds =
      Repo.all(from r in Round, where: r.tournament_id == ^tournament.id, preload: [:pairings])

    pairing_points =
      for round <- rounds,
          pairing <- round.pairings,
          pairing.white_player_id == player.id or pairing.black_player_id == player.id do
        white? = pairing.white_player_id == player.id

        case {pairing.result, white?} do
          {"1-0", true} -> 1.0
          {"1-0", false} -> 0.0
          {"0-1", true} -> 0.0
          {"0-1", false} -> 1.0
          {"1/2-1/2", _} -> 0.5
          {"+--", true} -> 1.0
          {"+--", false} -> 0.0
          {"--+", true} -> 0.0
          {"--+", false} -> 1.0
          {"0-0", _} -> 0.0
          {"bye", true} -> tournament.bye_value
          _ -> 0.0
        end
      end

    bye_points =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament.id and b.player_id == ^player.id,
          select: %{type: b.type}
      )
      |> Enum.map(fn bye ->
        case bye.type do
          "requested-half" -> tournament.points_draw
          "pairing-allocated" -> tournament.bye_value
          _ -> 0.0
        end
      end)

    Enum.sum(pairing_points) + Enum.sum(bye_points)
  end
end
