defmodule PairingsEngine.BoardOrderBakuTest do
  @moduledoc """
  VCL4THP Q188: with an acceleration method that assigns fictitious points
  (Baku, C.04.7), are the boards ordered by the sum of real and fictitious
  points? Pairs the accelerated rounds of a 16-player, 6-round event
  (Group A = pairing numbers 1-8, virtual points 1.0, 1.0, 0.5 in rounds 1-3)
  and checks every board against C.04.2:3.6 with each player's pairing
  score, virtual points included.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  @virtual %{1 => 1.0, 2 => 1.0, 3 => 0.5}
  @group_a_last 8

  defp keys(pairings, score, tpn) do
    for p <- pairings, p.black_player_id != nil do
      sw = score.(p.white_player_id)
      sb = score.(p.black_player_id)
      tw = tpn[p.white_player_id]
      tb = tpn[p.black_player_id]

      {first_score, first_tpn} =
        cond do
          sw > sb -> {sw, tw}
          sb > sw -> {sb, tb}
          true -> {sw, min(tw, tb)}
        end

      {-first_score, -(sw + sb), first_tpn}
    end
  end

  test "boards are ordered by real plus virtual points" do
    t =
      Repo.insert!(%Tournament{
        name: "Baku boards",
        type: "swiss",
        rounds_count: 6,
        acceleration: "baku",
        initial_colour: "white"
      })

    for n <- 1..16 do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "P#{n}",
          "fide_rating" => 2600 - n * 17
        })
    end

    {_points, differing} =
      Enum.reduce(1..3, {%{}, 0}, fn n, {points, differing} ->
        {:ok, round} = Pairing.pair_next_round(t)
        pairings = Repo.preload(round, :pairings).pairings |> Enum.sort_by(& &1.board)
        # Pairing numbers are fixed when round 1 is paired.
        tpn = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.pairing_number})

        real = fn id -> Map.get(points, id, 0.0) end
        virtual = fn id -> if tpn[id] <= @group_a_last, do: Map.fetch!(@virtual, n), else: 0.0 end
        both = fn id -> real.(id) + virtual.(id) end

        with_virtual = keys(pairings, both, tpn)
        real_only = keys(pairings, real, tpn)

        assert with_virtual == Enum.sort(with_virtual),
               "round #{n}: boards are not in 3.6 order with virtual points: #{inspect(with_virtual)}"

        # Deterministic, varied results: the lower number wins unless the sum
        # of the numbers is divisible by 3 (a draw) or by 5 (an upset).
        points =
          Enum.reduce(pairings, points, fn p, acc ->
            if p.black_player_id do
              tw = tpn[p.white_player_id]
              tb = tpn[p.black_player_id]

              {result, sw, sb} =
                cond do
                  rem(tw + tb, 3) == 0 ->
                    {"1/2-1/2", 0.5, 0.5}

                  rem(tw + tb, 5) == 0 ->
                    if tw < tb, do: {"0-1", 0.0, 1.0}, else: {"1-0", 1.0, 0.0}

                  tw < tb ->
                    {"1-0", 1.0, 0.0}

                  true ->
                    {"0-1", 0.0, 1.0}
                end

              {:ok, _} = Tournaments.update_pairing_result(p, result)

              acc
              |> Map.update(p.white_player_id, sw, &(&1 + sw))
              |> Map.update(p.black_player_id, sb, &(&1 + sb))
            else
              Map.update(acc, p.white_player_id, 1.0, &(&1 + 1.0))
            end
          end)

        {points, differing + if(real_only == Enum.sort(real_only), do: 0, else: 1)}
      end)

    # The check is not vacuous: in at least one round the real points alone
    # would have put the boards in a different order.
    assert differing > 0
  end
end
