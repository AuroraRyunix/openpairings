defmodule PairingsEngine.BoardOrderC0402Test do
  @moduledoc """
  VCL4THP Q187: are an individual Swiss's boards in the order C.04.2:3.6
  recommends - the higher score of the pair's higher-ranked player, then the
  larger sum of both scores, then the lower starting rank of that player?

  Pairs several rounds of a field with changing scores and checks every
  round's board numbers against that order (the bye last).
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  defp play(t, rounds, players) do
    Enum.reduce(1..rounds, %{}, fn n, points ->
      {:ok, round} = Pairing.pair_next_round(t)
      pairings = Repo.preload(round, :pairings).pairings |> Enum.sort_by(& &1.board)
      tpn = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.pairing_number})

      keys =
        for p <- pairings, p.black_player_id != nil do
          sw = Map.get(points, p.white_player_id, 0.0)
          sb = Map.get(points, p.black_player_id, 0.0)
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

      assert keys == Enum.sort(keys),
             "round #{n}: boards are not in C.04.2:3.6 order: #{inspect(keys)}"

      byes = Enum.filter(pairings, &is_nil(&1.black_player_id))
      assert Enum.all?(byes, &(&1.board == length(pairings))), "round #{n}: the bye is not last"

      # Deterministic, varied results: the lower pairing number wins unless
      # the sum of the numbers is divisible by 3 (a draw) or by 5 (upset).
      Enum.reduce(pairings, points, fn p, acc ->
        if p.black_player_id do
          tw = tpn[p.white_player_id]
          tb = tpn[p.black_player_id]
          sum = tw + tb

          {result, sw, sb} =
            cond do
              rem(sum, 3) == 0 -> {"1/2-1/2", 0.5, 0.5}
              rem(sum, 5) == 0 -> if tw < tb, do: {"0-1", 0.0, 1.0}, else: {"1-0", 1.0, 0.0}
              tw < tb -> {"1-0", 1.0, 0.0}
              true -> {"0-1", 0.0, 1.0}
            end

          {:ok, _} = Tournaments.update_pairing_result(p, result)

          acc
          |> Map.update(p.white_player_id, sw, &(&1 + sw))
          |> Map.update(p.black_player_id, sb, &(&1 + sb))
        else
          Map.update(acc, p.white_player_id, 1.0, &(&1 + 1.0))
        end
      end)
    end)

    assert length(players) > 0
  end

  for count <- [14, 15, 22] do
    test "#{count} players, Ainalrami: boards follow 3.6" do
      t =
        Repo.insert!(%Tournament{
          name: "Board order",
          type: "swiss",
          rounds_count: 6
        })

      players =
        for n <- 1..unquote(count) do
          {:ok, p} =
            Tournaments.create_player(t.id, %{
              "name" => "P#{n}",
              "fide_rating" => 2600 - n * 17
            })

          %Player{} = p
        end

      play(t, 5, players)
    end
  end
end
