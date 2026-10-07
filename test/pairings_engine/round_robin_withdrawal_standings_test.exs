defmodule PairingsEngine.RoundRobinWithdrawalStandingsTest do
  # FIDE C.05 6.6(2): a round-robin player who withdraws having completed
  # less than 50% of their games keeps their results in the tournament table
  # (rating, history) but they are not counted in the final standings; at 50%
  # or more they are counted. VCL4THP Q103.
  use PairingsEngine.DataCase, async: false

  import Ecto.Query

  alias PairingsEngine.{Repo, RoundRobin, Standings, Tournaments, TrfExport}
  alias PairingsEngine.Tournaments.{Round, Tournament}

  describe "single round robin, six players (five games each)" do
    test "withdrawn after 2 of 5 games: their games count for nobody, they are listed last" do
      {t, f} = event(6, 1, played_by_f: 2)

      entries = Standings.standings(t)
      last = List.last(entries)

      assert last.player.id == f.id
      assert last.c05_uncounted
      assert Enum.all?(Map.values(last.tiebreaks), &(&1 == 0.0))

      kept = Enum.reject(entries, &(&1.player.id == f.id))
      refute Enum.any?(kept, &Map.get(&1, :c05_uncounted))

      # Ten decisive games among the other five; the five against F are gone.
      assert kept |> Enum.map(& &1.points) |> Enum.sum() == 10.0

      # The results stay in the table: everybody still has their game with F.
      assert length(last.games) == 5
      assert Enum.all?(kept, fn e -> Enum.any?(e.games, &(&1.opponent_id == f.id)) end)
    end

    test "the TRF keeps every game and every point for rating" do
      {t, f} = event(6, 1, played_by_f: 2)

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      parsed = Ainalrami.Trf.parse(text)

      assert parsed.players |> Enum.map(& &1.points) |> Enum.sum() == 15.0

      f_row = Enum.find(parsed.players, &(&1.rank == f.pairing_number))
      assert length(f_row.games) == 5
    end

    test "withdrawn after 3 of 5 games: counted as usual" do
      {t, f} = event(6, 1, played_by_f: 3)

      entries = Standings.standings(t)
      refute Enum.any?(entries, &Map.get(&1, :c05_uncounted))
      assert entries |> Enum.map(& &1.points) |> Enum.sum() == 15.0
      assert Enum.find(entries, &(&1.player.id == f.id)).points == 0.0
    end

    test "a player who lost games by forfeit but did not withdraw is counted" do
      {t, f} = event(6, 1, played_by_f: 1, withdraw?: false)

      entries = Standings.standings(t)
      refute Enum.any?(entries, &Map.get(&1, :c05_uncounted))
      assert entries |> Enum.map(& &1.points) |> Enum.sum() == 15.0
      assert Enum.any?(entries, &(&1.player.id == f.id))
    end

    test "the grid the cross table prints from agrees" do
      {t, f} = event(6, 1, played_by_f: 2)

      entries = Standings.grid_standings(t)
      assert List.last(entries).player.id == f.id
      assert List.last(entries).c05_uncounted

      assert entries
             |> Enum.reject(&(&1.player.id == f.id))
             |> Enum.map(& &1.points)
             |> Enum.sum() == 10.0
    end
  end

  describe "double round robin, four players (six games each)" do
    test "exactly half completed (3 of 6) is counted" do
      {t, _f} = event(4, 2, played_by_f: 3)

      refute Enum.any?(Standings.standings(t), &Map.get(&1, :c05_uncounted))
    end

    test "under half (2 of 6) is not counted" do
      {t, f} = event(4, 2, played_by_f: 2)

      assert Standings.uncounted_withdrawals(t, Tournaments.list_players(t.id)) ==
               MapSet.new([f.id])

      entries = Standings.standings(t)
      # The other three play six games among themselves.
      assert entries
             |> Enum.reject(&(&1.player.id == f.id))
             |> Enum.map(& &1.points)
             |> Enum.sum() == 6.0
    end
  end

  test "a Swiss tournament is never touched" do
    t = Repo.insert!(%Tournament{name: "Swiss", type: "swiss", rounds_count: 5})
    {:ok, p} = Tournaments.create_player(t.id, %{name: "A", fide_rating: 2000})
    {:ok, _} = Tournaments.update_player(p, %{status: "withdrawn", pairing_number: 1})

    assert Standings.uncounted_withdrawals(t, Tournaments.list_players(t.id)) == MapSet.new()
  end

  # A round robin of `n` players over `cycles` cycles, every round paired.
  # The player numbered last ("F", lowest rated) plays and loses their first
  # `played_by_f` games, then loses the rest by forfeit and (unless
  # `withdraw?: false`) is withdrawn. Every other game is won by White.
  defp event(n, cycles, opts) do
    rounds = RoundRobin.rounds_needed(n, %{rr_cycles: cycles, rr_match_format: false})

    t =
      Repo.insert!(%Tournament{
        name: "RR withdrawal",
        type: "swiss",
        pairing_system: "round_robin",
        rr_cycles: cycles,
        rounds_count: rounds,
        round_dates: for(r <- 1..rounds, do: Date.to_iso8601(Date.add(~D[2026-09-01], r)))
      })

    for i <- 1..n do
      name = if i == n, do: "F", else: "P#{i}"
      {:ok, _} = Tournaments.create_player(t.id, %{name: name, fide_rating: 2400 - i * 50})
    end

    {:ok, _} = RoundRobin.pair_all_rounds(t)

    f = t.id |> Tournaments.list_players() |> Enum.find(&(&1.name == "F"))
    played_by_f = Keyword.fetch!(opts, :played_by_f)

    from(r in Round, where: r.tournament_id == ^t.id, order_by: r.number, preload: :pairings)
    |> Repo.all()
    |> Enum.flat_map(& &1.pairings)
    |> Enum.reduce(0, fn pairing, f_games ->
      cond do
        pairing.white_player_id == f.id ->
          result = if f_games < played_by_f, do: "0-1", else: "0-1FF"
          {:ok, _} = Tournaments.update_pairing_result(pairing, result)
          f_games + 1

        pairing.black_player_id == f.id ->
          result = if f_games < played_by_f, do: "1-0", else: "1-0FF"
          {:ok, _} = Tournaments.update_pairing_result(pairing, result)
          f_games + 1

        true ->
          {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")
          f_games
      end
    end)

    f =
      if Keyword.get(opts, :withdraw?, true) do
        {:ok, f} = Tournaments.update_player(f, %{status: "withdrawn"})
        f
      else
        f
      end

    {Repo.reload!(t), f}
  end
end
