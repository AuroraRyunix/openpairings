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

  ## ---------- byes must invalidate a hand-set manual standings order ----------
  #
  # SWAR parity #23 (manual standings) fix 3: byes award points too (see
  # PairingsEngine.Standings) but are written entirely inside this module,
  # never through Tournaments.update_pairing_result/2 — so they need their
  # own PairingsEngine.Tournaments.invalidate_manual_ranking/1 call sites.
  # See docs/manual-standings.md.

  @tag :javafo
  test "a round-specific absentee's requested-zero bye marks a hand-set manual order stale" do
    tournament =
      Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3, manual_ranking: true})

    insert_player(tournament, "Alice", fide_rating: 2000)
    insert_player(tournament, "Bob", fide_rating: 1900)
    insert_player(tournament, "Carol", fide_rating: 1800)
    insert_player(tournament, "Dave", fide_rating: 1700, absent_rounds: "1")

    {:ok, tournament} = Tournaments.reseed_manual_ranking(tournament)
    refute Repo.reload!(tournament).manual_ranking_stale

    assert {:ok, _round} = Pairing.pair_next_round(tournament)

    assert Repo.reload!(tournament).manual_ranking_stale
  end

  @tag :javafo
  test "a pairing-allocated bye (odd number of eligible players) marks a hand-set manual order stale" do
    tournament =
      Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3, manual_ranking: true})

    insert_player(tournament, "Alice", fide_rating: 2000)
    insert_player(tournament, "Bob", fide_rating: 1900)
    insert_player(tournament, "Carol", fide_rating: 1800)

    {:ok, tournament} = Tournaments.reseed_manual_ranking(tournament)
    refute Repo.reload!(tournament).manual_ranking_stale

    assert {:ok, round} = Pairing.pair_next_round(tournament)
    round = Repo.preload(round, :pairings)
    assert Enum.any?(round.pairings, &(&1.result == "bye"))

    assert Repo.reload!(tournament).manual_ranking_stale
  end

  test "pairing a round with no byes at all does not touch a fresh manual order (manual_ranking off, sanity)" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    insert_player(tournament, "Alice", fide_rating: 2000)

    # manual_ranking is off here, so pairing (even a failing one, as this
    # will be with a single player) must not touch manual_ranking_stale.
    assert {:error, _reason} = Pairing.pair_next_round(tournament)
    refute Repo.reload!(tournament).manual_ranking_stale
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

    player =
      insert_player(tournament, "Dgebuadze, Alexandre", fide_rating: 2400, pairing_number: 1)

    opponent = insert_player(tournament, "Opponent", fide_rating: 2000, pairing_number: 2)

    r1 =
      Repo.insert!(%PairingsEngine.Tournaments.Round{
        tournament_id: tournament.id,
        number: 1,
        status: "finished"
      })

    r2 =
      Repo.insert!(%PairingsEngine.Tournaments.Round{
        tournament_id: tournament.id,
        number: 2,
        status: "finished"
      })

    r3 =
      Repo.insert!(%PairingsEngine.Tournaments.Round{
        tournament_id: tournament.id,
        number: 3,
        status: "finished"
      })

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

  ## ---------- Baku acceleration (XXA) — pure line building ----------

  test "acceleration_lines/3 matches FIDE C.04.5.1's own nine-round worked example" do
    tournament =
      Repo.insert!(%Tournament{
        name: "T",
        type: "swiss",
        pairing_system: "swiss",
        rounds_count: 9,
        acceleration: "baku"
      })

    players = for n <- 1..8, do: %{pairing_number: n}

    # "In a nine-round tournament, the accelerated rounds are five. The
    # players in GA are assigned one virtual point in the first three
    # rounds, and half virtual point in the next two rounds." (FIDE
    # C.04.5.1). Group A = top half rounded up to an even count = 2*ceil(8/4)
    # = 4 players (ranks 1-4); Group B (ranks 5-8) never appears at all.
    assert Pairing.acceleration_lines(tournament, players, 4) ==
             "XXA     1  1.0  1.0  1.0  0.5\r\n" <>
               "XXA     2  1.0  1.0  1.0  0.5\r\n" <>
               "XXA     3  1.0  1.0  1.0  0.5\r\n" <>
               "XXA     4  1.0  1.0  1.0  0.5\r\n"

    # Round 1 alone: still 1.0 for Group A, one column only.
    assert Pairing.acceleration_lines(tournament, players, 1) ==
             "XXA     1  1.0\r\nXXA     2  1.0\r\nXXA     3  1.0\r\nXXA     4  1.0\r\n"

    # Round 6 is past the 5 accelerated rounds: the trailing column is 0.0,
    # but the historical columns are still reported in full (JaVaFo's own
    # words: needed for "floaters history").
    assert Pairing.acceleration_lines(tournament, players, 6) ==
             "XXA     1  1.0  1.0  1.0  0.5  0.5  0.0\r\n" <>
               "XXA     2  1.0  1.0  1.0  0.5  0.5  0.0\r\n" <>
               "XXA     3  1.0  1.0  1.0  0.5  0.5  0.0\r\n" <>
               "XXA     4  1.0  1.0  1.0  0.5  0.5  0.0\r\n"
  end

  test "acceleration_lines/3 is a no-op unless acceleration is baku and pairing_system is swiss" do
    players = for n <- 1..8, do: %{pairing_number: n}

    off = %Tournament{pairing_system: "swiss", rounds_count: 9, acceleration: "none"}
    assert Pairing.acceleration_lines(off, players, 1) == ""

    round_robin =
      %Tournament{pairing_system: "round_robin", rounds_count: 9, acceleration: "baku"}

    assert Pairing.acceleration_lines(round_robin, players, 1) == ""

    keizer = %Tournament{pairing_system: "keizer", rounds_count: 9, acceleration: "baku"}
    assert Pairing.acceleration_lines(keizer, players, 1) == ""
  end

  test "javafo_input/2 includes fixed-column XXA lines alongside XXR when acceleration is baku" do
    tournament =
      Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 9, acceleration: "baku"})

    alice = insert_player(tournament, "Alice", pairing_number: 1)
    bob = insert_player(tournament, "Bob", pairing_number: 2)
    carol = insert_player(tournament, "Carol", pairing_number: 3)
    dave = insert_player(tournament, "Dave", pairing_number: 4)

    trf = Pairing.javafo_input(tournament, [alice, bob, carol, dave])

    assert trf =~ "XXR 9\r\n"
    assert trf =~ "XXA     1  1.0\r\n"
    assert trf =~ "XXA     2  1.0\r\n"
  end

  test "javafo_input/2 omits XXA entirely when acceleration is none" do
    tournament =
      Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 9, acceleration: "none"})

    alice = insert_player(tournament, "Alice", pairing_number: 1)
    bob = insert_player(tournament, "Bob", pairing_number: 2)

    trf = Pairing.javafo_input(tournament, [alice, bob])
    refute trf =~ "XXA"
  end

  ## ---------- Baku acceleration actually changes JaVaFo's pairings ----------

  # End-to-end proof that JaVaFo honours the XXA directive rather than
  # silently ignoring it: two tournaments, identical 8 players and an
  # identical (already-played) round 1, differing only in
  # `acceleration`. Group A (starting ranks 1-4) is given +1.0 virtual
  # points for round 1 in the accelerated tournament, which changes their
  # effective round-2 standings score group from the real ranks-1-4 winners
  # (1, 3, 6, 8) to (1, 2, 3, 4) — so round 2 must pair 1 against 3 (the only
  # two Group-A players left once the group is a clean foursome), which
  # never happens without acceleration. Verified once by hand directly
  # against `javafo.jar` (see `PairingsEngine.Pairing.acceleration_lines/3`
  # doc) before being written up as this automated assertion.
  @tag :javafo
  test "pair_next_round/1 pairs round 2 differently when Baku acceleration is on vs off" do
    control =
      Repo.insert!(%Tournament{
        name: "Control",
        type: "swiss",
        rounds_count: 9,
        acceleration: "none"
      })

    accel =
      Repo.insert!(%Tournament{
        name: "Accel",
        type: "swiss",
        rounds_count: 9,
        acceleration: "baku"
      })

    for tournament <- [control, accel] do
      p1 = insert_player(tournament, "P1", fide_rating: 2400, pairing_number: 1)
      p2 = insert_player(tournament, "P2", fide_rating: 2300, pairing_number: 2)
      p3 = insert_player(tournament, "P3", fide_rating: 2200, pairing_number: 3)
      p4 = insert_player(tournament, "P4", fide_rating: 2100, pairing_number: 4)
      p5 = insert_player(tournament, "P5", fide_rating: 2000, pairing_number: 5)
      p6 = insert_player(tournament, "P6", fide_rating: 1900, pairing_number: 6)
      p7 = insert_player(tournament, "P7", fide_rating: 1800, pairing_number: 7)
      p8 = insert_player(tournament, "P8", fide_rating: 1700, pairing_number: 8)

      round1 =
        Repo.insert!(%PairingsEngine.Tournaments.Round{
          tournament_id: tournament.id,
          number: 1,
          status: "finished"
        })

      # 1 beats 5, 6 beats 2, 3 beats 7, 8 beats 4 — real scores after round
      # 1: {1, 3, 6, 8} = 1.0, {2, 4, 5, 7} = 0.0.
      for {white, black} <- [{p1, p5}, {p6, p2}, {p3, p7}, {p8, p4}] do
        Repo.insert!(%PairingsEngine.Tournaments.Pairing{
          round_id: round1.id,
          board: 1,
          white_player_id: white.id,
          black_player_id: black.id,
          result: "1-0"
        })
      end
    end

    assert {:ok, control_r2} = Pairing.pair_next_round(control)
    assert {:ok, accel_r2} = Pairing.pair_next_round(accel)

    control_pairs = round_pairs_by_rank(control_r2)
    accel_pairs = round_pairs_by_rank(accel_r2)

    refute control_pairs == accel_pairs

    # Without acceleration, the real score-1.0 group is {1, 3, 6, 8} — ranks
    # 1 and 3 never meet in round 2 (they're both undefeated but slotted
    # against 6/8 respectively).
    refute {1, 3} in control_pairs or {3, 1} in control_pairs

    # With acceleration, ranks 1-4 (Group A) each get +1.0 virtual points for
    # round 1, so the effective score-2.0 group entering round 2 is exactly
    # {1, 3} (real winners 1 and 3, boosted) — leaving JaVaFo no choice but
    # to pair them together.
    assert {1, 3} in accel_pairs or {3, 1} in accel_pairs
  end

  ## ---------- swiss_match_format ----------

  @tag :javafo
  test "pair_next_round/1 pairs match 1 (rounds 1-2) as two separate Round rows, leg 2 mirroring leg 1's pairs with colours swapped" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Match",
        type: "swiss",
        rounds_count: 4,
        swiss_match_format: true
      })

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700},
                            {"Eve", 1600}, {"Frank", 1500}] do
      insert_player(tournament, name, fide_rating: rating)
    end

    assert {:ok, round2} = Pairing.pair_next_round(tournament)
    assert round2.number == 2

    round1 = Tournaments.get_round(tournament.id, 1) |> Repo.preload(:pairings)
    round2 = Repo.preload(round2, :pairings)

    assert length(round1.pairings) == 3
    assert length(round2.pairings) == 3

    # Each round has exactly one Pairing per player (never two in one Round).
    for round <- [round1, round2] do
      player_ids =
        round.pairings
        |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
        |> Enum.reject(&is_nil/1)

      assert length(player_ids) == length(Enum.uniq(player_ids))
    end

    by_board1 = Map.new(round1.pairings, &{&1.board, &1})
    by_board2 = Map.new(round2.pairings, &{&1.board, &1})

    assert Map.keys(by_board1) |> Enum.sort() == Map.keys(by_board2) |> Enum.sort()

    Enum.each(by_board1, fn {board, p1} ->
      p2 = Map.fetch!(by_board2, board)

      if p1.result == "bye" do
        assert p2.result == "bye"
        assert p2.white_player_id == p1.white_player_id
        assert is_nil(p2.black_player_id)
      else
        assert p1.result == ""
        assert p2.result == ""
        assert p2.white_player_id == p1.black_player_id
        assert p2.black_player_id == p1.white_player_id
      end
    end)
  end

  @tag :javafo
  test "pair_next_round/1 rejects pairing a partial match once all rounds are already paired" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Match",
        type: "swiss",
        rounds_count: 4,
        swiss_match_format: true
      })

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      insert_player(tournament, name, fide_rating: rating)
    end

    tournament = Repo.reload!(tournament)
    assert {:ok, _round2} = Pairing.pair_next_round(tournament)

    # Enter results for both legs of match 1 so match 2 can be paired.
    for number <- [1, 2] do
      round = Tournaments.get_round(tournament.id, number) |> Repo.preload(:pairings)

      Enum.each(round.pairings, fn p ->
        if p.result == "" do
          Tournaments.update_pairing_result(p, "1-0")
        end
      end)
    end

    assert {:ok, round4} = Pairing.pair_next_round(tournament)
    assert round4.number == 4

    assert {:error, "All 4 rounds have already been paired"} =
             Pairing.pair_next_round(tournament)
  end

  @tag :javafo
  test "pair_next_round/1's mirrored history round-trips through javafo_input/2: match 2 avoids pairs that already met" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Match",
        type: "swiss",
        rounds_count: 4,
        swiss_match_format: true
      })

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      insert_player(tournament, name, fide_rating: rating)
    end

    tournament = Repo.reload!(tournament)
    assert {:ok, _round2} = Pairing.pair_next_round(tournament)

    round1 = Tournaments.get_round(tournament.id, 1) |> Repo.preload(:pairings)
    round1_pairs = round1.pairings |> Enum.map(&{&1.white_player_id, &1.black_player_id}) |> MapSet.new()

    for number <- [1, 2] do
      round = Tournaments.get_round(tournament.id, number) |> Repo.preload(:pairings)
      Enum.each(round.pairings, &Tournaments.update_pairing_result(&1, "1-0"))
    end

    assert {:ok, round4} = Pairing.pair_next_round(tournament)
    round3 = Tournaments.get_round(tournament.id, 3) |> Repo.preload(:pairings)
    round4 = Repo.preload(round4, :pairings)

    for round <- [round3, round4] do
      Enum.each(round.pairings, fn p ->
        pair = {p.white_player_id, p.black_player_id}
        reverse_pair = {p.black_player_id, p.white_player_id}
        refute MapSet.member?(round1_pairs, pair)
        refute MapSet.member?(round1_pairs, reverse_pair)
      end)
    end
  end

  @tag :javafo
  test "a pairing-allocated bye and a round-specific absentee both mirror into leg 2 (same player, same type, both legs)" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Match",
        type: "swiss",
        rounds_count: 4,
        swiss_match_format: true,
        bye_value: 1.0
      })

    insert_player(tournament, "Alice", fide_rating: 2000)
    insert_player(tournament, "Bob", fide_rating: 1900)
    insert_player(tournament, "Carol", fide_rating: 1800)
    absentee = insert_player(tournament, "Dave", fide_rating: 1700, absent_rounds: "1")

    tournament = Repo.reload!(tournament)
    assert {:ok, round2} = Pairing.pair_next_round(tournament)
    round2 = Repo.preload(round2, :pairings)

    # The odd-sized eligible pool (Alice, Bob, Carol) produces a
    # pairing-allocated bye, mirrored into round 2 for the same player.
    round1 = Tournaments.get_round(tournament.id, 1) |> Repo.preload(:pairings)
    bye1 = Enum.find(round1.pairings, &(&1.result == "bye"))
    bye2 = Enum.find(round2.pairings, &(&1.result == "bye"))

    assert bye1
    assert bye2
    assert bye1.white_player_id == bye2.white_player_id

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament.id and b.player_id == ^absentee.id,
          select: %{round: b.round, type: b.type}
      )
      |> Enum.sort_by(& &1.round)

    assert byes == [
             %{round: 1, type: "requested-zero"},
             %{round: 2, type: "requested-zero"}
           ]
  end

  ## ---------- helpers ----------

  defp round_pairs_by_rank(round) do
    round
    |> Repo.preload(pairings: [:white_player, :black_player])
    |> Map.fetch!(:pairings)
    |> Enum.map(fn p ->
      white_rank = p.white_player && p.white_player.pairing_number
      black_rank = p.black_player && p.black_player.pairing_number
      {white_rank, black_rank}
    end)
  end

  defp insert_player(tournament, name, attrs) do
    defaults = %{tournament_id: tournament.id, name: name}
    {:ok, player} = Tournaments.create_player(tournament.id, Map.merge(defaults, Map.new(attrs)))
    player
  end
end
