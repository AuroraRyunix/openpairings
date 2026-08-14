defmodule PairingsEngine.PairingRationaleTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, PairingRationale, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngine.Tournaments.Round, as: RoundSchema
  alias PairingsEngine.Tournaments.Pairing, as: PairingSchema

  ## ---------- pure due-colour logic ----------

  describe "due_colour/1" do
    test "no history means no preference" do
      assert PairingRationale.due_colour([]) == nil
    end

    test "more whites than blacks is due black, and vice versa" do
      assert PairingRationale.due_colour([:w, :w, :b]) == :b
      assert PairingRationale.due_colour([:b, :b, :w]) == :w
    end

    test "balanced history alternates from the most recent colour" do
      assert PairingRationale.due_colour([:w, :b]) == :w
      assert PairingRationale.due_colour([:b, :w]) == :b
    end
  end

  test "for_round/2 returns nil for a round that hasn't been paired" do
    t = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5})
    assert PairingRationale.for_round(t, 1) == nil
  end

  ## ---------- round robin: deterministic Berger explanation ----------

  test "for_round/2 explains a round-robin round as a Berger schedule slot" do
    t =
      Repo.insert!(%Tournament{
        name: "RR",
        type: "swiss",
        rounds_count: 9,
        pairing_system: "round_robin",
        rr_cycles: 1
      })

    for name <- ~w(Alice Bob Carol Dave) do
      {:ok, _} = Tournaments.create_player(t.id, %{name: name})
    end

    assert {:ok, _round} = Pairing.pair_next_round(t)

    rationale = PairingRationale.for_round(t, 1)
    assert rationale.pairing_system == "round_robin"
    assert rationale.berger.match_format == false
    assert rationale.berger.cycle == 1
    assert rationale.berger.cycle_round == 1
    assert rationale.berger.deterministic == true
    # 4 players → 2 boards, no bye.
    assert rationale.summary.boards == 2
    assert rationale.summary.byes == 0
  end

  ## ---------- swiss (real JaVaFo): floater + bye on an odd field ----------

  @tag :javafo
  test "for_round/2 flags the floater and names the bye recipient in a later Swiss round" do
    t = Repo.insert!(%Tournament{name: "Swiss", type: "swiss", rounds_count: 5})

    # Five players — odd field, so every round has a pairing-allocated bye.
    p =
      for {name, rating} <- [
            {"Alice", 2000},
            {"Bob", 1900},
            {"Carol", 1800},
            {"Dave", 1700},
            {"Erin", 1600}
          ],
          into: %{} do
        {:ok, player} = Tournaments.create_player(t.id, %{name: name, fide_rating: rating})
        {name, player}
      end

    # Round 1.
    assert {:ok, round1} = Pairing.pair_next_round(t)
    round1 = Repo.preload(round1, :pairings)
    # Enter decisive results so round 2 has real score groups (a top group
    # and a bottom group), guaranteeing at least the possibility of floats.
    enter_all_results(round1)

    assert {:ok, _round2} = Pairing.pair_next_round(t)

    rationale = PairingRationale.for_round(t, 2)
    assert rationale.pairing_system == "swiss"

    # There must be exactly one pairing-allocated bye (odd field).
    assert rationale.summary.byes == 1
    assert %{bye_detail: detail} = rationale.byes.allocated
    assert detail.player.id in Enum.map(Map.values(p), & &1.id)

    # No rematches in round 2 (a fresh field, JaVaFo avoids repeats).
    assert rationale.summary.rematches == 0

    # Score groups were computed from pre-round standings.
    assert rationale.score_groups != []
    assert Enum.any?(rationale.score_groups, &(&1.score > 0.0))
  end

  # Sets every non-bye board in a round to a White win, so the round is
  # complete and produces a spread of scores for the next round.
  defp enter_all_results(round) do
    Enum.each(round.pairings, fn pairing ->
      if pairing.black_player_id do
        {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")
      end
    end)
  end

  ## ---------- pre-round scores follow the tournament's ranking rule ----------

  # The score brackets this module explains have to be the ones the
  # tournament actually ranks (and pairs) on. Reading `entry.total` here
  # instead of `Standings.rank_score/2` put a player's administrative extra
  # points (SWAR "XtPts") into the rationale even when `count_extra_points`
  # was off — the default, and what every SWAR import starts as — so the
  # rationale's numbers disagreed with the standings table by exactly the
  # extra points, on every board, every round.
  describe "extra points count in the rationale only when the tournament counts them" do
    defp tournament_with_extra_points(count_extra_points) do
      t =
        Repo.insert!(%Tournament{
          name: "Swiss",
          type: "swiss",
          rounds_count: 5,
          count_extra_points: count_extra_points
        })

      players =
        for {name, rating, extra} <- [
              {"Alice", 2000, 0.5},
              {"Bob", 1900, 0.0},
              {"Carol", 1800, 0.0},
              {"Dave", 1700, 0.0}
            ],
            into: %{} do
          {:ok, player} =
            Tournaments.create_player(t.id, %{
              name: name,
              fide_rating: rating,
              extra_points: extra
            })

          {name, player}
        end

      assert {:ok, round1} = Pairing.pair_next_round(t)
      enter_all_results(Repo.preload(round1, :pairings))
      assert {:ok, _round2} = Pairing.pair_next_round(t)

      {t, players}
    end

    defp rationale_score(t, round_number, player_id) do
      PairingRationale.for_round(t, round_number).boards
      |> Enum.flat_map(fn b -> Enum.filter([b.white, b.black], &(&1 != nil)) end)
      |> Enum.find(&(&1.player.id == player_id))
      |> case do
        nil -> nil
        side -> side.score
      end
    end

    @tag :javafo
    test "extra points are excluded when count_extra_points is off" do
      {t, players} = tournament_with_extra_points(false)
      alice = players["Alice"]

      entry =
        PairingsEngine.Standings.standings(t, through_round: 1)
        |> Enum.find(&(&1.player.id == alice.id))

      # The fixture is only meaningful while Alice actually carries a bonus
      # the two readings disagree about.
      assert entry.extra_points == 0.5
      assert entry.total == entry.points + 0.5

      assert rationale_score(t, 2, alice.id) == entry.points
    end

    @tag :javafo
    test "extra points are included when count_extra_points is on" do
      {t, players} = tournament_with_extra_points(true)
      alice = players["Alice"]

      entry =
        PairingsEngine.Standings.standings(t, through_round: 1)
        |> Enum.find(&(&1.player.id == alice.id))

      assert entry.extra_points == 0.5
      assert rationale_score(t, 2, alice.id) == entry.total
    end
  end

  ## ---------- anomaly checks ----------

  describe "rematch anomaly flagging" do
    test "a genuine rematch outside match format is flagged as an anomaly" do
      t = Repo.insert!(%Tournament{name: "Swiss", type: "swiss", rounds_count: 5})

      {:ok, alice} = Tournaments.create_player(t.id, %{name: "Alice"})
      {:ok, bob} = Tournaments.create_player(t.id, %{name: "Bob"})

      round1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})

      Repo.insert!(%PairingSchema{
        round_id: round1.id,
        board: 1,
        white_player_id: alice.id,
        black_player_id: bob.id,
        result: "1-0"
      })

      # Round 2 hand-built with the same pair meeting again — the real
      # engine avoids this, so this simulates hand-edited/imported data.
      round2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

      Repo.insert!(%PairingSchema{
        round_id: round2.id,
        board: 1,
        white_player_id: bob.id,
        black_player_id: alice.id,
        result: ""
      })

      rationale = PairingRationale.for_round(t, 2)
      [board] = rationale.boards

      assert board.rematch == true
      assert board.rematch_anomaly == true
    end

    test "a vacated white seat doesn't crash the rationale (regression, real prod incident)" do
      # `Tournaments.vacate_seat/3` can empty EITHER colour's seat, leaving
      # the other player still seated and NOT a bye (`is_bye` only checks
      # `black_player_id`). This hand-built pairing reproduces that state
      # directly: black seated, white vacated. Before the fix, `for_round/2`
      # crashed with `(KeyError) key :id not found in: nil` computing
      # `white.id` in the rematch check — this pins that it no longer does,
      # for both round 1 (no prior history to check) and a later round
      # (`played_before` is non-empty, exercising the real MapSet lookup
      # path around the guard, not just an early-return on an empty set).
      t = Repo.insert!(%Tournament{name: "Swiss", type: "swiss", rounds_count: 5})

      {:ok, alice} = Tournaments.create_player(t.id, %{name: "Alice"})
      {:ok, bob} = Tournaments.create_player(t.id, %{name: "Bob"})
      {:ok, carol} = Tournaments.create_player(t.id, %{name: "Carol"})

      round1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})

      Repo.insert!(%PairingSchema{
        round_id: round1.id,
        board: 1,
        white_player_id: nil,
        black_player_id: bob.id,
        result: ""
      })

      Repo.insert!(%PairingSchema{
        round_id: round1.id,
        board: 2,
        white_player_id: alice.id,
        black_player_id: carol.id,
        result: "1-0"
      })

      rationale1 = PairingRationale.for_round(t, 1)
      board1 = Enum.find(rationale1.boards, &(&1.board == 1))

      assert board1.is_bye == false
      assert board1.white == nil
      assert board1.black.player.id == bob.id
      assert board1.rematch == false
      assert board1.rematch_anomaly == false

      round2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

      Repo.insert!(%PairingSchema{
        round_id: round2.id,
        board: 1,
        white_player_id: nil,
        black_player_id: bob.id,
        result: ""
      })

      rationale2 = PairingRationale.for_round(t, 2)
      board2 = Enum.find(rationale2.boards, &(&1.board == 1))

      assert board2.is_bye == false
      assert board2.white == nil
      assert board2.rematch == false
    end

    test "a match-format back-to-back rematch is NOT flagged as an anomaly" do
      t =
        Repo.insert!(%Tournament{
          name: "Swiss match format",
          type: "swiss",
          rounds_count: 5,
          swiss_match_format: true
        })

      {:ok, alice} = Tournaments.create_player(t.id, %{name: "Alice"})
      {:ok, bob} = Tournaments.create_player(t.id, %{name: "Bob"})

      round1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})

      Repo.insert!(%PairingSchema{
        round_id: round1.id,
        board: 1,
        white_player_id: alice.id,
        black_player_id: bob.id,
        result: "1-0"
      })

      round2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

      Repo.insert!(%PairingSchema{
        round_id: round2.id,
        board: 1,
        white_player_id: bob.id,
        black_player_id: alice.id,
        result: ""
      })

      rationale = PairingRationale.for_round(t, 2)
      [board] = rationale.boards

      # Still an honest "they met before" fact (unchanged meaning)...
      assert board.rematch == true
      # ...but not surfaced as an anomaly, since this format expects it.
      assert board.rematch_anomaly == false
    end
  end

  describe "repeat pairing-allocated bye anomaly" do
    test "distinguishes a second real pairing-allocated bye from a mere repeat of any bye kind" do
      t = Repo.insert!(%Tournament{name: "Byes", type: "swiss", rounds_count: 5})
      {:ok, alice} = Tournaments.create_player(t.id, %{name: "Alice"})

      # Round 1: Alice's bye came from the requested/absence "byes" table,
      # NOT a pairing-allocated one.
      Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})

      Repo.insert_all("byes", [
        %{tournament_id: t.id, player_id: alice.id, round: 1, type: "requested-zero"}
      ])

      round2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

      Repo.insert!(%PairingSchema{
        round_id: round2.id,
        board: 1,
        white_player_id: alice.id,
        black_player_id: nil,
        result: "bye"
      })

      rationale = PairingRationale.for_round(t, 2)
      [board] = rationale.boards

      # The existing, broader check still fires (any prior bye at all)...
      assert board.bye_detail.had_prior_bye == true
      # ...but the new, narrower check correctly does NOT, since round 1's
      # was a requested/absence bye, not a real pairing-allocated one.
      assert board.bye_detail.had_prior_pairing_bye == false
    end

    test "flags a genuine second pairing-allocated bye" do
      t = Repo.insert!(%Tournament{name: "Byes", type: "swiss", rounds_count: 5})
      {:ok, alice} = Tournaments.create_player(t.id, %{name: "Alice"})

      round1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})

      Repo.insert!(%PairingSchema{
        round_id: round1.id,
        board: 1,
        white_player_id: alice.id,
        black_player_id: nil,
        result: "bye"
      })

      round2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

      Repo.insert!(%PairingSchema{
        round_id: round2.id,
        board: 1,
        white_player_id: alice.id,
        black_player_id: nil,
        result: "bye"
      })

      rationale = PairingRationale.for_round(t, 2)
      [board] = rationale.boards

      assert board.bye_detail.had_prior_bye == true
      assert board.bye_detail.had_prior_pairing_bye == true
    end
  end
end
