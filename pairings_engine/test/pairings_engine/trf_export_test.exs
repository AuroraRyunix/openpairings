defmodule PairingsEngine.TrfExportTest do
  # async: false — this DataCase does many writes; under ExUnit parallelism it
  # contends on SQLite's single writer lock and flakes with "Database busy"
  # (same reason fide/sync_test and the import/export tests are serial).
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, Trf, TrfExport}
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
        rounds_count: 3,
        round_dates: ["2026-01-01", "2026-01-02", "2026-01-03"]
      })

    alice = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice", fide_rating: 2000, pairing_number: 1})
    bob = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob", fide_rating: 1900, pairing_number: 2})
    carol = Repo.insert!(%Player{tournament_id: tournament.id, name: "Carol", fide_rating: 1800, pairing_number: 3})

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

    Repo.insert!(%Pairing{round_id: r1.id, board: 1, white_player_id: alice.id, black_player_id: bob.id, result: "1-0"})
    Repo.insert!(%Pairing{round_id: r1.id, board: 2, white_player_id: carol.id, black_player_id: nil, result: "bye"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 1, white_player_id: bob.id, black_player_id: carol.id, result: "1/2-1/2"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 2, white_player_id: alice.id, black_player_id: nil, result: "bye"})

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
  # DB writes can never produce a genuinely inconsistent mutual result pair —
  # the derivation from a single Pairing.result is symmetric by construction.
  # This test manufactures the corruption directly (two players sharing the
  # same pairing_number, one of whom is wired up to mutually — and
  # illegally — contradict another player's recorded result) to prove the
  # rescue path actually works end-to-end, rather than only unit-testing
  # `PairingsEngine.Trf.serialize/1` in isolation (already covered by
  # trf_test.exs).
  test "export/2 surfaces an inconsistent roster as {:error, %Trf.ValidationError{}}, not a crash" do
    tournament = Repo.insert!(%Tournament{name: "Corrupt", type: "swiss", rounds_count: 1})

    a = Repo.insert!(%Player{tournament_id: tournament.id, name: "A", pairing_number: 1})
    x = Repo.insert!(%Player{tournament_id: tournament.id, name: "X", pairing_number: 2})
    # Duplicate pairing_number 2 — never happens via the normal pairing flow
    # (PairingsEngine.Pairing.ensure_pairing_numbers/2 assigns each once),
    # only via direct data corruption/tampering.
    y = Repo.insert!(%Player{tournament_id: tournament.id, name: "Y", pairing_number: 2})

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    # A's own round-1 game resolves to this row (first match for A): A beats
    # X as white, "1" vs opponent_rank 2.
    Repo.insert!(%Pairing{round_id: round.id, board: 1, white_player_id: a.id, black_player_id: x.id, result: "1-0"})
    # A second row also pairs A against Y in the same round, with Y (black)
    # winning — Y's own resolved game genuinely points back at A's rank
    # (opponent_rank 1, result "1"). Because X and Y share pairing_number 2,
    # `by_rank[2]` resolves to Y, so A's claimed "1" against rank 2 gets
    # mutually matched against Y's own "1" — a "1"/"1" pair, illegal.
    Repo.insert!(%Pairing{round_id: round.id, board: 2, white_player_id: a.id, black_player_id: y.id, result: "0-1"})

    assert {:error, %Trf.ValidationError{message: message}} = TrfExport.export(tournament)
    assert message =~ "illegal result combination"
  end
end
