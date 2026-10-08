defmodule PairingsEngine.TpnTest do
  # A Swiss tournament's pairing numbers changed without changing a rating:
  # TPN exchange among equal ratings and TPN regeneration, until round 4 is
  # paired (C.04.2; VCL4THP Q147-Q155).
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Pairing, Repo, Tournaments, Tpn}
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}

  setup do
    t =
      Repo.insert!(%Tournament{
        name: "Swiss TPN",
        type: "swiss",
        pairing_system: "swiss",
        rounds_count: 5
      })

    players =
      for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1900}, {"Dave", 1800}],
          into: %{} do
        {:ok, p} = Tournaments.create_player(t.id, %{name: name, fide_rating: rating})
        {name, p}
      end

    %{t: t, p: players}
  end

  test "before anything is issued the order is the one round 1 would issue", %{t: t} do
    assert names(Tpn.order(t)) == ~w(Alice Bob Carol Dave)
    assert Tpn.editable?(t)
  end

  test "players of the same rating exchange numbers; different ratings are refused",
       %{t: t, p: p} do
    assert {:ok, order} = Tpn.exchange(t, p["Bob"].id, p["Carol"].id)
    assert names(order) == ~w(Alice Carol Bob Dave)
    assert Enum.map(~w(Alice Carol Bob Dave), &number(p[&1])) == [1, 2, 3, 4]

    assert {:error, :different_ratings} = Tpn.exchange(t, p["Alice"].id, p["Carol"].id)
  end

  test "two unrated players count as the same rating", %{t: t} do
    {:ok, x} = Tournaments.create_player(t.id, %{name: "Xavier"})
    {:ok, y} = Tournaments.create_player(t.id, %{name: "Yves"})

    assert {:ok, order} = Tpn.exchange(t, x.id, y.id)
    assert order |> names() |> Enum.take(-2) == ~w(Yves Xavier)
  end

  test "round 1 uses the exchanged numbers and places a later entry by rating",
       %{t: t, p: p} do
    {:ok, _} = Tpn.exchange(t, p["Bob"].id, p["Carol"].id)
    {:ok, eve} = Tournaments.create_player(t.id, %{name: "Eve", fide_rating: 1950})

    assert names(Tpn.order(t)) == ~w(Alice Eve Carol Bob Dave)

    assert {:ok, _round} = Pairing.pair_next_round(t)

    assert Enum.map([p["Alice"], eve, p["Carol"], p["Bob"], p["Dave"]], &number/1) ==
             [1, 2, 3, 4, 5]
  end

  test "the public starting list before round 1 shows the numbers round 1 will use",
       %{t: t, p: p} do
    {:ok, _} = Tpn.exchange(t, p["Bob"].id, p["Carol"].id)
    {:ok, _} = Tournaments.create_player(t.id, %{name: "Eve", fide_rating: 1950})

    t =
      t
      |> Ecto.Changeset.change(standings_through: 0, public_slug: "tpn-#{t.id}")
      |> Repo.update!()

    snapshot = PairingsEngine.Snapshot.build(t)

    assert Enum.map(snapshot["players"], &{&1["no"], &1["name"]}) ==
             [{1, "Alice"}, {2, "Eve"}, {3, "Carol"}, {4, "Bob"}, {5, "Dave"}]
  end

  test "regeneration follows a rating change and keeps the order of equal ratings",
       %{t: t, p: p} do
    {:ok, _} = Tpn.exchange(t, p["Bob"].id, p["Carol"].id)
    assert {:ok, _round} = Pairing.pair_next_round(t)

    {:ok, _} = Tournaments.update_player(Repo.reload!(p["Dave"]), %{fide_rating: 2100})

    changes = Tpn.regeneration_changes(t)

    assert Enum.map(changes, fn {pl, old, new} -> {pl.name, old, new} end) ==
             [{"Dave", 4, 1}, {"Alice", 1, 2}, {"Carol", 2, 3}, {"Bob", 3, 4}]

    assert {:ok, order} = Tpn.regenerate(t)
    assert names(order) == ~w(Dave Alice Carol Bob)
    assert Tpn.regeneration_changes(t) == []
  end

  # C.04.2 2.3 allows the regeneration until round 4; C.04.2 2.4 gives a late
  # entry its TPN "only when they actually arrive", and C.04.7 1.3.1 sends a
  # Baku event's late entries through that Article. So a Baku player who has
  # not arrived yet is left out of a regeneration and numbered on arrival.
  test "in a Baku event a regeneration skips a player who has not arrived yet",
       %{t: t, p: p} do
    t = t |> Ecto.Changeset.change(acceleration: "baku") |> Repo.update!()
    {:ok, eve} = Tournaments.create_player(t.id, %{name: "Eve", fide_rating: 2500})
    {:ok, _} = Tournaments.update_player(eve, %{"absent_rounds" => "1,2"})
    {:ok, frank} = Tournaments.create_player(t.id, %{name: "Frank", fide_rating: 1000})
    {:ok, _} = Tournaments.update_player(frank, %{"absent_rounds" => "1"})

    assert {:ok, _round} = Pairing.pair_next_round(t)
    assert number(eve) == nil and number(frank) == nil

    # Round 2 is next: Frank arrives, Eve does not.
    {:ok, _} = Tournaments.update_player(Repo.reload!(p["Dave"]), %{fide_rating: 2100})
    refute Enum.any?(Tpn.regeneration_changes(t), fn {pl, _old, _new} -> pl.id == eve.id end)
    assert {:ok, order} = Tpn.regenerate(t)

    assert names(order) == ~w(Dave Alice Bob Carol Frank)
    assert number(eve) == nil
    assert number(frank) == 5
    assert Repo.reload!(t).baku_group_a_last == 2
  end

  test "a regeneration with nothing to change changes nothing", %{t: t} do
    assert {:ok, _round} = Pairing.pair_next_round(t)
    assert Tpn.regeneration_changes(t) == []
  end

  test "nothing changes once round 4 is paired", %{t: t, p: p} do
    for n <- 1..3, do: Repo.insert!(%Round{tournament_id: t.id, number: n, status: "done"})
    assert Tpn.editable?(t)

    Repo.insert!(%Round{tournament_id: t.id, number: 4, status: "playing"})
    refute Tpn.editable?(t)
    assert {:error, :locked} = Tpn.exchange(t, p["Bob"].id, p["Carol"].id)
    assert {:error, :locked} = Tpn.regenerate(t)
  end

  test "only an individual Swiss" do
    rr = Repo.insert!(%Tournament{name: "RR", type: "swiss", pairing_system: "round_robin"})
    refute Tpn.applies?(rr)
    assert {:error, :not_swiss} = Tpn.regenerate(rr)
  end

  defp names(order), do: Enum.map(order, fn {player, _n} -> player.name end)
  defp number(player), do: Repo.get!(Player, player.id).pairing_number
end
