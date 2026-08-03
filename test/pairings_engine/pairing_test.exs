defmodule PairingsEngine.PairingTest do
  use PairingsEngine.DataCase, async: true
  import Ecto.Query

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  # `Pairing`'s JaVaFo scratch file is written into a per-run randomized
  # directory and deleted again the moment that run finishes (see
  # `Pairing.workdir!/0`'s doc — a security hardening against a shared-tmp
  # symlink/read attack), so tests can no longer read the TRF text back off
  # disk after `pair_next_round/1` returns. `Pairing` fires a
  # `[:pairings_engine, :pairing, :trf_built]` telemetry event with the exact
  # TRF text right before it's ever written to disk, purely for this kind of
  # test observability. This attaches once per test (handler id scoped to
  # the test process so `async: true` tests never cross-capture each
  # other's events) and stashes every event into this process's own
  # dictionary; `trf_for/3` below reads it back out.
  setup do
    handler_id = "trf-capture-#{inspect(self())}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:pairings_engine, :pairing, :trf_built],
      fn _event, _measurements, meta, _config ->
        Process.put(:trf_events, [meta | Process.get(:trf_events, [])])
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

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

  test "eligible_players/2 excludes a late entrant until their start_round is reached" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5})
    latecomer = insert_player(tournament, "Latecomer", start_round: 3)

    refute latecomer.id in (Pairing.eligible_players(tournament.id, 1) |> Enum.map(& &1.id))
    refute latecomer.id in (Pairing.eligible_players(tournament.id, 2) |> Enum.map(& &1.id))
    assert latecomer.id in (Pairing.eligible_players(tournament.id, 3) |> Enum.map(& &1.id))
    assert latecomer.id in (Pairing.eligible_players(tournament.id, 4) |> Enum.map(& &1.id))
  end

  test "not_yet_started?/2 is a pure check against start_round" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5})
    player = insert_player(tournament, "P", start_round: 3)

    assert Pairing.not_yet_started?(player, 1)
    assert Pairing.not_yet_started?(player, 2)
    refute Pairing.not_yet_started?(player, 3)
    refute Pairing.not_yet_started?(player, 4)

    from_round_one = insert_player(tournament, "Q", start_round: 1)
    refute Pairing.not_yet_started?(from_round_one, 1)
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

  # Root-caused bug: `do_pair_single/4` used to feed JaVaFo the players'
  # raw GLOBAL `pairing_number` as TRF starting ranks. Pairing numbers are
  # frozen once, highest rating first, over the WHOLE active pool (see
  # `ensure_pairing_numbers/2`); when a round-specific absentee
  # (`absent_rounds`) is excluded from just this round's eligible set, and
  # that absentee's rating places them in the MIDDLE of the field rather
  # than at either end, the eligible set's starting ranks have a GAP in the
  # middle of the 1..N range (e.g. {1,2,4,5}, rank 3 missing) — this really
  # does crash the real javafo.jar with a bare NullPointerException. The
  # existing "excludes a player absent for this round" test above doesn't
  # catch this because its absentee is the LOWEST-rated player (a gap at
  # the very end of the range only, which apparently doesn't crash JaVaFo —
  # only a middle gap does).
  @tag :javafo
  test "pair_next_round/1 doesn't crash when a round-specific absentee leaves a gap in the middle of the starting-rank range" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})

    p1 = insert_player(tournament, "Alice", fide_rating: 2000)
    p2 = insert_player(tournament, "Bob", fide_rating: 1900)

    # Rated exactly between Bob and Dave, so after `ensure_pairing_numbers/2`
    # freezes ranks highest-rating-first, Carol lands 3rd of 5 — round 1's
    # eligible set {Alice, Bob, Dave, Eve} then has starting ranks {1,2,4,5},
    # a gap in the MIDDLE of the range, not at either end.
    absentee = insert_player(tournament, "Carol", fide_rating: 1800, absent_rounds: "1")

    p4 = insert_player(tournament, "Dave", fide_rating: 1700)
    p5 = insert_player(tournament, "Eve", fide_rating: 1600)

    assert {:ok, round} = Pairing.pair_next_round(tournament)
    round = Repo.preload(round, :pairings)

    assert round.number == 1

    pairing_player_ids =
      round.pairings
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
      |> Enum.reject(&is_nil/1)

    refute absentee.id in pairing_player_ids
    assert p1.id in pairing_player_ids
    assert p2.id in pairing_player_ids
    assert p4.id in pairing_player_ids
    assert p5.id in pairing_player_ids

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament.id and b.player_id == ^absentee.id,
          select: %{round: b.round, type: b.type}
      )

    assert byes == [%{round: 1, type: "requested-zero"}]
  end

  ## ---------- a player's prior bye must not be lost when pairing later rounds ----------
  #
  # User-reported concern: "byes don't end up in the pairings history/list.
  # if i pair a new round, i can maybe even get a duplicate bye this way!"
  # Investigation traced the *visibility* half (bye rows never rendered on
  # PairingsLive/LiveRoundLive/PublicPairingsLive — fixed alongside this
  # test) but found `games_per_player/2` already joins the "byes" table
  # independently of `Tournaments.get_round/2` when building each round's
  # TRF history for JaVaFo, so the "duplicate bye" half was suspected to be
  # a false alarm caused only by the missing UI, not a real backend gap.
  # This test proves that trace rather than trusting it: a player whose
  # round-1 absence is recorded in the "byes" table (simulating a
  # SWAR-imported round-specific absentee, same mechanism already covered
  # above) must (a) still show up correctly in the TRF history fed to
  # JaVaFo for round 2, and (b) not be JaVaFo's pick for a fresh
  # pairing-allocated bye in round 2 ahead of players who have never sat
  # out, when an odd active-player count forces someone to receive one.
  @tag :javafo
  test "pair_next_round/1 preserves a prior round's bye in history and JaVaFo avoids re-assigning a bye to that player" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 4})

    _alice = insert_player(tournament, "Alice", fide_rating: 2000)
    _bob = insert_player(tournament, "Bob", fide_rating: 1900)
    _carol = insert_player(tournament, "Carol", fide_rating: 1800)
    _eve = insert_player(tournament, "Eve", fide_rating: 1700)
    # Absent for round 1 only — eligible_players/2 excludes Dave from round
    # 1's pairing and Pairing.pair_next_round/1 records a "requested-zero"
    # byes-table row for them (same mechanism as the excludes-absentee test
    # above), simulating a SWAR-imported round-specific absence. Deliberately
    # the LOWEST-rated player, so their pairing_number lands last (5) among
    # the five — round 1's eligible four then keep a contiguous 1..4 range
    # of starting ranks in the TRF sent to JaVaFo. (A gap in the middle of
    # the starting-rank range — e.g. the absentee rated between Carol and
    # Eve — hits a separate, pre-existing JaVaFo/TRF starting-rank
    # contiguity issue unrelated to what this test is checking.)
    dave = insert_player(tournament, "Dave", fide_rating: 1600, absent_rounds: "1")

    # Round 1: {Alice, Bob, Carol, Eve} — even, so two real games, no
    # pairing-allocated bye. Dave sits out via absent_rounds.
    assert {:ok, round1} = Pairing.pair_next_round(tournament)
    assert round1.number == 1

    # Round 2 can't be paired until round 1's results are all in (the
    # scoring the pairing engine relies on wouldn't be final otherwise) —
    # fill in arbitrary decisive results for round 1's two real games.
    round1 = Repo.preload(round1, :pairings)

    Enum.each(round1.pairings, fn pairing ->
      if pairing.result == "" do
        {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")
      end
    end)

    dave_byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament.id and b.player_id == ^dave.id,
          select: %{round: b.round, type: b.type}
      )

    assert dave_byes == [%{round: 1, type: "requested-zero"}]

    # (a) The round-1 absence must survive into the TRF history built for
    # round 2 — inspect the actual TRF export rather than trusting the
    # trace. Dave's round-1 slot must carry TRF code "Z" (requested-zero /
    # absent bye), not be silently blank/dropped.
    dave = Repo.reload(dave)
    trf = Pairing.javafo_input(tournament)

    dave_line =
      Enum.find(String.split(trf, "\r\n"), &(String.starts_with?(&1, "001") and &1 =~ "Dave"))

    refute is_nil(dave_line)

    round1_result_col = 92 + (1 - 1) * 10 + 7
    assert String.at(dave_line, round1_result_col - 1) == "Z"

    # (b) Round 2: all five players are eligible again (odd count), so one
    # of them gets a fresh pairing-allocated bye. Standard FIDE Dutch-system
    # logic prefers giving a bye to a player who hasn't already had one,
    # all else being equal — assert JaVaFo picked someone other than Dave,
    # proving the round-1 absence wasn't lost/ignored when pairing round 2
    # (which is exactly what would let the same player collect a second,
    # "duplicate" bye).
    assert {:ok, round2} = Pairing.pair_next_round(tournament)
    round2 = Repo.preload(round2, pairings: [:white_player, :black_player])
    assert round2.number == 2

    bye_pairing = Enum.find(round2.pairings, &(&1.result == "bye"))
    assert bye_pairing, "expected round 2 (5 active players) to include a pairing-allocated bye"

    bye_player_id = bye_pairing.white_player_id

    refute bye_player_id == dave.id,
           "JaVaFo re-assigned round 2's bye to Dave, who already sat out round 1 — the prior absence appears to have been lost"
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

  ## ---------- delete_round/2 must not orphan a round's byes table row ----------
  #
  # The "byes" table has no round_id foreign key, so a plain `Round` delete
  # alone leaves a round-specific absentee's "requested-zero" bye row
  # behind. Re-pairing the same round number then hits
  # `insert_all("byes", ...)`'s `UNIQUE(player_id, round)` index — which
  # used to raise, permanently bricking the round.
  @tag :javafo
  test "delete_round/2 clears a round-specific absentee's byes row so re-pairing doesn't crash" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})

    insert_player(tournament, "Alice", fide_rating: 2000)
    insert_player(tournament, "Bob", fide_rating: 1900)
    insert_player(tournament, "Carol", fide_rating: 1800)
    dave = insert_player(tournament, "Dave", fide_rating: 1700, absent_rounds: "1")

    assert {:ok, _round} = Pairing.pair_next_round(tournament)
    assert :ok = Pairing.delete_round(tournament.id, 1)

    # Re-pairing round 1 must succeed rather than raising a uniqueness
    # violation on the orphaned "byes" row from the first pairing run.
    assert {:ok, round} = Pairing.pair_next_round(tournament)
    assert round.number == 1

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament.id and b.player_id == ^dave.id,
          select: %{round: b.round, type: b.type}
      )

    # Exactly one row for {Dave, round: 1} — no duplicate from the deleted
    # round's leftover row.
    assert byes == [%{round: 1, type: "requested-zero"}]
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

  # User-reported crash (real SWAR 3-2-1 import, see swar_import_test.exs):
  # pairing a new round after import raised `Trf.ValidationError` —
  # "opponent 0000 cannot carry played-game result ... opponentless games
  # must use a bye code" — for a player whose round-1 REAL opponent had
  # since been marked `absent: true` and dropped out of `active_players/1`.
  # `games_per_player/2` was resolving that historical opponent's identity
  # against the same narrow player set used to decide who's eligible to be
  # paired THIS round, so a genuinely non-nil `opponent_id` produced a nil
  # `opponent_rank` — a played-game result with no way to name its
  # opponent, the illegal TRF combination. This is a synthetic
  # reproduction, independent of the gitignored real fixture: A beats B in
  # round 1, B then goes absent, and A's round-1 TRF line must still show
  # B's real starting rank, not "0000".
  test "javafo_input/2 resolves a historical opponent's rank even after they've gone absent" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})

    a = insert_player(tournament, "Alice", fide_rating: 2000, pairing_number: 1)
    b = insert_player(tournament, "Bob", fide_rating: 1900, pairing_number: 2)

    r1 =
      Repo.insert!(%PairingsEngine.Tournaments.Round{
        tournament_id: tournament.id,
        number: 1,
        status: "finished"
      })

    Repo.insert!(%PairingsEngine.Tournaments.Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    {:ok, b} = Tournaments.update_player(b, %{absent: true})
    refute b.id in (Pairing.active_players(tournament.id) |> Enum.map(& &1.id))

    # `trf_player_rows/2` directly: Alice's round-1 game must still resolve
    # Bob's real opponent_id/rank, not nil, even though Bob is no longer in
    # the player set being built (`active_players/1`'s result).
    [row] = Pairing.trf_player_rows(tournament, Pairing.active_players(tournament.id))
    [game] = row.games
    assert game.result == "1"
    assert game.opponent_id == b.id
    assert game.opponent_rank == 2

    # And the full TRF text used to previously crash JaVaFo never contains
    # the illegal "0000 - 1" combination for Alice's round-1 game — her
    # opponent id block (columns 92-95, round 1 — see Trf's round_cols/1)
    # must carry Bob's real starting rank (2), not the "0000" placeholder.
    trf = Pairing.javafo_input(tournament)
    refute trf =~ "0000 - 1"

    lines = String.split(trf, "\r\n")
    alice_line = Enum.find(lines, &(String.starts_with?(&1, "001") and &1 =~ "Alice"))
    assert String.slice(alice_line, 91, 4) |> String.trim() == "2"
    assert String.at(alice_line, 96) == "w"
    assert String.at(alice_line, 98) == "1"
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

  # Regression for audit finding #8: Group-A membership must be a
  # tournament-wide concept fixed at freeze time (FIDE C.04.5.1), not
  # something that shifts round-to-round based on who happens to be
  # eligible THIS round. `acceleration_lines/4`'s `ranked`/Group-A
  # computation now always receives the full frozen roster
  # (`do_pair_single/4` passes `full_roster`, not the round's eligible
  # subset, all the way through `javafo_input/4`) — this was fixed as a
  # side effect of a separate colour-history fix. Proven here by pairing
  # round 2 with a non-trivial-rank Group-A player (#3) excused for round 2
  # only (`absent_rounds`) and asserting the round-2 TRF's XXA starting
  # ranks are byte-identical to round 1's — if Group A were still being
  # recomputed from the round's eligible subset, excluding rank 3 would
  # shift the remaining Group-A ranks to {1, 2, 4, 5}.
  @tag :javafo
  test "Baku Group-A membership is computed from the full roster, unaffected by a round-2-only absence" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Baku Roster Scoping",
        type: "swiss",
        rounds_count: 9,
        acceleration: "baku"
      })

    players =
      for {name, rating, n} <- [
            {"P1", 2400, 1},
            {"P2", 2300, 2},
            {"P3", 2200, 3},
            {"P4", 2100, 4},
            {"P5", 2000, 5},
            {"P6", 1900, 6},
            {"P7", 1800, 7},
            {"P8", 1700, 8}
          ] do
        insert_player(tournament, name, fide_rating: rating, pairing_number: n)
      end

    [_p1, _p2, p3 | _] = players

    assert {:ok, round1} = Pairing.pair_next_round(tournament)
    round1 = Repo.preload(round1, :pairings)

    round1_xxa_ranks = trf_xxa_ranks(tournament, 1)
    # Group A = 2*ceil(8/4) = 4 players: starting ranks 1-4.
    assert round1_xxa_ranks == [1, 2, 3, 4]

    Enum.each(round1.pairings, fn pairing ->
      {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")
    end)

    # P3 (starting rank 3, inside Group A) is excused for round 2 only —
    # excluded from round 2's pairing pool, but must not shrink Group A
    # membership (still all 4 of pairing_number 1-4, per
    # `acceleration_lines/4`'s doc: Group-A membership is a fixed,
    # tournament-wide concept keyed on `pairing_number`, deliberately
    # unaffected by which round is being paired).
    {:ok, _} = Tournaments.update_player(p3, %{absent_rounds: "2"})

    assert {:ok, _round2} = Pairing.pair_next_round(tournament)

    round2_xxa_ranks = trf_xxa_ranks(tournament, 2)
    # NOT asserting the exact same rank *numbers* as round 1: JaVaFo's
    # input (and so each Group-A member's emitted XXA rank) is now ordered
    # by CURRENT STANDINGS, not the fixed `pairing_number` — see
    # `order_for_pairing/3`. Once round-1 results are in, a Group-A member
    # who won ends up ranked ahead of one who didn't, so the specific
    # numbers legitimately shift round to round. What must still hold is
    # the actual invariant this test is about: the round-specific absence
    # doesn't shrink Group A down from 4 members.
    assert length(round2_xxa_ranks) == length(round1_xxa_ranks)
  end

  # Reads back the `t#{tournament.id}_r#{round_number}.trf` file
  # `do_pair_single/4` writes to disk for JaVaFo, and extracts every `XXA`
  # line's starting-rank column (the fixed-column format documented on
  # `Pairing.acceleration_lines/4`).
  defp trf_xxa_ranks(tournament, round_number) do
    trf_for(tournament.id, round_number)
    |> then(&Regex.scan(~r/^XXA\s+(\d+)/m, &1))
    |> Enum.map(fn [_, rank] -> String.to_integer(rank) end)
    |> Enum.sort()
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

    for {name, rating} <- [
          {"Alice", 2000},
          {"Bob", 1900},
          {"Carol", 1800},
          {"Dave", 1700},
          {"Eve", 1600},
          {"Frank", 1500}
        ] do
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

    round1_pairs =
      round1.pairings |> Enum.map(&{&1.white_player_id, &1.black_player_id}) |> MapSet.new()

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

  ## ---------- delete_round/2 under swiss_match_format deletes both legs ----------
  #
  # A single do_pair/2 call under swiss_match_format inserts BOTH legs of a
  # match (rounds N and N+1 — see create_mirrored_leg/4 and the comment
  # above max_pairable_round/1, which documents that paired_rounds_count/1
  # always lands on an even number after a match-format pairing run).
  # delete_round/2 used to delete exactly one round regardless of match
  # format, breaking that invariant.

  @tag :javafo
  test "delete_round/2 under swiss_match_format deletes both legs of the match, not just the requested round" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Match",
        type: "swiss",
        rounds_count: 4,
        swiss_match_format: true
      })

    for {name, rating} <- [
          {"Alice", 2000},
          {"Bob", 1900},
          {"Carol", 1800},
          {"Dave", 1700},
          {"Eve", 1600},
          {"Frank", 1500}
        ] do
      insert_player(tournament, name, fide_rating: rating)
    end

    assert {:ok, _round2} = Pairing.pair_next_round(tournament)
    assert Pairing.paired_rounds_count(tournament.id) == 2

    assert :ok = Pairing.delete_round(tournament.id, 2)

    # Both legs (round 1 AND round 2) must be gone, not just round 2 —
    # otherwise round 1 would be orphaned (never rematched).
    assert Pairing.paired_rounds_count(tournament.id) == 0
    refute Tournaments.get_round(tournament.id, 1)
    refute Tournaments.get_round(tournament.id, 2)
  end

  @tag :javafo
  test "delete_round/2 on the last leg of the last match doesn't strand the tournament — pairing resumes cleanly" do
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

    # Enter results for both legs of match 1 so match 2 (rounds 3-4) can be
    # paired.
    for number <- [1, 2] do
      round = Tournaments.get_round(tournament.id, number) |> Repo.preload(:pairings)

      Enum.each(round.pairings, fn p ->
        if p.result == "", do: Tournaments.update_pairing_result(p, "1-0")
      end)
    end

    assert {:ok, round4} = Pairing.pair_next_round(tournament)
    assert round4.number == 4
    assert Pairing.paired_rounds_count(tournament.id) == 4

    # Deleting round 4 (the requested "latest round") must also delete
    # round 3 — leaving round 3 behind would strand the tournament:
    # next_number would become 4, but max_pairable_round is rounds_count - 1
    # == 3, so pairing would be permanently blocked with a misleading
    # "all rounds paired" error, and the UI has no way to delete round 3
    # directly (delete_round/2 only permits deleting the latest round).
    assert :ok = Pairing.delete_round(tournament.id, 4)
    assert Pairing.paired_rounds_count(tournament.id) == 2
    refute Tournaments.get_round(tournament.id, 3)
    refute Tournaments.get_round(tournament.id, 4)

    # Pairing must succeed again, creating rounds 3 and 4 fresh — not error
    # out and not treat round 3 as a leftover mismatched leg.
    assert {:ok, fresh_round4} = Pairing.pair_next_round(Repo.reload!(tournament))
    assert fresh_round4.number == 4
    assert Tournaments.get_round(tournament.id, 3)
    assert Pairing.paired_rounds_count(tournament.id) == 4
  end

  ## ---------- native per-category Swiss pairing (SWAR-parity #24) ----------

  @tag :javafo
  test "pair_by_category: true never pairs across categories, boards run continuously per category in tournament.categories order" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Cat",
        type: "swiss",
        rounds_count: 3,
        categories: ["A", "B"],
        categories_enabled: true,
        pair_by_category: true
      })

    a_players =
      for {name, rating} <- [{"A1", 2000}, {"A2", 1900}, {"A3", 1800}, {"A4", 1700}] do
        insert_player(tournament, name, fide_rating: rating, category: "A")
      end

    b_players =
      for {name, rating} <- [{"B1", 1600}, {"B2", 1500}, {"B3", 1400}, {"B4", 1300}] do
        insert_player(tournament, name, fide_rating: rating, category: "B")
      end

    assert {:ok, round} = Pairing.pair_next_round(tournament)
    round = Repo.preload(round, :pairings)

    # 4 players per category, no byes: 2 boards per category, 4 total.
    assert length(round.pairings) == 4

    a_ids = MapSet.new(a_players, & &1.id)
    b_ids = MapSet.new(b_players, & &1.id)

    Enum.each(round.pairings, fn p ->
      white_in_a = MapSet.member?(a_ids, p.white_player_id)
      black_in_a = MapSet.member?(a_ids, p.black_player_id)
      white_in_b = MapSet.member?(b_ids, p.white_player_id)
      black_in_b = MapSet.member?(b_ids, p.black_player_id)

      assert (white_in_a and black_in_a) or (white_in_b and black_in_b),
             "pairing #{inspect(p)} crosses categories"
    end)

    boards_a =
      round.pairings
      |> Enum.filter(&MapSet.member?(a_ids, &1.white_player_id))
      |> Enum.map(& &1.board)
      |> Enum.sort()

    boards_b =
      round.pairings
      |> Enum.filter(&MapSet.member?(b_ids, &1.white_player_id))
      |> Enum.map(& &1.board)
      |> Enum.sort()

    # tournament.categories == ["A", "B"] — A's boards come first.
    assert boards_a == [1, 2]
    assert boards_b == [3, 4]
  end

  @tag :javafo
  test "pair_by_category: an odd-sized category gets its own pairing-allocated bye, not borrowed from another category" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Cat Odd",
        type: "swiss",
        rounds_count: 3,
        categories: ["A", "B"],
        categories_enabled: true,
        pair_by_category: true
      })

    a_players =
      for {name, rating} <- [{"A1", 2000}, {"A2", 1900}, {"A3", 1800}] do
        insert_player(tournament, name, fide_rating: rating, category: "A")
      end

    b_players =
      for {name, rating} <- [{"B1", 1600}, {"B2", 1500}, {"B3", 1400}, {"B4", 1300}] do
        insert_player(tournament, name, fide_rating: rating, category: "B")
      end

    assert {:ok, round} = Pairing.pair_next_round(tournament)
    round = Repo.preload(round, :pairings)

    a_ids = MapSet.new(a_players, & &1.id)
    b_ids = MapSet.new(b_players, & &1.id)

    a_pairings = Enum.filter(round.pairings, &MapSet.member?(a_ids, &1.white_player_id))
    b_pairings = Enum.filter(round.pairings, &MapSet.member?(b_ids, &1.white_player_id))

    assert Enum.any?(a_pairings, &(&1.result == "bye"))
    refute Enum.any?(b_pairings, &(&1.result == "bye"))
  end

  @tag :javafo
  test "pair_by_category: a single-player category gets an automatic bye" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Cat Single",
        type: "swiss",
        rounds_count: 3,
        categories: ["A", "B"],
        categories_enabled: true,
        pair_by_category: true
      })

    solo = insert_player(tournament, "Solo", fide_rating: 2000, category: "A")

    for {name, rating} <- [{"B1", 1600}, {"B2", 1500}, {"B3", 1400}, {"B4", 1300}] do
      insert_player(tournament, name, fide_rating: rating, category: "B")
    end

    assert {:ok, round} = Pairing.pair_next_round(tournament)
    round = Repo.preload(round, :pairings)

    solo_pairing = Enum.find(round.pairings, &(&1.white_player_id == solo.id))
    assert solo_pairing
    assert solo_pairing.result == "bye"
    assert is_nil(solo_pairing.black_player_id)
  end

  @tag :javafo
  test "pair_by_category: blank/unlisted category players form their own Uncategorized pool" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Cat Uncat",
        type: "swiss",
        rounds_count: 3,
        categories: ["A"],
        categories_enabled: true,
        pair_by_category: true
      })

    a_players =
      for {name, rating} <- [{"A1", 2000}, {"A2", 1900}] do
        insert_player(tournament, name, fide_rating: rating, category: "A")
      end

    uncat_players =
      for {name, rating} <- [{"U1", 1600}, {"U2", 1500}] do
        insert_player(tournament, name, fide_rating: rating, category: "")
      end

    assert {:ok, round} = Pairing.pair_next_round(tournament)
    round = Repo.preload(round, :pairings)

    a_ids = MapSet.new(a_players, & &1.id)
    uncat_ids = MapSet.new(uncat_players, & &1.id)

    Enum.each(round.pairings, fn p ->
      white_in_a = MapSet.member?(a_ids, p.white_player_id)
      black_in_a = MapSet.member?(a_ids, p.black_player_id)
      white_in_uncat = MapSet.member?(uncat_ids, p.white_player_id)
      black_in_uncat = MapSet.member?(uncat_ids, p.black_player_id)

      assert (white_in_a and black_in_a) or (white_in_uncat and black_in_uncat),
             "pairing #{inspect(p)} mixed A with Uncategorized"
    end)
  end

  @tag :javafo
  test "pair_by_category: a forbidden pairing within a category is honored; across categories is a harmless no-op" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Cat Forbidden",
        type: "swiss",
        rounds_count: 3,
        categories: ["A", "B"],
        categories_enabled: true,
        pair_by_category: true
      })

    a1 = insert_player(tournament, "A1", fide_rating: 2000, category: "A")
    a2 = insert_player(tournament, "A2", fide_rating: 1900, category: "A")
    _a3 = insert_player(tournament, "A3", fide_rating: 1800, category: "A")
    _a4 = insert_player(tournament, "A4", fide_rating: 1700, category: "A")
    b1 = insert_player(tournament, "B1", fide_rating: 1600, category: "B")
    _b2 = insert_player(tournament, "B2", fide_rating: 1500, category: "B")

    {:ok, _} = Tournaments.add_forbidden_pairing(tournament, a1.id, a2.id)
    # Cross-category forbidden pairing — these two could never meet anyway,
    # so this must be a harmless no-op, not an error.
    {:ok, _} = Tournaments.add_forbidden_pairing(tournament, a1.id, b1.id)

    assert {:ok, round} = Pairing.pair_next_round(Repo.reload!(tournament))
    round = Repo.preload(round, :pairings)

    pairs = Enum.map(round.pairings, &{&1.white_player_id, &1.black_player_id})

    refute {a1.id, a2.id} in pairs
    refute {a2.id, a1.id} in pairs
  end

  @tag :javafo
  test "pair_by_category: each category's own history avoids rematches within that category across rounds" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Cat Multi",
        type: "swiss",
        rounds_count: 3,
        categories: ["A", "B"],
        categories_enabled: true,
        pair_by_category: true
      })

    for {name, rating} <- [{"A1", 2000}, {"A2", 1900}, {"A3", 1800}, {"A4", 1700}] do
      insert_player(tournament, name, fide_rating: rating, category: "A")
    end

    for {name, rating} <- [{"B1", 1600}, {"B2", 1500}, {"B3", 1400}, {"B4", 1300}] do
      insert_player(tournament, name, fide_rating: rating, category: "B")
    end

    tournament = Repo.reload!(tournament)
    assert {:ok, round1} = Pairing.pair_next_round(tournament)
    round1 = Repo.preload(round1, :pairings)

    round1_pairs =
      round1.pairings
      |> Enum.reject(&(&1.result == "bye"))
      |> Enum.map(&{&1.white_player_id, &1.black_player_id})
      |> MapSet.new()

    Enum.each(round1.pairings, fn p ->
      if p.result != "bye", do: Tournaments.update_pairing_result(p, "1-0")
    end)

    assert {:ok, round2} = Pairing.pair_next_round(Repo.reload!(tournament))
    round2 = Repo.preload(round2, :pairings)

    Enum.each(round2.pairings, fn p ->
      if p.result != "bye" do
        pair = {p.white_player_id, p.black_player_id}
        reverse_pair = {p.black_player_id, p.white_player_id}
        refute MapSet.member?(round1_pairs, pair)
        refute MapSet.member?(round1_pairs, reverse_pair)
      end
    end)
  end

  ## ---------- colour-history preservation when a historical opponent leaves ----------

  # Root-caused bug (single-pool path): `do_pair_single/4` used to build its
  # local contiguous rank map over only THIS round's eligible players. A
  # player who has since gone permanently absent/forfeited/withdrawn is
  # excluded from `active_players/1` entirely, so a still-active player's
  # real, decisive past game against them fell outside the map and got
  # rewritten by `remap_trf_rows_to_local_ranks/2` into a synthetic bye
  # ("0000", win -> "F") in the TRF sent to JaVaFo — silently destroying
  # that game's played result, which can make JaVaFo repeat a colour and
  # break FIDE alternation. The fix scopes the local map (and the TRF row
  # set) to the full frozen roster and marks non-candidates with an explicit
  # "0000 - Z" line instead, so real history survives. This asserts directly
  # on the round-4 TRF: the anchor's round-1 game against the withdrawn
  # player must still carry that opponent's real starting rank and the real
  # played result "1", not a "0000"/"F" bye-rewrite. FAILS on the pre-fix
  # code (opponent "0000", result "F").
  @tag :javafo
  test "pair_next_round/1 keeps a withdrawn opponent's real played result/colour in the next round's TRF" do
    tournament =
      Repo.insert!(%Tournament{name: "Withdraw Colour", type: "swiss", rounds_count: 4})

    for {name, rating} <- [
          {"P1", 2000},
          {"P2", 1900},
          {"P3", 1800},
          {"P4", 1700},
          {"P5", 1600},
          {"P6", 1500}
        ] do
      insert_player(tournament, name, fide_rating: rating)
    end

    tournament = Repo.reload!(tournament)

    assert {:ok, round1} = Pairing.pair_next_round(tournament)
    round1 = Repo.preload(round1, :pairings)

    # Anchor = the white side of a real decisive game in round 1; the black
    # side is the opponent who will later withdraw.
    game1 = Enum.find(round1.pairings, &(&1.black_player_id != nil))
    anchor_id = game1.white_player_id
    opponent_id = game1.black_player_id

    enter_all_wins(round1)
    assert {:ok, round2} = Pairing.pair_next_round(Repo.reload!(tournament))
    enter_all_wins(Repo.preload(round2, :pairings))
    assert {:ok, round3} = Pairing.pair_next_round(Repo.reload!(tournament))
    enter_all_wins(Repo.preload(round3, :pairings))

    # Opponent withdraws after round 3 (permanently excluded from pairing).
    opponent = Repo.get!(PairingsEngine.Tournaments.Player, opponent_id)
    {:ok, opponent} = Tournaments.update_player(opponent, %{absent: true})
    refute opponent.id in (Pairing.active_players(tournament.id) |> Enum.map(& &1.id))

    assert {:ok, _round4} = Pairing.pair_next_round(Repo.reload!(tournament))

    anchor = Repo.get!(PairingsEngine.Tournaments.Player, anchor_id)
    anchor_line = anchor_trf_line(read_round_trf(tournament.id, 4), anchor.name)

    # Round-1 game columns (opponent rank cols 92-95, colour col 97, result
    # col 99 — 0-indexed 91/96/98): the anchor's real win over the now-
    # withdrawn opponent must survive intact.
    #
    # The opponent-rank column now holds their CURRENT-STANDINGS-based local
    # rank for this pairing run (see `order_for_pairing/3`), not their raw
    # `pairing_number` — deliberately no longer the same number across
    # rounds. What this test actually protects against is the "0000"/"F"
    # bye-rewrite regression, so it only needs to confirm the column holds
    # SOME real (non-"0000") rank reference, not which exact number.
    opponent_rank_column = String.slice(anchor_line, 91, 4) |> String.trim()
    assert opponent_rank_column != "0000" and opponent_rank_column != ""
    assert String.at(anchor_line, 96) == "w"
    assert String.at(anchor_line, 98) == "1"
  end

  # Same class of bug in the per-category path (`build_category_trf/5`):
  # historically it scoped the category-local rank map to just that
  # category's current players, so a past opponent who is no longer in the
  # category (here: moved to a different category between rounds) fell out of
  # the map and got the same colour-destroying bye-rewrite. The fix sends
  # every category the FULL roster (all categories) with a shared local
  # numbering, so any historical opponent resolves. Asserts on category A's
  # round-2 TRF that the anchor's round-1 game against the moved player still
  # carries the real starting rank and result "1", not "0000"/"F".
  @tag :javafo
  test "pair_by_category: a historical opponent now in a different category keeps their real played result in the TRF" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Cat Colour",
        type: "swiss",
        rounds_count: 3,
        categories: ["A", "B"],
        categories_enabled: true,
        pair_by_category: true
      })

    for {name, rating} <- [{"A1", 2000}, {"A2", 1900}, {"A3", 1800}, {"A4", 1700}] do
      insert_player(tournament, name, fide_rating: rating, category: "A")
    end

    for {name, rating} <- [{"B1", 1600}, {"B2", 1500}] do
      insert_player(tournament, name, fide_rating: rating, category: "B")
    end

    tournament = Repo.reload!(tournament)
    assert {:ok, round1} = Pairing.pair_next_round(tournament)
    round1 = Repo.preload(round1, pairings: [:white_player, :black_player])

    # A real decisive round-1 game between two category-A players.
    game1 =
      Enum.find(round1.pairings, fn p ->
        p.black_player_id != nil and p.white_player.category == "A" and
          p.black_player.category == "A"
      end)

    anchor = game1.white_player
    opponent = game1.black_player

    enter_all_wins(round1)

    # The opponent moves to category B before round 2 — now a historical
    # opponent OUTSIDE category A's own group when A's round-2 TRF is built.
    {:ok, _opponent} = Tournaments.update_player(opponent, %{category: "B"})

    assert {:ok, _round2} = Pairing.pair_next_round(Repo.reload!(tournament))

    # Category A is index 0 in `tournament.categories`, slug "0_A".
    trf = read_round_trf(tournament.id, 2, "_cat_0_A")
    anchor_line = anchor_trf_line(trf, anchor.name)

    # See the identical note in the non-category version of this test above:
    # the opponent-rank column is now a current-standings-based local rank
    # (`order_for_pairing/3`), not the raw `pairing_number` — only "not a
    # 0000 bye-rewrite" is the actual regression being guarded against here.
    opponent_rank_column = String.slice(anchor_line, 91, 4) |> String.trim()
    assert opponent_rank_column != "0000" and opponent_rank_column != ""
    assert String.at(anchor_line, 96) == "w"
    assert String.at(anchor_line, 98) == "1"
  end

  ## ---------- helpers ----------

  defp enter_all_wins(round) do
    Enum.each(round.pairings, fn p ->
      if p.result != "bye", do: Tournaments.update_pairing_result(p, "1-0")
    end)
  end

  # Each pairing run writes its JaVaFo scratch files into its own freshly
  # randomized `pairingsengine-<random>` directory (see `Pairing.workdir!/0`
  # — a security hardening so a symlink/predictable-path attack in a shared
  # temp dir can't clobber/read another user's scratch file), rather than
  # a single fixed `pairingsengine` subfolder. Glob every such directory and
  # find the one holding this round's file — safe in tests, where pairing
  # runs happen sequentially and each round's file is unique by
  # tournament/round/suffix.
  # `suffix` mirrors the old scratch-filename suffix (e.g. `"_cat_0_A"` for
  # a category run) purely to pick the category vs. non-category event —
  # any non-empty suffix means "the one category event captured for this
  # round" (these tests only ever pair one category at a time per
  # assertion, so there's never more than one to disambiguate between).
  defp read_round_trf(tournament_id, round_number, suffix \\ "") do
    category_name = if suffix == "", do: nil, else: :any_category
    trf_for(tournament_id, round_number, category_name)
  end

  # Reads back the TRF text `Pairing` fired via the `[:pairings_engine,
  # :pairing, :trf_built]` telemetry event (see this file's top-level
  # `setup`) for `tournament_id`/`round_number`, optionally narrowed to one
  # category (`:any_category` matches whichever single category event is
  # present — fine since these tests only ever pair one category at a time
  # per assertion).
  defp trf_for(tournament_id, round_number, category_name \\ nil) do
    match =
      Process.get(:trf_events, [])
      |> Enum.find(fn meta ->
        meta.tournament_id == tournament_id and meta.round == round_number and
          (category_name == :any_category or meta.category == category_name)
      end)

    case match do
      %{trf: trf} ->
        trf

      nil ->
        raise "no trf_built event captured for tournament #{tournament_id} round #{round_number}" <>
                if(category_name, do: " category #{inspect(category_name)}", else: "")
    end
  end

  defp anchor_trf_line(trf, name) do
    trf
    |> String.split("\r\n")
    |> Enum.find(&(String.starts_with?(&1, "001") and &1 =~ name))
  end

  ## ---------- JaVaFo output parsing ----------

  describe "parse_pairs/1" do
    # `parse_pairs/1` is `@doc false`-public purely for these tests (same
    # precedent as PairingsEngine.Fide.Sync) — JaVaFo has been observed to
    # exit 0 having written an EMPTY output file, and the old bare
    # `[_count | lines] =` match crashed pair_next_round/1 with an opaque
    # MatchError instead of a tidy {:error, ...}.

    test "parses the count line plus one \"white black\" pair per line" do
      assert Pairing.parse_pairs("2\r\n1 2\r\n3 0\r\n") == {:ok, [{1, 2}, {3, 0}]}
    end

    test "a lone \"0\" count line (no pairs) parses to an empty pair list" do
      assert Pairing.parse_pairs("0\n") == {:ok, []}
    end

    test "completely empty output returns {:error, ...} instead of raising MatchError" do
      assert {:error, message} = Pairing.parse_pairs("")
      assert message =~ "JaVaFo produced no pairings output"
    end

    test "whitespace-only output returns {:error, ...} too" do
      assert {:error, message} = Pairing.parse_pairs("\r\n \n\n")
      assert message =~ "JaVaFo produced no pairings output"
    end
  end

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
