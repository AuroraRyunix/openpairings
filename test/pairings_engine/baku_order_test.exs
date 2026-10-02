defmodule PairingsEngine.BakuOrderTest do
  @moduledoc """
  The smallest tournament that showed Baku's virtual points left out of the
  order the engine's rows are numbered in (`Pairing.order_for_pairing/4`).

  Eight players, four rounds, so Group A is pairing numbers 1-4 (C.04.7:
  `2 * ceil(8 / 4)`), the accelerated rounds are 1-2, and Group A carries
  1.0 virtual point in round 1 and 0.5 in round 2. Round 1 pairs 1-3 and
  2-4 in Group A, 5-7 and 6-8 in Group B. With 1-3 drawn, 2 beating 4 and
  5 and 6 winning, round 2's pairing scores are

      2: 1.5    1, 3, 5, 6: 1.0    4: 0.5    7, 8: 0

  and the 1.0 bracket is, by C.04.3 A.2, ordered 1, 3, 5, 6. Ordered by
  game points (1 and 3 hold 0.5, 5 and 6 hold 1.0) the rows went 5, 6, 1, 3,
  and the engine - which takes a row's position as its starting rank -
  paired that bracket as if 5 and 6 were the higher-ranked players.
  """

  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament
  alias Ainalrami.Trf

  setup do
    handler = "baku-order-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:pairings_engine, :pairing, :trf_built],
      fn _event, _measurements, meta, _config ->
        Process.put({:trf, meta.round}, meta.trf)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    tournament =
      Repo.insert!(%Tournament{
        name: "Baku order",
        type: "swiss",
        rounds_count: 4,
        acceleration: "baku",
        initial_colour: "white"
      })

    for n <- 1..8 do
      {:ok, _} =
        Tournaments.create_player(tournament.id, %{
          "name" => "P#{n}, Baku",
          "fide_rating" => 2400 - n * 100
        })
    end

    {:ok, round1} = Pairing.pair_next_round(tournament)
    pn = pairing_numbers(tournament)

    results = %{
      [1, 3] => "1/2-1/2",
      [2, 4] => :higher_wins,
      [5, 7] => :higher_wins,
      [6, 8] => :higher_wins
    }

    for pairing <- Repo.preload(round1, :pairings).pairings do
      white = pn[pairing.white_player_id]
      black = pn[pairing.black_player_id]

      result =
        case Map.fetch!(results, Enum.sort([white, black])) do
          :higher_wins when white < black -> "1-0"
          :higher_wins -> "0-1"
          draw -> draw
        end

      {:ok, _} = Tournaments.update_pairing_result(pairing, result)
    end

    %{tournament: tournament, pn: pn}
  end

  test "an accelerated round numbers the engine's rows by game points plus virtual points",
       %{tournament: tournament, pn: pn} do
    {:ok, _round2} = Pairing.pair_next_round(tournament)

    by_name = Map.new(Tournaments.list_players(tournament.id), &{&1.name, pn[&1.id]})

    order =
      Process.get({:trf, 2})
      |> Trf.parse()
      |> Map.fetch!(:players)
      |> Enum.sort_by(& &1.rank)
      |> Enum.map(&by_name[&1.name])

    assert order == [2, 1, 3, 5, 6, 4, 7, 8]
  end

  # The round bbpPairings (`--dutch`) and Ainalrami both pair from a file
  # numbered by pairing number with the same `XXA` lines (checked by hand
  # 2026-10-02; `PairingsEngine.BakuReferenceTest` does the same for random
  # tournaments). The game-point order paired 2-5, 3-4, 6-1, 7-8 instead.
  test "round 2 is the round C.04.3 with C.04.7 pairs", %{tournament: tournament, pn: pn} do
    {:ok, round2} = Pairing.pair_next_round(tournament)

    pairs =
      for p <- Repo.preload(round2, :pairings).pairings,
          do: {pn[p.white_player_id], pn[p.black_player_id]}

    assert Enum.sort(pairs) == expected_round_two()
  end

  defp expected_round_two, do: [{2, 1}, {3, 5}, {6, 4}, {7, 8}]

  defp pairing_numbers(tournament) do
    Map.new(Tournaments.list_players(tournament.id), &{&1.id, &1.pairing_number})
  end
end
