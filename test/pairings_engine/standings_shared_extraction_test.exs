defmodule PairingsEngine.StandingsSharedExtractionTest do
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{PairingRationale, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  describe "standings_by_round/2" do
    test "each horizon matches standings/2 called on its own" do
      t = seeded()

      by_round = Standings.standings_by_round(t, [1, 2, 3])

      for n <- [1, 2, 3] do
        assert by_round[n] == Standings.standings(t, through_round: n),
               "horizon #{n} differs from a standalone call"
      end
    end

    test "horizons may be unsorted, repeated, or a single one" do
      t = seeded()

      assert Map.keys(Standings.standings_by_round(t, [3, 1, 3])) |> Enum.sort() == [1, 3]
      assert Map.keys(Standings.standings_by_round(t, [2])) == [2]
    end

    test "reads the rounds and byes once, not once per horizon" do
      t = seeded()

      one = count_queries(fn -> Standings.standings(t, through_round: 3) end)
      three = count_queries(fn -> Standings.standings_by_round(t, [1, 2, 3]) end)

      # Three horizons must not cost three times one. The players read is
      # shared too, so the only honest claim is "no more than a single call".
      # Guard against a vacuous pass: if telemetry never fired, both are 0
      # and the comparison below would prove nothing.
      assert one > 0, "the query counter is not counting anything"
      assert three <= one, "#{three} queries for three horizons vs #{one} for one"
    end
  end

  describe "points_by_player/2" do
    test "agrees with the points standings/2 computes, without the rest" do
      t = seeded()

      for n <- [0, 1, 2, 3] do
        full =
          t
          |> Standings.standings(through_round: n)
          |> Map.new(&{&1.player.id, &1.points})

        assert Standings.points_by_player(t, through_round: n) == full
      end
    end

    test "player_scores_before_round/2 still answers the same map" do
      t = seeded()
      expected = Standings.points_by_player(t, through_round: 2)

      assert Standings.player_scores_before_round(t, 3) == expected
    end
  end

  describe "player_trails/2 over the shared extraction" do
    test "is unchanged by where the standings came from" do
      t = seeded()
      trails = PairingRationale.player_trails(t, 3)

      assert map_size(trails) == 4

      for {_id, %{rounds: rounds, summary: summary}} <- trails do
        assert length(rounds) == 3
        assert is_map(summary)
      end
    end
  end

  # Four players, three finished rounds, one bye row - enough for the
  # prefixes to differ from each other and from the full extraction.
  defp seeded do
    t =
      Repo.insert!(%Tournament{
        name: "Prefix",
        type: "swiss",
        rounds_count: 3,
        points_win: 1.0,
        points_draw: 0.5,
        points_loss: 0.0,
        tiebreaks: ~w(BHC1 BH SB WIN PS)
      })

    [a, b, c, d] =
      for {name, nr, rating} <- [
            {"Alice", 1, 2000},
            {"Bob", 2, 1900},
            {"Carol", 3, 1800},
            {"Dave", 4, 1700}
          ] do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: name,
          pairing_number: nr,
          fide_rating: rating
        })
      end

    schedule = [
      {1, [{a, d, "1-0"}, {b, c, "1/2-1/2"}]},
      {2, [{a, c, "1/2-1/2"}, {d, b, "0-1"}]},
      {3, [{a, b, "1-0"}, {c, d, "1-0FF"}]}
    ]

    for {number, boards} <- schedule do
      round = Repo.insert!(%Round{tournament_id: t.id, number: number, status: "finished"})

      boards
      |> Enum.with_index(1)
      |> Enum.each(fn {{white, black, result}, board} ->
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: board,
          white_player_id: white.id,
          black_player_id: black.id,
          result: result
        })
      end)
    end

    Tournaments.get_tournament(t.id)
  end

  # Counts queries by attaching to Ecto's own telemetry for this repo.
  defp count_queries(fun) do
    ref = make_ref()
    parent = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:pairings_engine, :repo, :query],
      fn _event, _measure, _meta, _cfg -> send(parent, {ref, :query}) end,
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
      {^ref, :query} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end
end
