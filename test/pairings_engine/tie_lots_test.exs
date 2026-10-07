defmodule PairingsEngine.TieLotsTest do
  @moduledoc """
  VCL4THP Q204-Q206: a simulated drawing of lots for players level after
  every tie-break, recorded as the manual ranking, which gives the same
  order when repeated.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Pairing, Repo, Standings, TieLots, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  @results ~w(1-0 0-1 1/2-1/2 1-0 0-1)

  # No tie-breaks at all, so everybody on the same score is level.
  defp played(players \\ 8, rounds \\ 3) do
    t =
      Repo.insert!(%Tournament{
        name: "Lots",
        type: "swiss",
        rounds_count: rounds,
        tiebreaks: [],
        round_dates: for(r <- 1..rounds, do: "2026-09-0#{r}")
      })

    for i <- 1..players do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          tournament_id: t.id,
          name: "Player #{i}",
          fide_rating: 2400 - 37 * i
        })
    end

    for _ <- 1..rounds do
      {:ok, round} = Pairing.pair_next_round(Repo.reload!(t), [])
      round = Tournaments.get_round(t.id, round.number)

      for {p, i} <- Enum.with_index(round.pairings), p.black_player_id do
        {:ok, _} =
          Tournaments.update_pairing_result(p, Enum.at(@results, rem(i + round.number, 5)))
      end
    end

    Repo.reload!(t)
  end

  defp manual_order(t) do
    t.id
    |> Tournaments.list_players()
    |> Enum.sort_by(& &1.manual_rank)
    |> Enum.map(& &1.id)
  end

  test "the groups are the players sharing a place after the whole list" do
    t = played()
    groups = TieLots.tied_groups(Standings.standings(t))
    assert groups != []

    for group <- groups do
      assert length(group) > 1
      assert group |> Enum.map(&Standings.place/1) |> Enum.uniq() |> length() == 1
    end
  end

  test "drawing records a full manual order and keeps untied players where they were" do
    t = played()
    before = Standings.standings(t)
    assert {:ok, %{players: n, groups: g, tournament: t2}} = TieLots.draw(t)
    assert n >= 2 and g >= 1
    assert t2.manual_ranking and is_integer(t2.lots_seed)

    order = manual_order(t2)
    assert Enum.sort(order) == Enum.sort(Enum.map(before, & &1.player.id))

    # Every player stays inside the block of their own place.
    by_id = Map.new(before, &{&1.player.id, Standings.place(&1)})
    places = Enum.map(order, &by_id[&1])
    assert places == Enum.sort(places)
  end

  test "drawing again gives the same order, even after the order was cleared" do
    t = played()
    {:ok, %{tournament: t1}} = TieLots.draw(t)
    first = manual_order(t1)

    {:ok, %{tournament: t2}} = TieLots.draw(t1)
    assert manual_order(t2) == first

    {:ok, t3} = Tournaments.disable_manual_ranking(t2)
    {:ok, t3} = Tournaments.enable_manual_ranking(t3)

    {:ok, %{tournament: t4}} = TieLots.draw(t3)
    assert manual_order(t4) == first
  end

  test "another seed is another draw" do
    t = played(12, 3)

    orders =
      for seed <- [11, 222, 3333, 44_444, 555_555] do
        Repo.update_all(Ecto.Query.from(x in Tournament, where: x.id == ^t.id),
          set: [lots_seed: seed]
        )

        {:ok, %{tournament: t2}} = TieLots.draw(Repo.reload!(t))
        manual_order(t2)
      end

    assert length(Enum.uniq(orders)) > 1
  end

  test "nobody level, nothing to draw" do
    t = played(2, 1)
    # The one game is decisive (round 1, board 1: the first result above).
    assert {:error, :no_ties} = TieLots.draw(Repo.reload!(t))
  end

  test "not for a Keizer tournament" do
    t =
      Repo.insert!(%Tournament{
        name: "K",
        type: "swiss",
        pairing_system: "keizer",
        rounds_count: 3
      })

    assert {:error, :not_supported} = TieLots.draw(t)
  end
end
