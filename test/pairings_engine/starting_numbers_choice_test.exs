defmodule PairingsEngine.StartingNumbersChoiceTest do
  # How a round robin's players can be numbered before round 1: by rating, as
  # entered, by lot, or as already set. Each gives a reproducible order, and
  # the Berger table pairs on it.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Pairing, Repo, StartingNumbers, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  setup do
    t =
      Repo.insert!(%Tournament{
        name: "RR numbering",
        type: "swiss",
        pairing_system: "round_robin",
        rr_cycles: 1,
        rounds_count: 5
      })

    # Entered in an order that is neither the rating order nor alphabetical.
    players =
      for {name, rating} <- [
            {"Dave", 1700},
            {"Alice", 2000},
            {"Carol", 1800},
            {"Bob", 1900},
            {"Erik", 1500}
          ],
          into: %{} do
        {:ok, p} = Tournaments.create_player(t.id, %{name: name, fide_rating: rating})
        {name, p}
      end

    %{t: t, p: players}
  end

  test "as entered is the order the players were added", %{t: t, p: p} do
    assert names(StartingNumbers.numbered(t, StartingNumbers.entry_ids(t))) ==
             ~w(Dave Alice Carol Bob Erik)

    assert {:ok, order} = StartingNumbers.by_entry(t)
    assert names(order) == ~w(Dave Alice Carol Bob Erik)
    assert Enum.map(~w(Dave Alice Carol Bob Erik), &number(p[&1])) == [1, 2, 3, 4, 5]
  end

  test "as entered follows entry, not the list's own rating order", %{t: t} do
    {:ok, late} = Tournaments.create_player(t.id, %{name: "Zed", fide_rating: 2700})

    assert List.last(StartingNumbers.entry_ids(t)) == late.id
    assert hd(StartingNumbers.rating_ids(t)) == late.id
  end

  test "round 1 of the table pairs on the numbers as entered", %{t: t, p: p} do
    # Five players, so number 6 is empty: round 1 pairs 1-6 (a bye for the
    # first player), 2-5 and 3-4.
    {:ok, _} = StartingNumbers.by_entry(t)
    assert {:ok, round} = Pairing.pair_next_round(t)
    round = Repo.preload(round, :pairings)

    pairs =
      Enum.map(round.pairings, fn pr ->
        MapSet.new([pr.white_player_id, pr.black_player_id])
      end)

    assert MapSet.new([p["Alice"].id, p["Erik"].id]) in pairs
    assert MapSet.new([p["Carol"].id, p["Bob"].id]) in pairs
  end

  test "by rating is the same order every time, ties included", %{t: t} do
    # Three players on the same rating, no title: name decides, then entry.
    for name <- ~w(Yves Xena Wim) do
      {:ok, _} = Tournaments.create_player(t.id, %{name: name, fide_rating: 1600})
    end

    {:ok, twin} = Tournaments.create_player(t.id, %{name: "Wim", fide_rating: 1600})

    first = StartingNumbers.rating_ids(t)
    assert first == StartingNumbers.rating_ids(t)

    ordered = StartingNumbers.numbered(t, first)
    assert names(ordered) == ~w(Alice Bob Carol Dave Wim Wim Xena Yves Erik)

    # The two Wims keep entry order; the later one is not the twin's equal.
    wims = for {p, _n} <- ordered, p.name == "Wim", do: p.id
    assert wims == Enum.sort(wims)
    assert List.last(wims) == twin.id
  end

  test "equal ratings: the title goes first", %{t: t, p: p} do
    {:ok, gm} =
      Tournaments.create_player(t.id, %{name: "Zoe", title: "GM", fide_rating: 1800})

    ids = StartingNumbers.rating_ids(t)

    # Zoe (GM) and Carol are both 1800: the title decides, not the name.
    assert Enum.find_index(ids, &(&1 == gm.id)) < Enum.find_index(ids, &(&1 == p["Carol"].id))
  end

  test "a seed draws the same lots every time and is a permutation", %{t: t} do
    ids = StartingNumbers.entry_ids(t)

    assert StartingNumbers.shuffle_by_seed(ids, 42) == StartingNumbers.shuffle_by_seed(ids, 42)
    assert Enum.sort(StartingNumbers.shuffle_by_seed(ids, 42)) == Enum.sort(ids)
    assert StartingNumbers.lot_ids(t, 42) == StartingNumbers.shuffle_by_seed(ids, 42)

    # Not one fixed order whatever the seed.
    assert 1..20 |> Enum.map(&StartingNumbers.shuffle_by_seed(ids, &1)) |> Enum.uniq() |> length() >
             1
  end

  test "drawing from a seed writes that order, and the seed repeats it", %{t: t} do
    seed = StartingNumbers.new_seed()
    assert is_integer(seed)

    assert {:ok, order} = StartingNumbers.draw_lots_seeded(t, seed)
    drawn = Enum.map(order, fn {p, _n} -> p.id end)
    assert drawn == StartingNumbers.shuffle_by_seed(Enum.sort(drawn), seed)
    assert Enum.map(order, &elem(&1, 1)) == [1, 2, 3, 4, 5]
  end

  test "the audit details hold the choice, the seed and the order", %{t: t} do
    {:ok, order} = StartingNumbers.draw_lots_seeded(t, 7)
    details = StartingNumbers.audit_details(:lots, order, 7)

    assert details.mode == "lots"
    assert details.seed == 7
    assert Enum.map(details.order, & &1.no) == [1, 2, 3, 4, 5]
    assert Enum.map(details.order, & &1.id) == StartingNumbers.lot_ids(t, 7)
  end

  test "the preselected choice is the rating order until numbers are set", %{t: t} do
    assert StartingNumbers.default_mode(t) == :rating
    {:ok, _} = StartingNumbers.by_entry(t)
    assert StartingNumbers.default_mode(t) == :set
  end

  test "none of it changes once round 1 exists", %{t: t} do
    {:ok, _} = Pairing.pair_next_round(t)

    assert {:error, :round_paired} = StartingNumbers.by_entry(t)
    assert {:error, :round_paired} = StartingNumbers.draw_lots_seeded(t, 1)
    assert {:error, :round_paired} = StartingNumbers.set_order(t, StartingNumbers.rating_ids(t))
  end

  defp names(order), do: Enum.map(order, fn {player, _n} -> player.name end)
  defp number(player), do: Repo.get!(Player, player.id).pairing_number
end
