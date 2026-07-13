defmodule PairingsEngine.SwarImportTest do
  # `async: false` — each test writes a whole tournament (players, rounds,
  # pairings) via a real transaction; with the FIDE-matching tests added on
  # top, that's enough concurrent SQLite writers to occasionally hit
  # "Database busy" under the async pool (SQLite has a single writer).
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{SwarImport, Tournaments, Repo}
  alias PairingsEngine.Tournaments.Round
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Fide.FidePlayer

  @c_reeks "test/fixtures/c-reeks.swar"
  @problemski "test/fixtures/problemski.swar"

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
    assert deloof.mat_fide == 210234
    assert deloof.elo == 1779 or deloof.elo_fide == 1779

    waegeman = Enum.find(data.players, &(&1.name == "Waegeman, Willem"))
    assert waegeman.mat_nat == 19953
    assert waegeman.mat_fide == 292052
    assert String.starts_with?(waegeman.birth, "1982")

    cobert = Enum.find(data.players, &(&1.name == "Cobert, Quinten"))
    assert cobert.elo == 0
    assert cobert.elo_fide == 0
  end

  ## ---------- import_file/1 ----------

  test "import_file/1 creates the tournament, players and pairings for c-reeks.swar" do
    assert {:ok, tournament} = SwarImport.import_file(@c_reeks)

    assert tournament.name =~ "C-reeks"
    assert tournament.rounds_count == 11

    players = Tournaments.list_players(tournament.id)
    assert length(players) == 27

    deloof = Enum.find(players, &(&1.name == "Deloof, Koen"))
    assert deloof.national_id == "39934"
    assert deloof.fide_id == 210234
    assert deloof.national_rating == 1810
    assert deloof.fide_rating == 1779
    assert deloof.birth_year == 1973

    waegeman = Enum.find(players, &(&1.name == "Waegeman, Willem"))
    assert waegeman.national_id == "19953"
    assert waegeman.fide_id == 292052
    assert waegeman.birth_year == 1982

    cobert = Enum.find(players, &(&1.name == "Cobert, Quinten"))
    assert cobert.national_rating == 0
    assert cobert.fide_rating == 0

    assert PairingsEngine.Pairing.paired_rounds_count(tournament.id) == 11

    assert points_for(tournament, deloof) == 9.0
  end

  test "import_file/1 maps SWAR player-administration fields (payment, affiliation, extra points, category, club number)" do
    {:ok, tournament} = SwarImport.import_file(@c_reeks)
    players = Tournaments.list_players(tournament.id)

    abramenko = Enum.find(players, &(&1.name == "Abramenko, Aleksei"))
    assert abramenko.paid == "paid"
    assert abramenko.extra_points == 0.5
    assert abramenko.affiliated == true
    assert abramenko.national_id == "21740"
    assert abramenko.fide_id == 268968
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

  test "import_file/1 does not create duplicate pairings for the same game" do
    {:ok, tournament} = SwarImport.import_file(@c_reeks)
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
    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.user_tournaments_topic(scope.user.id))

    assert {:ok, tournament} = SwarImport.import_file(@c_reeks, scope)

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
    assert {:ok, _tournament} = SwarImport.import_file(@c_reeks)
  end

  test "import_file/1 parses and imports problemski.swar without error" do
    assert {:ok, tournament} = SwarImport.import_file(@problemski)
    players = Tournaments.list_players(tournament.id)
    assert length(players) == 10
  end

  test "import_file/1 marks the tournament as running, not stuck on setup, since rounds were imported" do
    # c-reeks.swar's 11 rounds are all paired but not, as it turns out,
    # fully scored — 4 of its 297 games carry a blank result (2 from the
    # legacy SWAR DRAW_ZERO/ZERO_DRAW combo with no equivalent here — see
    # `combine_results/2`'s moduledoc note — 2 genuinely unplayed), so the
    # honestly-derived status (see the "commits a fully-scored import as
    # finished" test below) is "running", same as this test asserted before
    # status became derived rather than hardcoded.
    assert {:ok, tournament} = SwarImport.import_file(@c_reeks)
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
              Enum.map(p.rounds, fn r -> if r.round_nr == round_nr, do: %{r | result: code}, else: r end)

            %{p | rounds: rounds}
          else
            p
          end
        end)
      end)

    data = %{prepared.data | players: players}
    assert {:ok, tournament} = SwarImport.commit_import(%{data: data}, %{})

    assert tournament.status == "finished"
    assert Tournaments.get_tournament!(tournament.id).status == "finished"
  end

  ## ---------- Federation normalization + full birth dates ----------

  test "import_file/1 normalizes the SWAR federation entity to the FIDE country code, not the raw league marker" do
    {:ok, tournament} = SwarImport.import_file(@c_reeks)

    # c-reeks.swar's [TOURNOI] `federation` field is code 6 ("direct FIDE
    # homologation") — still Belgium, not the literal string "FIDE".
    assert tournament.federation == "BEL"

    players = Tournaments.list_players(tournament.id)
    assert Enum.all?(players, &(&1.federation == "BEL"))
  end

  test "import_file/1 stores the full birth date, kept in sync with birth_year" do
    {:ok, tournament} = SwarImport.import_file(@c_reeks)
    players = Tournaments.list_players(tournament.id)

    deloof = Enum.find(players, &(&1.name == "Deloof, Koen"))
    assert deloof.birth_date == ~D[1973-04-30]
    assert deloof.birth_date.year == deloof.birth_year

    waegeman = Enum.find(players, &(&1.name == "Waegeman, Willem"))
    assert waegeman.birth_date == ~D[1982-04-02]
    assert waegeman.birth_date.year == waegeman.birth_year
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
      {:ok, tournament} = SwarImport.import_file(@problemski)
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

      {:ok, tournament} = SwarImport.commit_import(%{data: data}, %{})
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

    test "import_file/1's best-effort matching also auto-adopts the same unambiguous match, with no confirm step", %{
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

      {:ok, tournament} = SwarImport.import_file(path)
      deloof = Enum.find(Tournaments.list_players(tournament.id), &(&1.name == "Deloof, Koen"))
      assert deloof.fide_id == 210_234
    end

    test "an ambiguous match (right name+federation, wrong/blank birth year) is left for the user to resolve — never silently guessed",
         %{tmp_dir: tmp_dir} do
      # Same name and federation, but a *different* birth year — this must
      # not auto-match, even though it's the only same-named candidate.
      Repo.insert!(%FidePlayer{fide_id: 999_999, name: "Deloof, Koen", federation: "BEL", birth_year: 1960})

      path = c_reeks_with_deloof_fide_id_blanked!(tmp_dir)

      assert {:ok, %{data: data, unresolved: unresolved}} = SwarImport.prepare_import(path)

      assert %{federation: "BEL", birth_year: 1973, candidates: candidates} =
               Enum.find(unresolved, &(&1.name == "Deloof, Koen"))

      assert [%{fide_id: 999_999, birth_year: 1960}] = candidates

      # And the non-interactive path leaves it unmatched too — nobody to ask.
      {:ok, tournament} = SwarImport.import_file(path)
      deloof = Enum.find(Tournaments.list_players(tournament.id), &(&1.name == "Deloof, Koen"))
      assert deloof.fide_id == nil

      # Also verify the *interactive* confirm step can commit that same
      # `data` with the user's explicit choice.
      %{ni: deloof_ni} = Enum.find(unresolved, &(&1.name == "Deloof, Koen"))

      {:ok, chosen} = SwarImport.commit_import(%{data: data}, %{deloof_ni => 999_999})
      chosen_deloof = Enum.find(Tournaments.list_players(chosen.id), &(&1.name == "Deloof, Koen"))
      assert chosen_deloof.fide_id == 999_999
    end

    test "commit_import/3 imports without a fide_id when the resolution says skip (or is simply missing)", %{
      tmp_dir: tmp_dir
    } do
      path = c_reeks_with_deloof_fide_id_blanked!(tmp_dir)

      {:ok, %{data: data, unresolved: unresolved}} = SwarImport.prepare_import(path)
      assert %{ni: ni} = Enum.find(unresolved, &(&1.name == "Deloof, Koen"))

      {:ok, tournament} = SwarImport.commit_import(%{data: data}, %{ni => nil})
      deloof = Enum.find(Tournaments.list_players(tournament.id), &(&1.name == "Deloof, Koen"))
      assert deloof.fide_id == nil
      assert deloof.name == "Deloof, Koen"
    end
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
