defmodule PairingsEngine.RoundRobinTest do
  # Several tests write a whole tournament's worth of rounds/pairings/byes
  # in sequence and would starve SQLite's single writer under async
  # execution (see the "Database busy" note other pairing tests carry).
  use PairingsEngine.DataCase, async: false

  import Ecto.Query

  alias PairingsEngine.{Pairing, Repo, RoundRobin, Standings, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  ## ---------- schedule/3: published FIDE Berger tables ----------
  ##
  ## Source: FIDE Handbook C.05 Annex 1 "Details of Berger Table". N=4 is
  ## also given verbatim in this module's task brief. Comparing as a
  ## MapSet per round ignores board-listing order (not part of "the
  ## schedule") while still checking exact composition *and* colour.

  describe "schedule/3 — published Berger tables" do
    test "N=4 matches the FIDE table for every round" do
      published = %{
        1 => [{1, 4}, {2, 3}],
        2 => [{4, 3}, {1, 2}],
        3 => [{2, 4}, {3, 1}]
      }

      for {round, pairs} <- published do
        assert {:ok, matches} = RoundRobin.schedule(4, 1, round)
        assert MapSet.new(matches) == pairing_set(pairs)
      end
    end

    test "N=6 matches the FIDE table for every round" do
      published = %{
        1 => [{1, 6}, {2, 5}, {3, 4}],
        2 => [{6, 4}, {5, 3}, {1, 2}],
        3 => [{2, 6}, {3, 1}, {4, 5}],
        4 => [{6, 5}, {1, 4}, {2, 3}],
        5 => [{3, 6}, {4, 2}, {5, 1}]
      }

      for {round, pairs} <- published do
        assert {:ok, matches} = RoundRobin.schedule(6, 1, round)
        assert MapSet.new(matches) == pairing_set(pairs)
      end
    end

    defp pairing_set(pairs), do: MapSet.new(pairs, fn {w, b} -> {:pairing, w, b} end)
  end

  ## ---------- structural properties ----------

  describe "schedule/3 — structural properties" do
    test "single cycle needs N-1 rounds for even N, N rounds for odd N" do
      assert RoundRobin.total_rounds(4, 1) == 3
      assert RoundRobin.total_rounds(6, 1) == 5
      assert RoundRobin.total_rounds(5, 1) == 5
      assert RoundRobin.total_rounds(7, 1) == 7
    end

    test "each player meets every other player exactly once per cycle (N=6)" do
      all_pairs =
        for round <- 1..5,
            {:ok, matches} = RoundRobin.schedule(6, 1, round),
            {:pairing, w, b} <- matches do
          Enum.sort([w, b]) |> List.to_tuple()
        end

      expected = for a <- 1..6, b <- 1..6, a < b, do: {a, b}
      assert Enum.sort(all_pairs) == Enum.sort(expected)
    end

    test "odd N gives every real player exactly one zero-point-shaped bye per cycle (N=5)" do
      byes =
        for round <- 1..5,
            {:ok, matches} = RoundRobin.schedule(5, 1, round),
            {:bye, n} <- matches do
          n
        end

      assert Enum.sort(byes) == [1, 2, 3, 4, 5]

      # And every round has exactly one bye plus two real games (5 players
      # -> effective_n 6 -> 3 "matches", one of them structural).
      for round <- 1..5 do
        assert {:ok, matches} = RoundRobin.schedule(5, 1, round)
        assert length(matches) == 3
        assert Enum.count(matches, &match?({:bye, _}, &1)) == 1
        assert Enum.count(matches, &match?({:pairing, _, _}, &1)) == 2
      end
    end

    test "double cycle reverses colours round-for-round and doubles the round count" do
      assert RoundRobin.total_rounds(4, 2) == 6

      for round <- 1..3 do
        assert {:ok, cycle1} = RoundRobin.schedule(4, 2, round)
        assert {:ok, cycle2} = RoundRobin.schedule(4, 2, round + 3)

        assert cycle2 == Enum.map(cycle1, fn {:pairing, w, b} -> {:pairing, b, w} end)
      end
    end

    test "pairing beyond the final round returns the schedule-complete error" do
      assert RoundRobin.schedule(4, 1, 4) ==
               {:error, "All rounds have been paired (round-robin schedule complete)"}

      assert RoundRobin.schedule(4, 2, 7) ==
               {:error, "All rounds have been paired (round-robin schedule complete)"}
    end

    test "determinism: computing the same round twice yields identical results" do
      assert RoundRobin.schedule(6, 1, 2) == RoundRobin.schedule(6, 1, 2)
      assert RoundRobin.schedule(5, 2, 4) == RoundRobin.schedule(5, 2, 4)
    end
  end

  ## ---------- match_schedule/2 & match_total_rounds/1: "match format" ----------
  ##
  ## rr_match_format's immediate two-game rematch — physical round 2k-1/2k
  ## are match k's two legs — as opposed to rr_cycles=2's far-apart repeat
  ## (already covered above).

  describe "match_schedule/2 — structural properties" do
    test "leg 2 is a byte-for-byte colour-mirrored copy of leg 1's pairings (N=4)" do
      for match <- 1..3 do
        leg1_round = 2 * match - 1
        leg2_round = 2 * match

        assert {:ok, leg1} = RoundRobin.match_schedule(4, leg1_round)
        assert {:ok, leg2} = RoundRobin.match_schedule(4, leg2_round)

        assert leg2 == Enum.map(leg1, fn {:pairing, w, b} -> {:pairing, b, w} end)
      end
    end

    test "leg 1 of each match matches the plain single-cycle schedule (N=4)" do
      for match <- 1..3 do
        assert RoundRobin.match_schedule(4, 2 * match - 1) == RoundRobin.schedule(4, 1, match)
      end
    end

    test "bye rows appear identically (same player, unmirrored) in both legs of a match (N=5)" do
      for match <- 1..5 do
        leg1_round = 2 * match - 1
        leg2_round = 2 * match

        assert {:ok, leg1} = RoundRobin.match_schedule(5, leg1_round)
        assert {:ok, leg2} = RoundRobin.match_schedule(5, leg2_round)

        leg1_bye = Enum.find(leg1, &match?({:bye, _}, &1))
        leg2_bye = Enum.find(leg2, &match?({:bye, _}, &1))

        assert leg1_bye == leg2_bye
        refute is_nil(leg1_bye)
      end
    end

    test "pairing beyond the final match errors like schedule/3" do
      assert RoundRobin.match_schedule(4, 7) ==
               {:error, "All rounds have been paired (round-robin schedule complete)"}
    end

    test "determinism: computing the same physical round twice yields identical results" do
      assert RoundRobin.match_schedule(6, 4) == RoundRobin.match_schedule(6, 4)
    end
  end

  describe "match_total_rounds/1" do
    test "is double the single-cycle total_rounds/2 value" do
      assert RoundRobin.match_total_rounds(4) == 2 * RoundRobin.total_rounds(4, 1)
      assert RoundRobin.match_total_rounds(6) == 2 * RoundRobin.total_rounds(6, 1)
      assert RoundRobin.match_total_rounds(5) == 2 * RoundRobin.total_rounds(5, 1)
    end
  end

  describe "pair_next_round/1 with rr_match_format — end-to-end" do
    test "round 1 and round 2 pair the same players with reversed colours, each in its own round/pairing rows" do
      tournament = round_robin_tournament(rr_cycles: 1, rr_match_format: true)

      a = insert_player(tournament, "Alice", fide_rating: 2000)
      b = insert_player(tournament, "Bob", fide_rating: 1900)
      c = insert_player(tournament, "Carol", fide_rating: 1800)
      d = insert_player(tournament, "Dave", fide_rating: 1700)

      assert {:ok, round1} = Pairing.pair_next_round(tournament)
      assert {:ok, round2} = Pairing.pair_next_round(tournament)

      assert round1.number == 1
      assert round2.number == 2
      assert round1.id != round2.id

      round1 = Repo.preload(round1, :pairings)
      round2 = Repo.preload(round2, :pairings)

      # Round 1 (leg 1) is the plain single-cycle Berger round 1: {1,4}
      # white, {2,3} white -> Alice/Dave and Bob/Carol.
      pairs1 = Enum.map(round1.pairings, &{&1.white_player_id, &1.black_player_id})
      assert {a.id, d.id} in pairs1
      assert {b.id, c.id} in pairs1

      # Round 2 (leg 2) is the exact same pairs, colours reversed.
      pairs2 = Enum.map(round2.pairings, &{&1.white_player_id, &1.black_player_id})
      assert {d.id, a.id} in pairs2
      assert {c.id, b.id} in pairs2

      # Each round has its own independent Pairing rows — never two
      # Pairings sharing a Round.
      assert Enum.all?(round1.pairings, &(&1.round_id == round1.id))
      assert Enum.all?(round2.pairings, &(&1.round_id == round2.id))
    end

    test "byes land correctly across both legs of a match (odd player count)" do
      tournament = round_robin_tournament(rr_cycles: 1, rr_match_format: true)

      a = insert_player(tournament, "Alice", fide_rating: 2000)
      insert_player(tournament, "Bob", fide_rating: 1900)
      insert_player(tournament, "Carol", fide_rating: 1800)
      insert_player(tournament, "Dave", fide_rating: 1700)
      insert_player(tournament, "Eve", fide_rating: 1600)

      assert {:ok, _round1} = Pairing.pair_next_round(tournament)
      assert {:ok, _round2} = Pairing.pair_next_round(tournament)

      byes =
        Repo.all(
          from bye in "byes",
            where: bye.tournament_id == ^tournament.id,
            select: %{player_id: bye.player_id, round: bye.round, type: bye.type}
        )
        |> Enum.sort_by(& &1.round)

      assert byes == [
               %{player_id: a.id, round: 1, type: "requested-zero"},
               %{player_id: a.id, round: 2, type: "requested-zero"}
             ]
    end
  end

  ## ---------- end-to-end: the public dispatcher, DB writes, standings ----------

  describe "pair_next_round/1 via the public dispatcher" do
    test "wires up round-robin end-to-end: freezes pairing numbers, creates round 1 matching the Berger table" do
      tournament = round_robin_tournament(rr_cycles: 1)

      a = insert_player(tournament, "Alice", fide_rating: 2000)
      b = insert_player(tournament, "Bob", fide_rating: 1900)
      c = insert_player(tournament, "Carol", fide_rating: 1800)
      d = insert_player(tournament, "Dave", fide_rating: 1700)

      assert {:ok, round} = Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)

      assert round.number == 1
      assert length(round.pairings) == 2

      # Frozen highest-rating-first: Alice=1, Bob=2, Carol=3, Dave=4 -> round
      # 1 is Berger {1,4} (Alice white vs Dave) and {2,3} (Bob white vs Carol).
      pairs = Enum.map(round.pairings, &{&1.white_player_id, &1.black_player_id})
      assert {a.id, d.id} in pairs
      assert {b.id, c.id} in pairs
    end

    test "a recorded result and standings both work without crashing" do
      tournament = round_robin_tournament(rr_cycles: 1)

      insert_player(tournament, "Alice", fide_rating: 2000)
      insert_player(tournament, "Bob", fide_rating: 1900)
      insert_player(tournament, "Carol", fide_rating: 1800)
      insert_player(tournament, "Dave", fide_rating: 1700)

      assert {:ok, round} = Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)
      [pairing | _] = round.pairings

      assert {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")

      entries = Standings.standings(tournament)
      assert length(entries) == 4
      assert Enum.any?(entries, &(&1.points == 1.0))
    end

    test "pairing round 1 flips the tournament's derived status from setup to running" do
      tournament = round_robin_tournament(rr_cycles: 1)
      assert tournament.status == "setup"

      insert_player(tournament, "Alice", fide_rating: 2000)
      insert_player(tournament, "Bob", fide_rating: 1900)
      insert_player(tournament, "Carol", fide_rating: 1800)
      insert_player(tournament, "Dave", fide_rating: 1700)

      assert {:ok, _round} = Pairing.pair_next_round(tournament)

      # PairingsEngine.RoundRobin doesn't call Tournaments.refresh_status!/1
      # itself — the dispatcher in PairingsEngine.Pairing does it centrally
      # for round_robin/keizer, same as the Swiss path already did.
      assert Tournaments.get_tournament!(tournament.id).status == "running"
    end

    test "odd player count gives the sitting-out player a zero-point bye row via the dispatcher" do
      tournament = round_robin_tournament(rr_cycles: 1)

      a = insert_player(tournament, "Alice", fide_rating: 2000)
      insert_player(tournament, "Bob", fide_rating: 1900)
      insert_player(tournament, "Carol", fide_rating: 1800)
      insert_player(tournament, "Dave", fide_rating: 1700)
      insert_player(tournament, "Eve", fide_rating: 1600)

      # 5 players (odd), highest-rated (Alice, #1) plays the phantom #6 in
      # round 1 (Berger table for effective N=6, round 1: 1-6) -> Alice
      # gets the bye.
      assert {:ok, round} = Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)

      assert length(round.pairings) == 2

      byes =
        Repo.all(
          from bye in "byes",
            where: bye.tournament_id == ^tournament.id,
            select: %{player_id: bye.player_id, round: bye.round, type: bye.type}
        )

      assert byes == [%{player_id: a.id, round: 1, type: "requested-zero"}]

      pairing_player_ids =
        round.pairings |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])

      refute a.id in pairing_player_ids
    end

    ## ---------- byes must invalidate a hand-set manual standings order ----------
    #
    # SWAR parity #23 (manual standings) fix 3: a "requested-zero" bye
    # awards points immediately (see PairingsEngine.Standings) without ever
    # going through Tournaments.update_pairing_result/2, so every bye-write
    # site needs its own Tournaments.invalidate_manual_ranking/1 call — see
    # PairingsEngine.Pairing.insert_round_absentee_byes/3 for the Swiss/
    # JaVaFo-path equivalent and docs/manual-standings.md.

    test "an odd-player-count structural bye marks a hand-set manual order stale" do
      tournament = round_robin_tournament(rr_cycles: 1)

      insert_player(tournament, "Alice", fide_rating: 2000)
      insert_player(tournament, "Bob", fide_rating: 1900)
      insert_player(tournament, "Carol", fide_rating: 1800)
      insert_player(tournament, "Dave", fide_rating: 1700)
      insert_player(tournament, "Eve", fide_rating: 1600)

      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)
      refute Repo.reload!(tournament).manual_ranking_stale

      # 5 players (odd) -> round 1 gives Alice (#1) the structural bye
      # (see the equivalent dispatcher test above).
      assert {:ok, _round} = Pairing.pair_next_round(tournament)

      assert Repo.reload!(tournament).manual_ranking_stale
    end

    test "a round with no byes at all (even player count) does not touch a fresh manual order" do
      tournament = round_robin_tournament(rr_cycles: 1)

      insert_player(tournament, "Alice", fide_rating: 2000)
      insert_player(tournament, "Bob", fide_rating: 1900)
      insert_player(tournament, "Carol", fide_rating: 1800)
      insert_player(tournament, "Dave", fide_rating: 1700)

      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)
      refute Repo.reload!(tournament).manual_ranking_stale

      assert {:ok, _round} = Pairing.pair_next_round(tournament)

      refute Repo.reload!(tournament).manual_ranking_stale
    end

    test "double cycle plays 2*(N-1) rounds and errors once the schedule is exhausted" do
      tournament = round_robin_tournament(rr_cycles: 2)

      insert_player(tournament, "Alice", fide_rating: 2000)
      insert_player(tournament, "Bob", fide_rating: 1900)
      insert_player(tournament, "Carol", fide_rating: 1800)
      insert_player(tournament, "Dave", fide_rating: 1700)

      for expected_round <- 1..6 do
        assert {:ok, round} = Pairing.pair_next_round(tournament)
        assert round.number == expected_round

        round_id = round.id

        Repo.all(from p in "pairings", where: p.round_id == ^round_id, select: p.id)
        |> Enum.each(fn id ->
          Repo.update_all(from(p in "pairings", where: p.id == ^id), set: [result: "1-0"])
        end)
      end

      assert Pairing.pair_next_round(tournament) ==
               {:error, "All rounds have been paired (round-robin schedule complete)"}
    end

    test "not enough schedulable players returns the same error the Swiss path uses" do
      tournament = round_robin_tournament(rr_cycles: 1)
      insert_player(tournament, "Alice", fide_rating: 2000)

      assert Pairing.pair_next_round(tournament) ==
               {:error, "At least two active players are needed"}
    end

    test "players added after the freeze are excluded from every later round" do
      tournament = round_robin_tournament(rr_cycles: 1)

      insert_player(tournament, "Alice", fide_rating: 2000)
      insert_player(tournament, "Bob", fide_rating: 1900)
      insert_player(tournament, "Carol", fide_rating: 1800)
      insert_player(tournament, "Dave", fide_rating: 1700)

      assert {:ok, _round1} = Pairing.pair_next_round(tournament)

      latecomer = insert_player(tournament, "Zoe", fide_rating: 2500)
      refute latecomer.pairing_number

      assert {:ok, round2} = Pairing.pair_next_round(tournament)
      round2 = Repo.preload(round2, :pairings)

      pairing_player_ids =
        round2.pairings |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])

      refute latecomer.id in pairing_player_ids

      latecomer = Repo.get!(Tournaments.Player, latecomer.id)
      assert latecomer.pairing_number == nil
    end

    test "pairing round K produces the same result whether it's the first or a later call" do
      # Same tournament, computed once by pairing rounds 1 then 2 in order...
      t1 = round_robin_tournament(rr_cycles: 1)
      insert_player(t1, "Alice", fide_rating: 2000)
      insert_player(t1, "Bob", fide_rating: 1900)
      insert_player(t1, "Carol", fide_rating: 1800)
      insert_player(t1, "Dave", fide_rating: 1700)

      {:ok, _} = Pairing.pair_next_round(t1)
      {:ok, round2_a} = Pairing.pair_next_round(t1)

      # Capture round 2's pairings before deleting it — delete_round cascades
      # and removes them from the DB.
      pairs_a =
        round2_a
        |> Repo.preload(:pairings)
        |> Map.fetch!(:pairings)
        |> Enum.map(&{&1.white_player_id, &1.black_player_id})
        |> Enum.sort()

      # ...vs. deleting round 2 and re-pairing it fresh: the pure schedule
      # doesn't depend on when it's called, so this must be identical.
      :ok = PairingsEngine.Pairing.delete_round(t1.id, 2)
      {:ok, round2_b} = Pairing.pair_next_round(t1)

      pairs_b =
        round2_b
        |> Repo.preload(:pairings)
        |> Map.fetch!(:pairings)
        |> Enum.map(&{&1.white_player_id, &1.black_player_id})
        |> Enum.sort()

      assert pairs_a == pairs_b
    end
  end

  ## ---------- absent/forfeit players auto-record a forfeit result ----------
  ##
  ## Round-robin's Berger schedule is frozen player-count math (see
  ## moduledoc: "Freezing pairing numbers") — an absent/forfeit player still
  ## gets paired every round by design, but shouldn't be left with a blank
  ## result for the arbiter to notice manually across dozens of players.
  ## This matters most for a tournament continued from a SWAR import, where
  ## `pairing_number` (and `absent`/`forfeit`) are set directly at player
  ## creation, bypassing `ensure_frozen/1`'s one-time freeze entirely — these
  ## tests simulate that shape directly via `pairing_number` in the attrs
  ## rather than going through the SWAR binary parser.

  describe "pair_next_round/1 — absent/forfeit players auto-record a forfeit result" do
    # `ensure_frozen/1` explicitly EXCLUDES currently-absent/forfeit players
    # from the initial freeze itself (`p.absent == false and p.forfeit ==
    # false` in its query) — so a player marked absent/forfeit *before* ever
    # being frozen wouldn't get a `pairing_number` at all via that path, and
    # these tests would be exercising "excluded from the schedule" rather
    # than the real bug. Every test below therefore sets `pairing_number`
    # directly at player creation (all four players at once, so
    # `already_frozen?` is true from the first insert and `ensure_frozen/1`
    # never runs) — this is exactly the SWAR-import shape the real bug lives
    # in: pairing numbers pre-set, absent/forfeit pre-set, freeze bypassed.

    test "an absent black player's pairing is auto-recorded as a white-forfeit-win" do
      tournament = round_robin_tournament(rr_cycles: 1)

      a = insert_player(tournament, "Alice", fide_rating: 2000, pairing_number: 1)
      insert_player(tournament, "Bob", fide_rating: 1900, pairing_number: 2)
      c = insert_player(tournament, "Carol", fide_rating: 1800, pairing_number: 3)
      d = insert_player(tournament, "Dave", fide_rating: 1700, pairing_number: 4, absent: true)

      # Round 1 is Berger {1,4} (Alice white vs Dave) and {2,3} (Bob white
      # vs Carol). Dave is absent, so the Alice/Dave pairing must come back
      # "1-0FF".
      assert {:ok, round} = Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)

      alice_dave =
        Enum.find(round.pairings, &(&1.white_player_id == a.id and &1.black_player_id == d.id))

      bob_carol =
        Enum.find(round.pairings, &(&1.white_player_id != a.id or &1.black_player_id != d.id))

      assert alice_dave.result == "1-0FF"
      refute is_nil(bob_carol)
      assert bob_carol.result == ""
      assert bob_carol.white_player_id in [c.id] or bob_carol.black_player_id in [c.id]
    end

    test "an absent white player's pairing is auto-recorded as a black-forfeit-win" do
      tournament = round_robin_tournament(rr_cycles: 1)

      a = insert_player(tournament, "Alice", fide_rating: 2000, pairing_number: 1, absent: true)
      insert_player(tournament, "Bob", fide_rating: 1900, pairing_number: 2)
      insert_player(tournament, "Carol", fide_rating: 1800, pairing_number: 3)
      d = insert_player(tournament, "Dave", fide_rating: 1700, pairing_number: 4)

      # Round 1: {1,4} Alice(white)/Dave, {2,3} Bob(white)/Carol. Alice
      # (white) is absent -> black (Dave) wins by forfeit.
      assert {:ok, round} = Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)

      alice_dave =
        Enum.find(round.pairings, &(&1.white_player_id == a.id and &1.black_player_id == d.id))

      other = Enum.find(round.pairings, &(&1.id != alice_dave.id))

      assert alice_dave.result == "0-1FF"
      refute is_nil(other)
      assert other.result == ""
    end

    test "a forfeit (not just absent) player's pairing is auto-recorded the same way" do
      tournament = round_robin_tournament(rr_cycles: 1)

      a = insert_player(tournament, "Alice", fide_rating: 2000, pairing_number: 1)
      insert_player(tournament, "Bob", fide_rating: 1900, pairing_number: 2)
      insert_player(tournament, "Carol", fide_rating: 1800, pairing_number: 3)
      d = insert_player(tournament, "Dave", fide_rating: 1700, pairing_number: 4, forfeit: true)

      assert {:ok, round} = Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)

      alice_dave =
        Enum.find(round.pairings, &(&1.white_player_id == a.id and &1.black_player_id == d.id))

      assert alice_dave.result == "1-0FF"
    end

    test "two absent players paired against each other are recorded as a double forfeit" do
      tournament = round_robin_tournament(rr_cycles: 1)

      a = insert_player(tournament, "Alice", fide_rating: 2000, pairing_number: 1, absent: true)
      insert_player(tournament, "Bob", fide_rating: 1900, pairing_number: 2)
      insert_player(tournament, "Carol", fide_rating: 1800, pairing_number: 3)
      d = insert_player(tournament, "Dave", fide_rating: 1700, pairing_number: 4, absent: true)

      # Round 1's {1,4} pairing is Alice/Dave -> both absent -> "0-0FF".
      assert {:ok, round} = Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)

      alice_dave =
        Enum.find(round.pairings, &(&1.white_player_id == a.id and &1.black_player_id == d.id))

      assert alice_dave.result == "0-0FF"
    end

    test "an absent/forfeit player's forced pairing still feeds standings via the existing forfeit-result handling" do
      tournament = round_robin_tournament(rr_cycles: 1)

      insert_player(tournament, "Alice", fide_rating: 2000, pairing_number: 1)
      insert_player(tournament, "Bob", fide_rating: 1900, pairing_number: 2)
      insert_player(tournament, "Carol", fide_rating: 1800, pairing_number: 3)
      insert_player(tournament, "Dave", fide_rating: 1700, pairing_number: 4, absent: true)

      assert {:ok, _round} = Pairing.pair_next_round(tournament)

      entries = Standings.standings(tournament)
      assert length(entries) == 4
      # Alice (white vs the absent Dave) already has her forfeit-win point
      # without anyone calling Tournaments.update_pairing_result/2.
      assert Enum.any?(entries, &(&1.points == 1.0))
    end

    test "simulating the SWAR-import shape: pairing_number pre-set at creation, absent pre-set from import" do
      tournament = round_robin_tournament(rr_cycles: 1)

      # SWAR-imported players get pairing_number set directly at creation
      # (bypassing ensure_frozen/1's freeze, since already_frozen? is true
      # once any pairing_number exists) instead of via the frozen-by-rating
      # path the other tests above exercise.
      a = insert_player(tournament, "Alice", fide_rating: 2000, pairing_number: 1)
      insert_player(tournament, "Bob", fide_rating: 1900, pairing_number: 2)
      insert_player(tournament, "Carol", fide_rating: 1800, pairing_number: 3)

      d =
        insert_player(tournament, "Dave",
          fide_rating: 1700,
          pairing_number: 4,
          absent: true
        )

      assert {:ok, round} = Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)

      alice_dave =
        Enum.find(round.pairings, &(&1.white_player_id == a.id and &1.black_player_id == d.id))

      assert alice_dave.result == "1-0FF"
    end
  end

  ## ---------- helpers ----------

  defp round_robin_tournament(attrs) do
    Repo.insert!(%Tournament{
      name: "RR Test",
      type: "swiss",
      rounds_count: 9,
      pairing_system: "round_robin",
      rr_cycles: Keyword.fetch!(attrs, :rr_cycles),
      rr_match_format: Keyword.get(attrs, :rr_match_format, false)
    })
  end

  defp insert_player(tournament, name, attrs) do
    defaults = %{tournament_id: tournament.id, name: name}
    {:ok, player} = Tournaments.create_player(tournament.id, Map.merge(defaults, Map.new(attrs)))
    player
  end
end
