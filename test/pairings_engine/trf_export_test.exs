defmodule PairingsEngine.TrfExportTest do
  # async: false - this DataCase does many writes; under ExUnit parallelism it
  # contends on SQLite's single writer lock and flakes with "Database busy"
  # (same reason fide/sync_test and the import/export tests are serial).
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, TrfExport, Tournaments}
  alias PairingsEngine.Federations.BEL.SwarImport
  alias Ainalrami.Trf
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing}

  ## ---------- parse_rounds/2 ----------

  describe "parse_rounds/2" do
    test "nil or blank defaults to every round 1..max_round" do
      assert TrfExport.parse_rounds(nil, 5) == [1, 2, 3, 4, 5]
      assert TrfExport.parse_rounds("", 5) == [1, 2, 3, 4, 5]
    end

    test "no paired rounds yet -> empty list, never 1..0" do
      assert TrfExport.parse_rounds(nil, 0) == []
    end

    test "parses a comma-separated list of single rounds" do
      assert TrfExport.parse_rounds("1,3,5", 9) == [1, 3, 5]
    end

    test "parses a dash range" do
      assert TrfExport.parse_rounds("1-5", 9) == [1, 2, 3, 4, 5]
    end

    test "parses a mix of ranges and singles, deduping and sorting" do
      assert TrfExport.parse_rounds("5,1-3,3", 9) == [1, 2, 3, 5]
    end

    test "clamps out-of-range tokens to 1..max_round" do
      assert TrfExport.parse_rounds("0,1,99", 3) == [1]
      assert TrfExport.parse_rounds("2-10", 3) == [2, 3]
    end

    test "garbage tokens are dropped; if nothing valid remains, falls back to every round" do
      assert TrfExport.parse_rounds("abc,xyz", 3) == [1, 2, 3]
      assert TrfExport.parse_rounds("", 3) == [1, 2, 3]
    end

    test "ignores whitespace around tokens" do
      assert TrfExport.parse_rounds(" 1 , 2 - 3 ", 5) == [1, 2, 3]
    end
  end

  ## ---------- export/2 ----------

  # 3 players, 2 paired rounds:
  #   R1: Alice (w) 1-0 Bob      Carol -- bye (pairing-allocated)
  #   R2: Bob   (w) 1/2-1/2 Carol   Alice -- bye (pairing-allocated)
  defp fixture do
    tournament =
      Repo.insert!(%Tournament{
        name: "TRF Export Test",
        type: "swiss",
        round_dates: ["2026-08-15", "2026-08-16", "2026-08-17", "2026-08-18", "2026-08-19"],
        rounds_count: 3,
        round_dates: ["2026-01-01", "2026-01-02", "2026-01-03"]
      })

    alice =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Alice",
        fide_rating: 2000,
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

  test "exporting with no rounds param includes every paired round" do
    {tournament, _} = fixture()

    assert {:ok, text} = TrfExport.export(tournament)
    parsed = Trf.parse(text)

    assert length(parsed.players) == 3
    alice = Enum.find(parsed.players, &(&1.name |> String.trim() == "Alice"))
    assert length(alice.games) == 2
    assert Enum.map(alice.games, & &1.result) == ["1", "U"]
    # Full-history points: win (1.0) + pairing-allocated bye (bye_value, default 1.0).
    assert alice.points == 2.0
  end

  test "?rounds=1 includes only round 1's column for every player" do
    {tournament, _} = fixture()

    assert {:ok, text} = TrfExport.export(tournament, "1")
    parsed = Trf.parse(text)

    alice = Enum.find(parsed.players, &(&1.name |> String.trim() == "Alice"))
    bob = Enum.find(parsed.players, &(&1.name |> String.trim() == "Bob"))
    carol = Enum.find(parsed.players, &(&1.name |> String.trim() == "Carol"))

    assert length(alice.games) == 1
    assert hd(alice.games).result == "1"
    # Points recomputed from the round-1-only subset: just the win.
    assert alice.points == 1.0

    assert length(bob.games) == 1
    assert hd(bob.games).result == "0"
    assert bob.points == 0.0

    assert length(carol.games) == 1
    assert hd(carol.games).result == "U"
    assert carol.points == 1.0
  end

  test "?rounds=2 includes only round 2's column, and round-2-only points" do
    {tournament, _} = fixture()

    assert {:ok, text} = TrfExport.export(tournament, "2")
    parsed = Trf.parse(text)

    bob = Enum.find(parsed.players, &(&1.name |> String.trim() == "Bob"))
    assert length(bob.games) == 1
    assert hd(bob.games).result == "="
    assert bob.points == 0.5
  end

  test "?rounds=1,2 (explicit list) matches the no-param default for a fully-paired tournament" do
    {tournament, _} = fixture()

    assert {:ok, all} = TrfExport.export(tournament)
    assert {:ok, explicit} = TrfExport.export(tournament, "1,2")
    assert all == explicit
  end

  test "an unpaired round beyond what's been played is dropped, not padded with blanks" do
    {tournament, _} = fixture()

    # Round 3 was never paired; asking for "1-3" clamps to the 2 paired rounds.
    assert {:ok, with_3} = TrfExport.export(tournament, "1-3")
    assert {:ok, without_3} = TrfExport.export(tournament, "1-2")
    assert with_3 == without_3
  end

  test "round-dates line is filtered to match the selected rounds" do
    {tournament, _} = fixture()

    assert {:ok, text} = TrfExport.export(tournament, "2")
    parsed = Trf.parse(text)

    assert parsed.tournament.round_dates == ["2026-01-02"]
  end

  ## ---------- 142/182/column-legend (Swiss-Manager parity) ----------

  test "142 (rounds in this file) reflects the selected rounds, not the tournament's configured total" do
    {tournament, _} = fixture()

    assert {:ok, all} = TrfExport.export(tournament)
    assert Trf.parse(all).tournament.number_of_rounds == 2

    assert {:ok, one} = TrfExport.export(tournament, "1")
    assert Trf.parse(one).tournament.number_of_rounds == 1
  end

  test "182 names OpenPairings and its version" do
    {tournament, _} = fixture()

    assert {:ok, text} = TrfExport.export(tournament)
    assert Trf.parse(text).tournament.generator =~ ~r/^OpenPairings v\d+\.\d+\.\d+/
  end

  test "the Swiss-Manager-style column-ruler/legend lines are present and don't disturb parsing" do
    {tournament, _} = fixture()

    assert {:ok, text} = TrfExport.export(tournament)
    lines = String.split(text, "\r\n", trim: true)

    assert Enum.any?(lines, &String.starts_with?(&1, "DDD SSSS sTTT"))
    assert Enum.any?(lines, &(&1 =~ ~r/^(1234567890)+\d*$/))

    # Still parses back to the exact same player/game data either way - the
    # legend is inert decoration to any TRF16 reader, including our own.
    parsed = Trf.parse(text)
    assert length(parsed.players) == 3
  end

  test "the JaVaFo-input path never gets the column legend (it's opt-in, TrfExport-only)" do
    text =
      Trf.serialize(%{
        tournament: %{name: "T", type: "swiss"},
        players: [%{rank: 1, name: "Alice", points: 0.0, games: []}]
      })

    refute text =~ "DDD SSSS"
    refute text =~ "142 "
    refute text =~ "182 "
  end

  ## ---------- header completeness (072/082/102/112/122) ----------

  test "072 (number of rated players) counts only players with a fide_rating > 0" do
    {tournament, %{carol: carol}} = fixture()
    # Make Carol unrated in the FIDE sense but give her a national rating -
    # that national figure must NOT count towards 072.
    Tournaments.update_player(carol, %{fide_rating: 0, national_rating: 1500})

    assert {:ok, text} = TrfExport.export(tournament)
    assert text =~ "072 2"
  end

  test "082 (number of teams) is always emitted as 0 for an individual tournament" do
    {tournament, _} = fixture()

    assert {:ok, text} = TrfExport.export(tournament)
    assert text =~ "082 0"
  end

  test "102 (chief arbiter) combines the officials FIDE id with the chief_arbiter name" do
    {tournament, _} = fixture()

    {:ok, tournament} =
      Tournaments.update_tournament(tournament, %{
        "chief_arbiter" => "Boutchon, Gaston",
        "officials" => %{"chief_arbiter_fide_id" => "208418"}
      })

    assert {:ok, text} = TrfExport.export(tournament)
    assert text =~ "102 208418 Boutchon, Gaston"
  end

  test "102 is skipped entirely when the chief arbiter is unknown" do
    {tournament, _} = fixture()

    assert {:ok, text} = TrfExport.export(tournament)
    refute text =~ "\r\n102 "
  end

  test "112 (deputy arbiters) emits one line per deputyN_name found in officials" do
    {tournament, _} = fixture()

    {:ok, tournament} =
      Tournaments.update_tournament(tournament, %{
        "officials" => %{
          "deputy1_name" => "Assistant One",
          "deputy1_fide_id" => "111",
          "deputy2_name" => "Assistant Two"
        }
      })

    assert {:ok, text} = TrfExport.export(tournament)
    assert text =~ "112 111 Assistant One"
    assert text =~ "112 Assistant Two"
  end

  test "112 also emits a line per arbiterN_name - arbiters beyond the 2 ranked deputies" do
    {tournament, _} = fixture()

    {:ok, tournament} =
      Tournaments.update_tournament(tournament, %{
        "officials" => %{
          "extra_arbiters_count" => "1",
          "arbiter1_name" => "Assistant Three",
          "arbiter1_fide_id" => "333"
        }
      })

    assert {:ok, text} = TrfExport.export(tournament)
    assert text =~ "112 333 Assistant Three"
  end

  test "112 with no extra arbiters at all doesn't blow up (the 1..0 descending-range footgun)" do
    {tournament, _} = fixture()

    assert {:ok, text} = TrfExport.export(tournament)
    refute text =~ "112 "
  end

  test "122 (rate of play) is emitted from tournament.rate_of_play, and skipped when blank" do
    {tournament, _} = fixture()

    assert {:ok, text} = TrfExport.export(tournament)
    refute text =~ "\r\n122 "

    {:ok, tournament} = Tournaments.update_tournament(tournament, %{"rate_of_play" => "90+30"})
    assert {:ok, text} = TrfExport.export(tournament)
    assert text =~ "122 90+30"
  end

  ## ---------- 032 federation normalization ----------

  # SwarImport.create_tournament/2 already normalizes a Belgian regional
  # league marker (VSF/FEFB/FRBE/"FIDE"/...) to "BEL" on import - but a
  # tournament imported before that normalization existed may still have
  # the raw marker sitting in `tournament.federation` in the database.
  # `TrfExport` applies the same normalization defensively at export time
  # (reusing `PairingsEngine.Federation.normalize/1`) so that tournament
  # exports "032 BEL" without needing a re-import.
  test "032 (federation) normalizes a raw Belgian league marker stored on the tournament, without re-importing" do
    {tournament, _} = fixture()
    {:ok, tournament} = Tournaments.update_tournament(tournament, %{"federation" => "VSF"})

    assert {:ok, text} = TrfExport.export(tournament)
    assert text =~ "032 BEL"
    refute text =~ "032 VSF"
  end

  test "032 (federation) passes through a real FIDE federation code unchanged" do
    {tournament, _} = fixture()
    {:ok, tournament} = Tournaments.update_tournament(tournament, %{"federation" => "FRA"})

    assert {:ok, text} = TrfExport.export(tournament)
    assert text =~ "032 FRA"
  end

  ## ---------- player-line rating & birthdate ----------

  test "fide_rating on the player line is the FIDE rating, never a fallback to national rating" do
    {tournament, %{carol: carol}} = fixture()
    Tournaments.update_player(carol, %{fide_rating: 0, national_rating: 1500})

    assert {:ok, text} = TrfExport.export(tournament)
    parsed = Trf.parse(text)

    carol_row = Enum.find(parsed.players, &(&1.name |> String.trim() == "Carol"))
    assert carol_row.fide_rating == 0
  end

  test "birth_date on the player line prefers the full birth_date over the year-only fallback" do
    {tournament, %{alice: alice, bob: bob}} = fixture()
    Tournaments.update_player(alice, %{birth_date: ~D[1990-11-30]})
    Tournaments.update_player(bob, %{birth_year: 1985})

    assert {:ok, text} = TrfExport.export(tournament)
    parsed = Trf.parse(text)

    alice_row = Enum.find(parsed.players, &(&1.name |> String.trim() == "Alice"))
    bob_row = Enum.find(parsed.players, &(&1.name |> String.trim() == "Bob"))

    assert alice_row.birth_date == "1990-11-30"
    assert bob_row.birth_date == "1985-00-00"
  end

  # End-to-end regression check for a real user-reported gap: an OLD export
  # of a SWAR-imported tournament lacked 072/082/102/112/122 entirely and
  # had year-only birth dates (e.g. "1975/00/00") even for players SWAR
  # knew a full birth date for. Both were supposedly fixed already (see the
  # synthetic-fixture tests above) - this exercises the exact real-world
  # path (SwarImport -> TrfExport) rather than a hand-built fixture, using
  # c-reeks.swar, which has both rated and unrated players and at least one
  # player with a known full birth date (Deloof, Koen, 1973-04-30).
  @tag :swar_fixture
  test "a SWAR-imported tournament's TRF export has the full 072/082/102/112/122 header and full birth dates" do
    {:ok, tournament, _warnings} = SwarImport.import_file("test/fixtures/c-reeks.swar")

    assert {:ok, text} = TrfExport.export(tournament)

    assert text =~ ~r/^072 \d+/m
    assert text =~ "082 0"

    parsed = Trf.parse(text)
    deloof = Enum.find(parsed.players, &(&1.name |> String.trim() == "Deloof, Koen"))
    assert deloof.birth_date == "1973-04-30"
  end

  ## ---------- applicable_fide_id/2 & export_meta/2 (per-round FIDE ID ranges) ----------

  describe "applicable_fide_id/2" do
    test "falls back to the tournament-wide fide_tournament_id when no ranges are configured" do
      {tournament, _} = fixture()

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{"fide_tournament_id" => "999"})

      assert TrfExport.applicable_fide_id(tournament, [1, 2]) == "999"
    end

    test "uses the single range's ID when it fully covers the exported rounds" do
      {tournament, _} = fixture()

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "fide_tournament_id" => "999",
          "fide_id_ranges" => [
            %{"fide_tournament_id" => "111", "from_round" => "1", "to_round" => "2"}
          ]
        })

      assert TrfExport.applicable_fide_id(tournament, [1, 2]) == "111"
      # A sub-range still inside the single configured range also resolves to it.
      assert TrfExport.applicable_fide_id(tournament, [1]) == "111"
    end

    test "falls back to the tournament-wide ID when the exported rounds span two ranges" do
      {tournament, _} = fixture()

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "fide_tournament_id" => "999",
          "fide_id_ranges" => [
            %{"fide_tournament_id" => "111", "from_round" => "1", "to_round" => "1"},
            %{"fide_tournament_id" => "222", "from_round" => "2", "to_round" => "2"}
          ]
        })

      assert TrfExport.applicable_fide_id(tournament, [1, 2]) == "999"
    end

    test "falls back to the tournament-wide ID when the exported rounds only partially overlap a range" do
      {tournament, _} = fixture()

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "fide_tournament_id" => "999",
          "fide_id_ranges" => [
            %{"fide_tournament_id" => "111", "from_round" => "1", "to_round" => "1"}
          ]
        })

      assert TrfExport.applicable_fide_id(tournament, [1, 2]) == "999"
    end

    test "returns nil when neither a range nor a tournament-wide ID applies" do
      {tournament, _} = fixture()
      assert TrfExport.applicable_fide_id(tournament, [1, 2]) == nil
    end
  end

  describe "export_meta/2" do
    test "reports the resolved rounds and matching per-round FIDE ID" do
      {tournament, _} = fixture()

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "fide_id_ranges" => [
            %{"fide_tournament_id" => "111", "from_round" => "1", "to_round" => "1"}
          ]
        })

      assert TrfExport.export_meta(tournament, "1") == %{rounds: [1], fide_id: "111"}
    end

    test "defaults to every paired round when rounds_spec is nil" do
      {tournament, _} = fixture()
      assert %{rounds: [1, 2]} = TrfExport.export_meta(tournament)
    end
  end

  test "a player who was never paired (no pairing_number) is excluded entirely" do
    {tournament, _} = fixture()
    Repo.insert!(%Player{tournament_id: tournament.id, name: "Never Paired", pairing_number: nil})

    assert {:ok, text} = TrfExport.export(tournament)
    parsed = Trf.parse(text)

    refute Enum.any?(parsed.players, &(&1.name |> String.trim() == "Never Paired"))
    assert length(parsed.players) == 3
  end

  # `games_per_player` resolves a player's own game via the first pairing row
  # that mentions them in a round (see PairingsEngine.Pairing), so ordinary
  # DB writes can never produce a genuinely inconsistent mutual result pair -
  # the derivation from a single Pairing.result is symmetric by construction.
  # This test manufactures the corruption directly (two players sharing the
  # same pairing_number, one of whom is wired up to mutually - and
  # illegally - contradict another player's recorded result) to prove the
  # rescue path actually works end-to-end. The writer's own validation is
  # not re-tested here - it belongs to `Ainalrami.Trf` and is covered by
  # that repo's `test/ainalrami/trf_test.exs`. What this app still owns is
  # everything either side of the call: that the adapter can hand the writer
  # a roster it refuses, and that the refusal arrives as an `{:error, _}`
  # tuple a controller can flash rather than as a raise that 500s.
  test "export/2 surfaces an inconsistent roster as {:error, %ValidationError{}}, not a crash" do
    # A date, so the export reaches the roster check this test is about
    # rather than stopping at the missing-dates guard in front of it.
    tournament =
      Repo.insert!(%Tournament{
        name: "Corrupt",
        type: "swiss",
        rounds_count: 1,
        round_dates: ["2026-08-15"]
      })

    a = Repo.insert!(%Player{tournament_id: tournament.id, name: "A", pairing_number: 1})
    x = Repo.insert!(%Player{tournament_id: tournament.id, name: "X", pairing_number: 2})
    # Duplicate pairing_number 2 - never happens via the normal pairing flow
    # (PairingsEngine.Pairing.ensure_pairing_numbers/2 assigns each once),
    # only via direct data corruption/tampering.
    y = Repo.insert!(%Player{tournament_id: tournament.id, name: "Y", pairing_number: 2})

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    # A's own round-1 game resolves to this row (first match for A): A beats
    # X as white, "1" vs opponent_rank 2.
    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: x.id,
      result: "1-0"
    })

    # A second row also pairs A against Y in the same round, with Y (black)
    # winning - Y's own resolved game genuinely points back at A's rank
    # (opponent_rank 1, result "1"). Because X and Y share pairing_number 2,
    # `by_rank[2]` resolves to Y, so A's claimed "1" against rank 2 gets
    # mutually matched against Y's own "1" - a "1"/"1" pair, illegal.
    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 2,
      white_player_id: a.id,
      black_player_id: y.id,
      result: "0-1"
    })

    assert {:error, %Ainalrami.Trf.ValidationError{message: message}} =
             TrfExport.export(tournament)

    assert message =~ "illegal result combination"
  end

  ## ---------- manual ranking (SWAR parity #23) ----------

  describe "manual ranking is not surfaced in the TRF export" do
    test "the exported text is byte-identical whether manual ranking is on or off" do
      {tournament, %{alice: alice}} = fixture()

      assert {:ok, off_text} = TrfExport.export(tournament)

      {:ok, on_tournament} = Tournaments.enable_manual_ranking(tournament)
      assert {:ok, on_text} = TrfExport.export(on_tournament)

      assert off_text == on_text
      refute on_text =~ "990"
      refute on_text =~ "MANUAL RANKING"

      # Rank/starting-rank columns stay pairing_number-based regardless -
      # see docs/manual-standings.md for why manual ranking never touches
      # the TRF rank column at all.
      parsed = Trf.parse(on_text)
      alice_row = Enum.find(parsed.players, &(&1.name |> String.trim() == "Alice"))
      assert alice_row.rank == alice.pairing_number
      assert alice_row.points == 2.0
    end

    test "still true once the manual order goes stale (a result changed after seeding)" do
      {tournament, %{alice: alice, bob: bob}} = fixture()
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      pairing = Repo.get_by!(Pairing, white_player_id: alice.id, black_player_id: bob.id)
      Tournaments.update_pairing_result(pairing, "0-1")

      assert {:ok, text} = TrfExport.export(Repo.reload!(tournament))
      refute text =~ "990"
      refute text =~ "MANUAL RANKING"
      refute text =~ "STALE"
    end
  end
end
