defmodule PairingsEngine.PairingRationaleTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, PairingRationale, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

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
end
