defmodule PairingsEngine.ExpelledPlayerTest do
  @moduledoc """
  VCL4THP Q197 and Q198: an expelled player is flagged, not paired further,
  and left out of the standings - the player only, not the results: games
  against them stay in their opponents' scores and tie-breaks.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  test "expelled is a status of its own, beside active and withdrawn" do
    t = Repo.insert!(%Tournament{name: "Expel", type: "swiss", rounds_count: 3})
    {:ok, p} = Tournaments.create_player(t.id, %{"name" => "Zed"})

    assert {:ok, p} = Tournaments.update_player(p, %{"status" => "expelled"})
    assert Player.expelled?(p)
    refute Player.withdrawn?(p)
    assert {:error, _} = Tournaments.update_player(p, %{"status" => "banished"})
  end

  test "withdrawn covers the withdrawn status and the Forfeit tick" do
    assert Player.withdrawn?(%Player{status: "withdrawn"})
    assert Player.withdrawn?(%Player{forfeit: true})
    refute Player.withdrawn?(%Player{})
    refute Player.withdrawn?(%Player{status: "expelled"})
  end

  test "the expelled player leaves the standings, their opponent keeps the points" do
    t = Repo.insert!(%Tournament{name: "Expel", type: "swiss", rounds_count: 5})

    for n <- 1..4 do
      {:ok, _} =
        Tournaments.create_player(t.id, %{"name" => "P#{n}", "fide_rating" => 2400 - n * 100})
    end

    {:ok, round1} = Pairing.pair_next_round(t)
    pairings = Repo.preload(round1, :pairings).pairings

    for pairing <- pairings do
      {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")
    end

    assert length(Standings.standings(t)) == 4

    first = hd(pairings)
    expelled = Repo.get!(Player, first.black_player_id)
    winner = Repo.get!(Player, first.white_player_id)

    {:ok, _} = Tournaments.update_player(expelled, %{"status" => "expelled"})

    standings = Standings.standings(t)
    assert expelled.id not in Enum.map(standings, & &1.player.id)
    assert length(standings) == 3
    assert Enum.map(standings, & &1.rank) == [1, 2, 3]
    # The win over the expelled player still counts.
    assert Enum.find(standings, &(&1.player.id == winner.id)).points == 1.0

    # And they are not paired in the next round.
    {:ok, round2} = Pairing.pair_next_round(t)

    ids =
      for p <- Repo.preload(round2, :pairings).pairings,
          id <- [p.white_player_id, p.black_player_id],
          do: id

    refute expelled.id in ids
  end
end
