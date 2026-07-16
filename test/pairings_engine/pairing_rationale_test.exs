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

  describe "starting-rank / pairing-number gap" do
    @tag :javafo
    test "detects a round-specific absentee leaving a gap in the middle of the field" do
      t = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})

      p1 = insert_player(t, "Alice", fide_rating: 2000)
      p2 = insert_player(t, "Bob", fide_rating: 1900)
      # Rated between Bob and Dave, so after pairing numbers freeze
      # (highest rating first), Carol lands 3rd of 5 — sitting her out this
      # round only leaves a gap in the MIDDLE of the starting-rank range.
      carol = insert_player(t, "Carol", fide_rating: 1800, absent_rounds: "1")
      p4 = insert_player(t, "Dave", fide_rating: 1700)
      p5 = insert_player(t, "Eve", fide_rating: 1600)

      assert {:ok, _round} = Pairing.pair_next_round(t)

      # Pairing numbers freeze during pairing, so reload to see them.
      carol = Repo.get!(PairingsEngine.Tournaments.Player, carol.id)
      p1 = Repo.get!(PairingsEngine.Tournaments.Player, p1.id)
      p2 = Repo.get!(PairingsEngine.Tournaments.Player, p2.id)
      p4 = Repo.get!(PairingsEngine.Tournaments.Player, p4.id)
      p5 = Repo.get!(PairingsEngine.Tournaments.Player, p5.id)

      rationale = PairingRationale.for_round(t, 1)

      refute is_nil(rationale.pairing_gap)
      assert carol.pairing_number in rationale.pairing_gap.missing_numbers
      assert Enum.any?(rationale.pairing_gap.players, &(&1.id == carol.id))

      for p <- [p1, p2, p4, p5] do
        refute p.pairing_number in rationale.pairing_gap.missing_numbers
      end
    end

    @tag :javafo
    test "no gap is reported for a normal, fully-eligible field" do
      t = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})

      for name <- ~w(Alice Bob Carol Dave) do
        {:ok, _} = Tournaments.create_player(t.id, %{name: name})
      end

      assert {:ok, _round} = Pairing.pair_next_round(t)

      rationale = PairingRationale.for_round(t, 1)
      assert rationale.pairing_gap == nil
    end
  end

  defp insert_player(tournament, name, attrs) do
    {:ok, player} =
      Tournaments.create_player(tournament.id, Map.new([{:name, name} | attrs]))

    player
  end
end
