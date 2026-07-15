defmodule PairingsEngine.PairingTest do
  use PairingsEngine.DataCase, async: true
  import Ecto.Query

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  ## ---------- pure eligibility logic ----------

  test "eligible_players/2 excludes withdrawn, permanently-absent and forfeited players" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5})

    active = insert_player(tournament, "Active", status: "active")
    withdrawn = insert_player(tournament, "Withdrawn", status: "withdrawn")
    absent = insert_player(tournament, "Absent", absent: true)
    forfeit = insert_player(tournament, "Forfeit", forfeit: true)

    ids = Pairing.eligible_players(tournament.id, 1) |> Enum.map(& &1.id)

    assert active.id in ids
    refute withdrawn.id in ids
    refute absent.id in ids
    refute forfeit.id in ids
  end

  test "eligible_players/2 excludes a player only for the rounds listed in absent_rounds" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5})
    player = insert_player(tournament, "Sometimes Absent", absent_rounds: "3,5")

    assert player.id in (Pairing.eligible_players(tournament.id, 1) |> Enum.map(& &1.id))
    assert player.id in (Pairing.eligible_players(tournament.id, 2) |> Enum.map(& &1.id))
    refute player.id in (Pairing.eligible_players(tournament.id, 3) |> Enum.map(& &1.id))
    assert player.id in (Pairing.eligible_players(tournament.id, 4) |> Enum.map(& &1.id))
    refute player.id in (Pairing.eligible_players(tournament.id, 5) |> Enum.map(& &1.id))
  end

  test "absent_for_round?/2 is a pure check against the comma-separated absent_rounds list" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5})
    player = insert_player(tournament, "P", absent_rounds: "1")

    assert Pairing.absent_for_round?(player, 1)
    refute Pairing.absent_for_round?(player, 2)

    blank = insert_player(tournament, "Q", absent_rounds: "")
    refute Pairing.absent_for_round?(blank, 1)
  end

  ## ---------- full pairing run (invokes JaVaFo) ----------

  @tag :javafo
  test "pair_next_round/1 excludes a player absent for this round and gives them a requested-zero bye" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})

    p1 = insert_player(tournament, "Alice", fide_rating: 2000)
    p2 = insert_player(tournament, "Bob", fide_rating: 1900)
    p3 = insert_player(tournament, "Carol", fide_rating: 1800)
    absentee = insert_player(tournament, "Dave", fide_rating: 1700, absent_rounds: "1")

    assert {:ok, round} = Pairing.pair_next_round(tournament)
    round = Repo.preload(round, :pairings)

    assert round.number == 1
    # Only 1 real pairing among {Alice, Bob, Carol} — the fourth (odd) player
    # among the eligible three gets a pairing-allocated bye, so 2 pairing
    # rows total (1 game + 1 allocated bye); Dave never reaches JaVaFo.
    assert length(round.pairings) == 2

    pairing_player_ids =
      round.pairings
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
      |> Enum.reject(&is_nil/1)

    refute absentee.id in pairing_player_ids
    assert p1.id in pairing_player_ids
    assert p2.id in pairing_player_ids
    assert p3.id in pairing_player_ids

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament.id and b.player_id == ^absentee.id,
          select: %{round: b.round, type: b.type}
      )

    assert byes == [%{round: 1, type: "requested-zero"}]
  end

  ## ---------- PubSub broadcasts ----------

  @tag :javafo
  test "pair_next_round/1 broadcasts :rounds on the tournament topic" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    insert_player(tournament, "Alice", fide_rating: 2000)
    insert_player(tournament, "Bob", fide_rating: 1900)

    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

    assert {:ok, _round} = Pairing.pair_next_round(tournament)

    tid = tournament.id
    assert_receive {:tournament_changed, ^tid, :rounds}
  end

  test "pair_next_round/1 does not broadcast when pairing fails" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    insert_player(tournament, "Alice", fide_rating: 2000)

    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

    assert {:error, _reason} = Pairing.pair_next_round(tournament)

    refute_receive {:tournament_changed, _, :rounds}
  end

  @tag :javafo
  test "delete_round/2 broadcasts :rounds on the tournament topic" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    insert_player(tournament, "Alice", fide_rating: 2000)
    insert_player(tournament, "Bob", fide_rating: 1900)

    {:ok, _round} = Pairing.pair_next_round(tournament)

    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

    assert :ok = Pairing.delete_round(tournament.id, 1)

    tid = tournament.id
    assert_receive {:tournament_changed, ^tid, :rounds}
  end

  ## ---------- TRF result-code mapping ----------

  test "javafo_input/2 maps every internal result string to the correct TRF16 codes" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 7})

    white = insert_player(tournament, "White", fide_rating: 2000, pairing_number: 1)
    black = insert_player(tournament, "Black", fide_rating: 1900, pairing_number: 2)

    # {internal result, expected white TRF code, expected black TRF code}
    results = [
      {"1-0", "1", "0"},
      {"0-1", "0", "1"},
      {"1/2-1/2", "=", "="},
      # Forfeits are unplayed for both sides (FIDE Art. 16), win side gets '+'.
      {"1-0FF", "+", "-"},
      {"0-1FF", "-", "+"},
      # Double forfeit: neither played, '-' for both.
      {"0-0FF", "-", "-"},
      # Played "0-0" (both lose, e.g. both defaulted after moving): '0' for both.
      {"0-0", "0", "0"}
    ]

    results
    |> Enum.with_index(1)
    |> Enum.each(fn {{result, _w, _b}, round_number} ->
      round =
        Repo.insert!(%PairingsEngine.Tournaments.Round{
          tournament_id: tournament.id,
          number: round_number,
          status: "finished"
        })

      Repo.insert!(%PairingsEngine.Tournaments.Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: result
      })
    end)

    trf = Pairing.javafo_input(tournament)
    lines = String.split(trf, "\r\n")
    white_line = Enum.find(lines, &(String.starts_with?(&1, "001") and &1 =~ "White"))
    black_line = Enum.find(lines, &(String.starts_with?(&1, "001") and &1 =~ "Black"))

    results
    |> Enum.with_index(1)
    |> Enum.each(fn {{result, w_code, b_code}, round_number} ->
      # Round blocks repeat every 10 columns starting at column 92; result
      # is the 8th char of the block (opponent id 4, colour 1, result 1,
      # with 1-char gaps — see PairingsEngine.Trf's round_cols/1).
      result_col = 92 + (round_number - 1) * 10 + 7

      assert String.at(white_line, result_col - 1) == w_code,
             "round #{round_number} (#{result}): expected white code #{w_code}"

      assert String.at(black_line, result_col - 1) == b_code,
             "round #{round_number} (#{result}): expected black code #{b_code}"
    end)
  end

  ## ---------- opponentless games normalize to bye codes (JaVaFo crash fix) ----------

  # User-reported crash: JaVaFo exits 1 on "B.A.B.E: Unexpected format of
  # player line" for rows like "... 0000 - 1 ... 0000 - = ..." — opponent
  # 0000 illegally carrying a played-game result code. This reproduces the
  # underlying data shape (an opponentless Pairing row whose `result` is a
  # playing code rather than the "bye" sentinel — e.g. a won/half bye
  # recorded as if it were an ordinary scored game) and asserts the shared
  # row builder rewrites it to a legal bye code before it ever reaches
  # JaVaFo or the user-facing TRF export.
  test "trf_player_rows/2 normalizes an opponentless game's playing-code result into a bye code" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    player = insert_player(tournament, "Dgebuadze, Alexandre", fide_rating: 2400, pairing_number: 1)
    opponent = insert_player(tournament, "Opponent", fide_rating: 2000, pairing_number: 2)

    r1 = Repo.insert!(%PairingsEngine.Tournaments.Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%PairingsEngine.Tournaments.Round{tournament_id: tournament.id, number: 2, status: "finished"})
    r3 = Repo.insert!(%PairingsEngine.Tournaments.Round{tournament_id: tournament.id, number: 3, status: "finished"})

    # Round 1: an ordinary game against a real opponent — unaffected.
    Repo.insert!(%PairingsEngine.Tournaments.Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: player.id,
      black_player_id: opponent.id,
      result: "1-0"
    })

    # Round 2: a "won bye" recorded with no opponent but a playing-code
    # result ("1-0") instead of the "bye" sentinel — reproduces "0000 - 1".
    Repo.insert!(%PairingsEngine.Tournaments.Pairing{
      round_id: r2.id,
      board: 2,
      white_player_id: player.id,
      black_player_id: nil,
      result: "1-0"
    })

    # Round 3: a "half bye" recorded the same anomalous way — reproduces
    # "0000 - =".
    Repo.insert!(%PairingsEngine.Tournaments.Pairing{
      round_id: r3.id,
      board: 2,
      white_player_id: player.id,
      black_player_id: nil,
      result: "1/2-1/2"
    })

    rows = Pairing.trf_player_rows(tournament, [player, opponent])
    row = Enum.find(rows, &(&1.name == "Dgebuadze, Alexandre"))

    assert Enum.map(row.games, & &1.result) == ["1", "F", "H"]
    assert Enum.map(row.games, & &1.opponent_rank) == [2, nil, nil]

    # The fix applies to both the JaVaFo input path and the TRF export,
    # since both go through this same shared builder — confirm the
    # generated TRF text never contains the illegal combination.
    trf = Pairing.javafo_input(tournament, [player, opponent])
    refute trf =~ "0000 - 1"
    refute trf =~ "0000 - ="
  end

  ## ---------- forbidden pairings -> JaVaFo XXP extension ----------

  test "forbidden_pairs_lines/2 emits one XXP line per pair, using this run's pairing_number as the id" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    alice = insert_player(tournament, "Alice", pairing_number: 1)
    bob = insert_player(tournament, "Bob", pairing_number: 2)
    carol = insert_player(tournament, "Carol", pairing_number: 3)

    {:ok, _} = Tournaments.add_forbidden_pairing(tournament, alice.id, bob.id)
    {:ok, _} = Tournaments.add_forbidden_pairing(tournament, alice.id, carol.id)

    lines = Pairing.forbidden_pairs_lines(tournament.id, [alice, bob, carol])

    # list_forbidden_pairings/1 orders most-recently-added first, so assert
    # on line membership rather than an exact concatenation order.
    line_set = lines |> String.split("\r\n", trim: true) |> MapSet.new()
    assert line_set == MapSet.new(["XXP 1 2", "XXP 1 3"])
  end

  test "forbidden_pairs_lines/2 silently skips a pair when a player has no starting rank in this run" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    alice = insert_player(tournament, "Alice", pairing_number: 1)
    bob = insert_player(tournament, "Bob", [])

    {:ok, _} = Tournaments.add_forbidden_pairing(tournament, alice.id, bob.id)

    # Bob isn't in the `players` list passed in (e.g. not eligible this
    # round) — the pair is dropped rather than emitting a malformed line.
    assert Pairing.forbidden_pairs_lines(tournament.id, [alice]) == ""
  end

  test "forbidden_pairs_lines/2 returns an empty string when there are no forbidden pairings" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    alice = insert_player(tournament, "Alice", pairing_number: 1)

    assert Pairing.forbidden_pairs_lines(tournament.id, [alice]) == ""
  end

  test "javafo_input/2 includes the XXP line(s) alongside the XXR line" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5})
    alice = insert_player(tournament, "Alice", pairing_number: 1)
    bob = insert_player(tournament, "Bob", pairing_number: 2)

    {:ok, _} = Tournaments.add_forbidden_pairing(tournament, alice.id, bob.id)

    trf = Pairing.javafo_input(tournament, [alice, bob])

    assert trf =~ "XXR 5\r\n"
    assert trf =~ "XXP 1 2\r\n"
  end

  ## ---------- club/federation exclusions -> JaVaFo XXP extension ----------

  test "exclusion_pairs_lines/2 emits one XXP line per pair excluded by an \"all\" club rule" do
    tournament =
      Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3, club_exclusion: "all"})

    alice = insert_player(tournament, "Alice", pairing_number: 1, club: "Chess Club")
    bob = insert_player(tournament, "Bob", pairing_number: 2, club: "Chess Club")
    carol = insert_player(tournament, "Carol", pairing_number: 3, club: "Other Club")

    lines = Pairing.exclusion_pairs_lines(tournament, [alice, bob, carol])

    assert lines == "XXP 1 2\r\n"
  end

  test "exclusion_pairs_lines/2 respects a \"listed\" federation rule" do
    tournament =
      Repo.insert!(%Tournament{
        name: "T",
        type: "swiss",
        rounds_count: 3,
        fed_exclusion: "listed",
        fed_exclusion_list: "BEL"
      })

    alice = insert_player(tournament, "Alice", pairing_number: 1, federation: "BEL")
    bob = insert_player(tournament, "Bob", pairing_number: 2, federation: "BEL")
    carol = insert_player(tournament, "Carol", pairing_number: 3, federation: "NED")
    dave = insert_player(tournament, "Dave", pairing_number: 4, federation: "NED")

    lines = Pairing.exclusion_pairs_lines(tournament, [alice, bob, carol, dave])

    assert lines == "XXP 1 2\r\n"
  end

  test "exclusion_pairs_lines/2 dedupes a pair already covered by an explicit forbidden pairing" do
    tournament =
      Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3, club_exclusion: "all"})

    alice = insert_player(tournament, "Alice", pairing_number: 1, club: "Chess Club")
    bob = insert_player(tournament, "Bob", pairing_number: 2, club: "Chess Club")

    {:ok, _} = Tournaments.add_forbidden_pairing(tournament, alice.id, bob.id)

    # forbidden_pairs_lines/2 already emits "XXP 1 2\r\n" for the explicit
    # pairing above — exclusion_pairs_lines/2 must not emit it a second time.
    assert Pairing.exclusion_pairs_lines(tournament, [alice, bob]) == ""
  end

  test "exclusion_pairs_lines/2 returns an empty string when both rules are \"none\"" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    alice = insert_player(tournament, "Alice", pairing_number: 1, club: "Chess Club")
    bob = insert_player(tournament, "Bob", pairing_number: 2, club: "Chess Club")

    assert Pairing.exclusion_pairs_lines(tournament, [alice, bob]) == ""
  end

  test "javafo_input/2 includes exclusion XXP lines alongside explicit forbidden-pairing lines" do
    tournament =
      Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5, club_exclusion: "all"})

    alice = insert_player(tournament, "Alice", pairing_number: 1, club: "Chess Club")
    bob = insert_player(tournament, "Bob", pairing_number: 2, club: "Chess Club")
    carol = insert_player(tournament, "Carol", pairing_number: 3)
    dave = insert_player(tournament, "Dave", pairing_number: 4)

    {:ok, _} = Tournaments.add_forbidden_pairing(tournament, carol.id, dave.id)

    trf = Pairing.javafo_input(tournament, [alice, bob, carol, dave])

    assert trf =~ "XXP 1 2\r\n"
    assert trf =~ "XXP 3 4\r\n"
  end

  ## ---------- forbidden pairings actually respected by JaVaFo ----------

  @tag :javafo
  test "pair_next_round/1 never pairs a forbidden pair together" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 1})

    alice = insert_player(tournament, "Alice", fide_rating: 2000)
    bob = insert_player(tournament, "Bob", fide_rating: 1900)
    insert_player(tournament, "Carol", fide_rating: 1800)
    insert_player(tournament, "Dave", fide_rating: 1700)

    {:ok, _} = Tournaments.add_forbidden_pairing(tournament, alice.id, bob.id)

    assert {:ok, round} = Pairing.pair_next_round(tournament)
    round = Repo.preload(round, :pairings)

    refute Enum.any?(round.pairings, fn p ->
             MapSet.new([p.white_player_id, p.black_player_id]) == MapSet.new([alice.id, bob.id])
           end)
  end

  ## ---------- helpers ----------

  defp insert_player(tournament, name, attrs) do
    defaults = %{tournament_id: tournament.id, name: name}
    {:ok, player} = Tournaments.create_player(tournament.id, Map.merge(defaults, Map.new(attrs)))
    player
  end
end
