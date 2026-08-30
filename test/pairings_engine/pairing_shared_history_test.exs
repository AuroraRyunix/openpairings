defmodule PairingsEngine.PairingSharedHistoryTest do
  @moduledoc """
  Sweep item 6: a pairing run redoing work it already has.

  These assert the COST, not the output - the pairing itself is covered
  extensively in `pairing_test.exs`, and none of it may change. What changed
  is how many times one run asks the database for the same rows, so that is
  what is measured here: with the query counter, and by category count,
  where the redundancy multiplied.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{ForbiddenPairing, Player, Tournament}

  @tag :javafo
  test "a category run's query count does not scale with the number of categories" do
    two = query_count_for_categories(2)
    four = query_count_for_categories(4)

    # Every category still runs its own engine call and inserts its own
    # boards, so this is not "identical" - it is "the tournament-wide reads
    # are not repeated". Doubling the categories used to double the roster
    # history reads (3 each) and the forbidden-pairing reads (2 each) on top
    # of the per-category work.
    # Measured: 53 / 87 / 121 queries for 2 / 4 / 6 categories - a flat 17
    # per extra category, all of it that category's own engine call and
    # board inserts. Each category used to add two forbidden-pairing reads
    # on top of that, for a list identical across all of them.
    assert four - two < two,
           "4 categories cost #{four} queries, 2 cost #{two} - the difference " <>
             "should be per-category work only"
  end

  @tag :javafo
  test "the single-pool path builds its shared history once" do
    tournament = swiss_tournament()

    for {name, rating} <- [{"P1", 2000}, {"P2", 1900}, {"P3", 1800}, {"P4", 1700}] do
      insert_player(tournament, name, rating, nil)
    end

    # Round 1 has no history to read. Pair it, enter results, then measure
    # round 2, which is the round that actually walks the rounds table.
    assert {:ok, round} = Pairing.pair_next_round(tournament)
    finish_round(round)

    count = count_queries(fn -> Pairing.pair_next_round(tournament) end)

    # Measured on this exact fixture: 43 queries before, 35 after. This
    # path used to fall through to `build_shared_history/1` from BOTH
    # `order_for_pairing/3` and `trf_player_rows/3`, so its three history
    # queries appeared twice, plus a `full_roster_players/1` read of rows
    # the history already had, plus two extra `active_players/1` reads.
    #
    # The bound is deliberately loose - this is a regression guard against
    # the duplication coming back, not a pin on an exact count.
    assert count > 0
    assert count < 40, "#{count} queries to pair one Swiss round (was 43, now 35)"
  end

  @tag :javafo
  test "forbidden pairings are still honoured after being read once per run" do
    tournament = swiss_tournament()

    [a, b, c, d] =
      for {name, rating} <- [{"P1", 2000}, {"P2", 1900}, {"P3", 1800}, {"P4", 1700}] do
        insert_player(tournament, name, rating, nil)
      end

    # The two top seeds would otherwise be paired together in round 1.
    Repo.insert!(%ForbiddenPairing{
      tournament_id: tournament.id,
      player_a_id: a.id,
      player_b_id: b.id
    })

    assert {:ok, round} = Pairing.pair_next_round(tournament)
    round = Repo.preload(round, :pairings)

    pairs = Enum.map(round.pairings, &MapSet.new([&1.white_player_id, &1.black_player_id]))

    assert length(pairs) == 2
    refute MapSet.new([a.id, b.id]) in pairs
    # All four are paired, so the forbidden pair was routed around rather
    # than dropped.
    assert pairs |> Enum.reduce(&MapSet.union/2) ==
             MapSet.new([a.id, b.id, c.id, d.id])
  end

  ## ---------- helpers ----------

  defp query_count_for_categories(n) do
    categories = for i <- 1..n, do: "C#{i}"

    tournament =
      Repo.insert!(%Tournament{
        name: "Cat#{n}",
        type: "swiss",
        rounds_count: 3,
        categories: categories,
        categories_enabled: true,
        pair_by_category: true
      })

    for {category, ci} <- Enum.with_index(categories),
        pi <- 1..4 do
      insert_player(tournament, "#{category}P#{pi}", 2000 - ci * 100 - pi, category)
    end

    count_queries(fn -> {:ok, _round} = Pairing.pair_next_round(tournament) end)
  end

  defp swiss_tournament do
    Repo.insert!(%Tournament{name: "Single", type: "swiss", rounds_count: 3})
  end

  defp insert_player(tournament, name, rating, category) do
    Repo.insert!(%Player{
      tournament_id: tournament.id,
      name: name,
      fide_rating: rating,
      category: category
    })
  end

  defp finish_round(round) do
    round = Repo.preload(round, :pairings)

    Enum.each(round.pairings, fn p ->
      if p.black_player_id, do: {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end)
  end

  defp count_queries(fun) do
    ref = make_ref()
    parent = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:pairings_engine, :repo, :query],
      fn _e, _m, _meta, _c -> send(parent, {ref, :q}) end,
      nil
    )

    try do
      fun.()
      drain(ref, 0)
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(ref, n) do
    receive do
      {^ref, :q} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end
end
