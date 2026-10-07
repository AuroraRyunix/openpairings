defmodule PairingsEngine.StartingNumbersTest do
  # A round robin's starting numbers set before round 1, by hand or by a
  # drawing of lots (C.05 6.2; VCL4THP Q95), and used by the Berger pairing.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Pairing, Repo, StartingNumbers, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  setup do
    t =
      Repo.insert!(%Tournament{
        name: "RR draw",
        type: "swiss",
        pairing_system: "round_robin",
        rr_cycles: 1,
        rounds_count: 3
      })

    players =
      for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}],
          into: %{} do
        {:ok, p} = Tournaments.create_player(t.id, %{name: name, fide_rating: rating})
        {name, p}
      end

    %{t: t, p: players}
  end

  test "before anything is set, the order is the rating order round 1 would freeze", %{t: t} do
    assert names(StartingNumbers.order(t)) == ~w(Alice Bob Carol Dave)
    refute StartingNumbers.set_by_hand?(t)
    assert StartingNumbers.editable?(t)
  end

  test "numbers set by hand are the Berger numbers round 1 pairs by", %{t: t, p: p} do
    ids = Enum.map(~w(Dave Carol Bob Alice), &p[&1].id)
    assert {:ok, order} = StartingNumbers.set_order(t, ids)
    assert names(order) == ~w(Dave Carol Bob Alice)

    assert {:ok, round} = Pairing.pair_next_round(t)
    pairs = round |> Repo.preload(:pairings) |> pairs()

    # Berger round 1 for four: 1-4, 2-3.
    assert {p["Dave"].id, p["Alice"].id} in pairs
    assert {p["Carol"].id, p["Bob"].id} in pairs

    assert number(p["Dave"]) == 1
    assert number(p["Alice"]) == 4
  end

  test "a drawing of lots numbers the whole pool", %{t: t} do
    assert {:ok, order} = StartingNumbers.draw_lots(t, &Enum.reverse/1)
    assert names(order) == ~w(Dave Carol Bob Alice)
    assert Enum.map(order, &elem(&1, 1)) == [1, 2, 3, 4]
  end

  test "moving a player up, down, or to a number", %{t: t, p: p} do
    assert {:ok, order} = StartingNumbers.move(t, p["Dave"].id, :up)
    assert names(order) == ~w(Alice Bob Dave Carol)

    assert {:ok, order} = StartingNumbers.move_to(t, p["Carol"].id, 1)
    assert names(order) == ~w(Carol Alice Bob Dave)

    assert {:ok, order} = StartingNumbers.move(t, p["Carol"].id, :down)
    assert names(order) == ~w(Alice Carol Bob Dave)

    assert {:error, :out_of_range} = StartingNumbers.move(t, p["Alice"].id, :up)
    assert {:error, :out_of_range} = StartingNumbers.move_to(t, p["Alice"].id, 9)
  end

  test "a player entered after the draw gets the next number when round 1 is paired",
       %{t: t, p: p} do
    {:ok, _} = StartingNumbers.draw_lots(t, &Enum.reverse/1)
    {:ok, late} = Tournaments.create_player(t.id, %{name: "Eve", fide_rating: 2500})

    # Listed after the drawn numbers, not by rating.
    assert names(StartingNumbers.order(t)) == ~w(Dave Carol Bob Alice Eve)

    assert {:ok, _round} = Pairing.pair_next_round(t)
    assert number(late) == 5
    assert number(p["Dave"]) == 1
  end

  test "a withdrawn player loses their number on the next write", %{t: t, p: p} do
    {:ok, _} = StartingNumbers.draw_lots(t, &Enum.reverse/1)
    {:ok, _} = Tournaments.update_player(Repo.reload!(p["Bob"]), %{status: "withdrawn"})

    assert names(StartingNumbers.order(t)) == ~w(Dave Carol Alice)
    assert {:ok, _} = StartingNumbers.move(t, p["Alice"].id, :up)

    assert number(p["Bob"]) == nil
    assert Enum.map(~w(Dave Alice Carol), &number(p[&1])) == [1, 2, 3]
  end

  test "order by rating takes the numbers off again", %{t: t} do
    {:ok, _} = StartingNumbers.draw_lots(t, &Enum.reverse/1)
    assert StartingNumbers.set_by_hand?(t)

    assert {:ok, order} = StartingNumbers.by_rating(t)
    assert names(order) == ~w(Alice Bob Carol Dave)
    refute StartingNumbers.set_by_hand?(t)
  end

  test "frozen once round 1 is paired", %{t: t, p: p} do
    assert {:ok, _round} = Pairing.pair_next_round(t)

    refute StartingNumbers.editable?(t)
    assert {:error, :round_paired} = StartingNumbers.move(t, p["Bob"].id, :up)
    assert {:error, :round_paired} = StartingNumbers.draw_lots(t)
    assert {:error, :round_paired} = StartingNumbers.by_rating(t)
  end

  test "a list that no longer matches the pool is refused", %{t: t, p: p} do
    assert {:error, :stale_order} = StartingNumbers.set_order(t, [p["Alice"].id, p["Bob"].id])
  end

  test "a Swiss tournament has no such numbers to set" do
    swiss = Repo.insert!(%Tournament{name: "Swiss", type: "swiss", rounds_count: 5})

    refute StartingNumbers.applies?(swiss)
    refute StartingNumbers.editable?(swiss)
    assert {:error, :not_round_robin} = StartingNumbers.draw_lots(swiss)
  end

  defp names(order), do: Enum.map(order, fn {player, _n} -> player.name end)
  defp number(player), do: Repo.get!(Player, player.id).pairing_number
  defp pairs(round), do: Enum.map(round.pairings, &{&1.white_player_id, &1.black_player_id})
end
