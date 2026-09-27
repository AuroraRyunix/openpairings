defmodule PairingsEngine.PairingDeviationsTest do
  @moduledoc """
  Rounds paired away from C.04.3 by something that is not a FIDE rule -
  extra points in the pairing (a counted handicap, acceleration mode) and
  the arbiter's "only if possible" wishes - mark the tournament the way a
  bye exclusion that moves the bye does: the first round in which they
  actually change what the engine is given (or pairs) is stamped as
  `fide_compliance_lost_round`, and a setting that bites nowhere records
  nothing. Baku is FIDE's own and never marks anything. Ainalrami only, so
  no JVM.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Round, Tournament}

  defp tournament(attrs) do
    Repo.insert!(
      struct(
        %Tournament{
          name: "Deviations",
          type: "swiss",
          rounds_count: 5,
          tiebreaks: ~w(BH),
          pairing_engine: "ainalrami",
          initial_colour: "white",
          round_dates: List.duplicate("2026-09-01", 5)
        },
        attrs
      )
    )
  end

  defp roster(t, count, extra \\ %{}) do
    for n <- 1..count do
      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "P#{n}",
          "fide_rating" => 2050 - n * 50,
          "extra_points" => Map.get(extra, n, 0.0)
        })

      p
    end
  end

  defp white_wins(round) do
    round
    |> Repo.preload(:pairings, force: true)
    |> Map.fetch!(:pairings)
    |> Enum.each(fn p ->
      if p.black_player_id, do: {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end)
  end

  defp met?(round, a, b) do
    round
    |> Repo.preload(:pairings, force: true)
    |> Map.fetch!(:pairings)
    |> Enum.any?(
      &(Enum.sort([&1.white_player_id, &1.black_player_id]) == Enum.sort([a.id, b.id]))
    )
  end

  defp lost_round(t), do: Repo.reload!(t).fide_compliance_lost_round

  describe "extra points" do
    test "acceleration with nobody holding points pairs as FIDE and records nothing" do
      t = tournament(%{extra_points_mode: "acceleration"})
      roster(t, 8)

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert round.virtual_points == %{}
      assert Pairing.pairing_deviations(t, 1) == []
      assert lost_round(t) == nil
    end

    test "acceleration points reaching the engine stamp the first round, and only that one" do
      t = tournament(%{extra_points_mode: "acceleration"})
      roster(t, 8, %{1 => 1.0, 2 => 1.0, 3 => 1.0, 4 => 1.0})

      assert {:ok, r1} = Pairing.pair_next_round(t)
      assert Pairing.pairing_deviations(t, 1) == [:extra_points]
      assert lost_round(t) == 1

      white_wins(r1)
      assert {:ok, _r2} = Pairing.pair_next_round(Repo.reload!(t))
      assert lost_round(t) == 1
    end

    test "a counted handicap in the pairing stamps the round" do
      t = tournament(%{extra_points_mode: "handicap", count_extra_points: true})
      roster(t, 8, %{8 => 1.5})

      assert {:ok, _round} = Pairing.pair_next_round(t)
      assert Pairing.pairing_deviations(t, 1) == [:extra_points]
      assert lost_round(t) == 1
    end

    test "a handicap that is not counted never reaches the pairing and records nothing" do
      t = tournament(%{extra_points_mode: "handicap", count_extra_points: false})
      roster(t, 8, %{8 => 1.5})

      assert {:ok, _round} = Pairing.pair_next_round(t)
      assert Pairing.pairing_deviations(t, 1) == []
      assert lost_round(t) == nil
    end

    test "points held only in an earlier round's history still reach the engine" do
      # A SWAR file brings its rounds' XtraPts: the players hold nothing
      # today, but every player's XXA history carries round 1's value, so
      # round 2 is paired with it.
      t = tournament(%{extra_points_mode: "acceleration"})
      [p1 | _] = roster(t, 8)

      assert {:ok, r1} = Pairing.pair_next_round(t)
      assert lost_round(t) == nil

      r1 |> Ecto.Changeset.change(virtual_points: %{to_string(p1.id) => 1.0}) |> Repo.update!()
      white_wins(r1)

      assert {:ok, _r2} = Pairing.pair_next_round(Repo.reload!(t))
      assert Pairing.pairing_deviations(t, 2) == [:extra_points]
      assert lost_round(t) == 2
    end

    test "Baku stays FIDE: its virtual points never mark the tournament" do
      t = tournament(%{acceleration: "baku"})
      roster(t, 8, %{1 => 1.0})

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert %Round{} = round
      assert Pairing.pairing_deviations(t, 1) == []
      assert lost_round(t) == nil
    end
  end

  describe "soft rules" do
    # Four players: round 1 pairs P1-P3 and P2-P4, so a wish to keep P1 and
    # P3 apart can only be honoured by changing the round, and one for P1
    # and P4 is honoured already.
    test "a wish that moves a board stamps the round and says so on the account" do
      t = tournament(%{})
      [p1, _p2, p3, _p4] = roster(t, 4)
      {:ok, _} = Tournaments.add_forbidden_pairing(t, p1.id, p3.id, soft: true)

      assert {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
      refute met?(round, p1, p3)

      assert Enum.any?(round.explanation["sections"], &(&1["soft_pairs_moved"] == true))
      assert Pairing.pairing_deviations(t, 1) == [:soft_pairs]
      assert lost_round(t) == 1
    end

    test "a wish the rules already honour changes nothing and records nothing" do
      t = tournament(%{})
      [p1, _p2, _p3, p4] = roster(t, 4)
      {:ok, _} = Tournaments.add_forbidden_pairing(t, p1.id, p4.id, soft: true)

      assert {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
      refute met?(round, p1, p4)

      refute Enum.any?(round.explanation["sections"], &Map.has_key?(&1, "soft_pairs_moved"))
      assert Pairing.pairing_deviations(t, 1) == []
      assert lost_round(t) == nil
    end
  end

  test "a round already marked by a setting keeps its round" do
    t = tournament(%{extra_points_mode: "acceleration", fide_compliance_lost_round: 0})
    roster(t, 8, %{1 => 1.0})

    assert {:ok, _round} = Pairing.pair_next_round(t)
    assert lost_round(t) == 0
  end
end
