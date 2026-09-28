defmodule PairingsEngine.StandingsCacheTest do
  @moduledoc """
  `PairingsEngine.StandingsCache` may only ever return what a fresh replay
  of the games would return right now. Checked two ways: random sequences
  of writes through every kind of write path, comparing the cached answer
  with a fresh one after each, and one test per write path that the data
  version moved and the next answer is the fresh one.
  """
  use PairingsEngine.DataCase, async: false
  use ExUnitProperties

  alias PairingsEngine.{
    Keizer,
    Pairing,
    Repo,
    ResultsImport,
    Snapshots,
    Standings,
    StandingsCache,
    Tournaments
  }

  alias PairingsEngine.Tournaments.{Round, Tournament}

  @moduletag :capture_log

  defp tournament(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Tournament{
          name: "Cached",
          type: "swiss",
          rounds_count: 6,
          tiebreaks: ~w(BH SB),
          pairing_engine: "ainalrami",
          initial_colour: "white",
          round_dates: List.duplicate("2026-09-01", 6)
        },
        attrs
      )
    )
  end

  defp roster(t, count) do
    for n <- 1..count do
      {:ok, p} =
        Tournaments.create_player(t.id, %{"name" => "P#{n}", "fide_rating" => 2100 - n * 37})

      p
    end
  end

  defp pairings(t, number) do
    case Tournaments.get_round(t.id, number) do
      nil -> []
      round -> Enum.sort_by(round.pairings, & &1.board)
    end
  end

  defp finish_round(t, number, result \\ "1-0") do
    for p <- pairings(t, number),
        p.black_player_id,
        do: {:ok, _} = Tournaments.update_pairing_result(p, result)
  end

  # Every cached entry point, answered cached and answered fresh.
  defp answers(t) do
    t = Repo.reload!(t)

    [
      standings: fn -> Standings.standings(t) end,
      after_round_1: fn -> Standings.standings(t, through_round: 1) end,
      grid: fn -> Standings.grid_standings(t) end,
      points: fn -> Standings.points_by_player(t) end,
      before_round_2: fn -> Standings.player_scores_before_round(t, 2) end,
      by_round: fn -> Standings.standings_by_round(t, [0, 1, 2]) end
    ]
  end

  defp assert_fresh(t) do
    for {name, answer} <- answers(t) do
      cached = answer.()
      # Asked twice: the second is the one served from the cache.
      assert answer.() == cached, "#{name}: a second read differs from the first"
      assert cached == StandingsCache.bypass(answer), "#{name}: cached differs from fresh"
    end

    :ok
  end

  describe "the cache" do
    test "serves a second read from the cache, keyed by the current version" do
      t = tournament()
      roster(t, 6)
      {:ok, _} = Pairing.pair_next_round(t)

      first = Standings.standings(t)
      version = StandingsCache.version(t.id)
      assert Enum.any?(StandingsCache.entries(t.id), &(elem(&1, 0) == version))
      assert Standings.standings(t) == first
    end

    test "a struct changed in memory is its own entry, not the stored one" do
      t = tournament()
      roster(t, 6)
      {:ok, _} = Pairing.pair_next_round(t)
      finish_round(t, 1)

      standard = Standings.standings(t)
      three_one = Standings.standings(%{t | points_win: 3.0, points_draw: 1.0})

      refute standard == three_one
      assert Enum.all?(three_one, &(&1.points in [0.0, 3.0]))
      assert Standings.standings(t) == standard
    end

    test "only the current version's entries are kept" do
      t = tournament()
      roster(t, 6)
      {:ok, _} = Pairing.pair_next_round(t)
      Standings.standings(t)
      old = StandingsCache.version(t.id)

      finish_round(t, 1)
      Standings.standings(Repo.reload!(t))
      _ = :sys.get_state(StandingsCache)

      versions = t.id |> StandingsCache.entries() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      assert versions == [StandingsCache.version(t.id)]
      refute old in versions
    end
  end

  # One entry per write path: the version moves, and the next answer is the
  # fresh one - and differs from the old one, so the test would notice a
  # stale hit.
  describe "every write path invalidates" do
    setup do
      t = tournament()
      players = roster(t, 7)
      {:ok, _} = Pairing.pair_next_round(t)
      finish_round(t, 1)
      {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))
      %{t: Repo.reload!(t), players: players}
    end

    defp changes(t, write) do
      t = Repo.reload!(t)
      before = Standings.standings(t)
      grid = Standings.grid_standings(t)
      version = StandingsCache.version(t.id)
      t2 = write.(t) || Repo.reload!(t)

      assert_fresh(t2)
      {before, grid, version, Standings.standings(t2)}
    end

    test "a result", %{t: t} do
      {before, _, version, now} =
        changes(t, fn t ->
          [p | _] = pairings(t, 2) |> Enum.filter(& &1.black_player_id)
          {:ok, _} = Tournaments.update_pairing_result(p, "0-1")
          nil
        end)

      refute StandingsCache.version(t.id) == version
      refute now == before
    end

    test "a result changed back and forth never serves the middle one", %{t: t} do
      [p | _] = pairings(t, 2) |> Enum.filter(& &1.black_player_id)
      {:ok, p} = Tournaments.update_pairing_result(p, "1-0")
      one = Standings.standings(Repo.reload!(t))
      {:ok, p} = Tournaments.update_pairing_result(p, "0-1")
      two = Standings.standings(Repo.reload!(t))
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
      three = Standings.standings(Repo.reload!(t))

      refute one == two
      assert three == one
      assert_fresh(t)
    end

    test "a bye row, written by the pairing and by hand", %{t: t, players: [p1 | _]} do
      {before, _, version, now} =
        changes(t, fn t ->
          Repo.insert_all("byes", [
            %{tournament_id: t.id, player_id: p1.id, round: 3, type: "requested-half"}
          ])

          nil
        end)

      refute StandingsCache.version(t.id) == version
      # A bye for a round not paired yet still counts in the standings.
      refute now == before

      {_, _, version, _} =
        changes(t, fn t ->
          Repo.delete_all(from b in "byes", where: b.tournament_id == ^t.id and b.round == 3)
          nil
        end)

      refute StandingsCache.version(t.id) == version
    end

    test "a player added, edited, withdrawn and deleted", %{t: t, players: [p1, p2 | _]} do
      {before, _, _, now} =
        changes(t, fn t ->
          {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Late", "fide_rating" => 2400})
          nil
        end)

      refute length(now) == length(before)

      {before, _, _, now} =
        changes(t, fn _t ->
          {:ok, _} = Tournaments.update_player(p2, %{"fide_rating" => 2900, "name" => "Renamed"})
          nil
        end)

      refute now == before

      {_, _, version, _} =
        changes(t, fn _t ->
          {:ok, _} = Tournaments.update_player(Repo.reload!(p1), %{"status" => "withdrawn"})
          nil
        end)

      refute StandingsCache.version(t.id) == version

      {before, _, _, now} =
        changes(t, fn _t ->
          {:ok, _} = Tournaments.delete_player(Repo.reload!(p1))
          nil
        end)

      refute length(now) == length(before)
    end

    test "scoring and tie-break settings", %{t: t} do
      {before, grid_before, _, now} =
        changes(t, fn t ->
          {:ok, t} =
            Tournaments.update_tournament(t, %{
              "points_win" => "3",
              "points_draw" => "1",
              "tiebreaks" => ["SB", "BH"]
            })

          t
        end)

      refute now == before
      refute Standings.grid_standings(Repo.reload!(t)) == grid_before
    end

    test "late-entry settings", %{t: t} do
      {:ok, late} =
        Tournaments.create_player(t.id, %{
          "name" => "Joined late",
          "fide_rating" => 1500,
          "start_round" => "3"
        })

      {before, _, _, now} =
        changes(t, fn _t ->
          {:ok, _} = Tournaments.update_player(late, %{"start_round" => "2"})
          nil
        end)

      assert now |> Enum.map(& &1.player.start_round) |> Enum.member?(2)
      refute now == before

      # The rounds before a late entrant joined stop counting as absences:
      # the tournament's own setting, so a new key rather than a new version.
      {before, _, _, now} =
        changes(t, fn t ->
          {:ok, t} = Tournaments.update_tournament(t, %{"late_entry_absences" => "false"})
          t
        end)

      assert Enum.map(now, & &1.player.id) |> Enum.sort() ==
               Enum.map(before, & &1.player.id) |> Enum.sort()
    end

    test "extra points", %{t: t, players: [_, _, p3 | _]} do
      {before, _, _, now} =
        changes(t, fn _t ->
          {:ok, _} = Tournaments.update_player(p3, %{"extra_points" => "1.5"})
          nil
        end)

      refute now == before

      # Counting them is the tournament's setting: fresh either way.
      changes(t, fn t ->
        {:ok, t} = Tournaments.update_tournament(t, %{"count_extra_points" => "true"})
        t
      end)
    end

    test "categories", %{t: t, players: players} do
      {before, _, _, now} =
        changes(t, fn t ->
          {:ok, t} =
            Tournaments.update_tournament(t, %{
              "categories_enabled" => "true",
              "categories" => ["A", "B"],
              "categories_ranked_separately" => "true"
            })

          for {p, i} <- Enum.with_index(players),
              do:
                {:ok, _} =
                  Tournaments.update_player(p, %{"category" => Enum.at(~w(A B), rem(i, 2))})

          Repo.reload!(t)
        end)

      assert Enum.all?(now, &Map.has_key?(&1, :category_place))
      refute now == before
    end

    test "unpairing and pairing again", %{t: t} do
      {_before, _, version, _now} =
        changes(t, fn t ->
          :ok = Pairing.delete_round(t.id, 2)
          nil
        end)

      refute StandingsCache.version(t.id) == version

      {before, _, _, now} =
        changes(t, fn t ->
          finish_round(t, 1, "0-1")
          {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))
          nil
        end)

      refute now == before
    end

    test "a results import", %{t: t} do
      {before, _, version, now} =
        changes(t, fn t ->
          rows =
            for {p, i} <- Enum.with_index(pairings(t, 2), 1), p.black_player_id, do: {i, "0-1"}

          {:ok, _count} = ResultsImport.apply_import(t, 2, rows)
          nil
        end)

      refute StandingsCache.version(t.id) == version
      refute now == before
    end

    test "restoring a snapshot", %{t: t} do
      {:ok, snapshot} = Snapshots.capture(t, "test.before")
      finish_round(t, 2, "0-1")
      after_results = Standings.standings(Repo.reload!(t))

      {:ok, restored} = Snapshots.restore(Repo.reload!(t), snapshot.id)
      assert_fresh(restored)
      refute Standings.standings(restored) == after_results
    end

    test "a raw write the code never announced", %{t: t} do
      {before, _, version, now} =
        changes(t, fn t ->
          round = Repo.one!(from r in Round, where: r.tournament_id == ^t.id and r.number == 2)

          Repo.update_all(
            from(p in PairingsEngine.Tournaments.Pairing,
              where: p.round_id == ^round.id and not is_nil(p.black_player_id)
            ),
            set: [result: "1/2-1/2"]
          )

          nil
        end)

      refute StandingsCache.version(t.id) == version
      refute now == before
    end

    test "Keizer's ladder", %{t: _t} do
      k = tournament(%{pairing_system: "keizer", tiebreaks: []})
      roster(k, 6)
      {:ok, _} = Pairing.pair_next_round(k)
      ladder = Keizer.standings(k)
      finish_round(k, 1)
      k = Repo.reload!(k)

      refute Keizer.standings(k) == ladder
      assert Keizer.standings(k) == StandingsCache.bypass(fn -> Keizer.standings(k) end)
    end
  end

  describe "bounds" do
    test "keeps at most the configured entries per tournament" do
      previous = Application.get_env(:pairings_engine, StandingsCache)
      Application.put_env(:pairings_engine, StandingsCache, per_tournament: 3)
      on_exit(fn -> restore_env(previous) end)

      t = tournament()
      roster(t, 6)
      {:ok, _} = Pairing.pair_next_round(t)

      for n <- 0..6, do: Standings.standings(t, through_round: n)
      _ = :sys.get_state(StandingsCache)

      assert length(StandingsCache.entries(t.id)) <= 3
    end

    test "keeps at most the configured tournaments, least recently used out first" do
      previous = Application.get_env(:pairings_engine, StandingsCache)
      Application.put_env(:pairings_engine, StandingsCache, max_tournaments: 2)
      on_exit(fn -> restore_env(previous) end)

      [a, b, c] =
        for _ <- 1..3 do
          t = tournament()
          roster(t, 4)
          Standings.standings(t)
          _ = :sys.get_state(StandingsCache)
          t
        end

      assert StandingsCache.entries(a.id) == []
      refute StandingsCache.entries(b.id) == []
      refute StandingsCache.entries(c.id) == []
    end
  end

  defp restore_env(nil), do: Application.delete_env(:pairings_engine, StandingsCache)
  defp restore_env(value), do: Application.put_env(:pairings_engine, StandingsCache, value)

  # ---------- random write sequences ----------

  @ops [
    :pair,
    :result,
    :clear_result,
    :add_player,
    :rate,
    :extra,
    :absent,
    :bye_row,
    :withdraw,
    :settings,
    :unpair,
    :raw_result,
    :read
  ]

  property "after any sequence of writes, the cached answer is the fresh one" do
    check all(
            ops <-
              list_of(tuple({member_of(@ops), integer(0..50)}), min_length: 1, max_length: 14),
            max_runs: 25
          ) do
      t = tournament()
      roster(t, 5)

      Enum.reduce(ops, t, fn {op, pick}, t ->
        t = apply_op(op, pick, Repo.reload!(t)) || t
        assert_fresh(t)
        t
      end)
    end
  end

  defp apply_op(:read, _pick, t), do: tap(t, &Standings.standings/1)

  defp apply_op(:pair, _pick, t) do
    _ = Pairing.pair_next_round(t)
    nil
  end

  defp apply_op(:unpair, _pick, t) do
    case Pairing.paired_rounds_count(t.id) do
      0 -> nil
      n -> tap(nil, fn _ -> Pairing.delete_round(t.id, n) end)
    end
  end

  defp apply_op(op, pick, t) when op in [:result, :clear_result, :raw_result] do
    boards =
      for n <- 1..max(Pairing.paired_rounds_count(t.id), 1),
          p <- pairings(t, n),
          p.black_player_id,
          do: p

    if boards != [] do
      p = Enum.at(boards, rem(pick, length(boards)))
      result = Enum.at(["1-0", "0-1", "1/2-1/2", "0-0FF"], rem(pick, 4))

      case op do
        :result ->
          Tournaments.update_pairing_result(p, result)

        :clear_result ->
          Tournaments.update_pairing_result(p, "")

        :raw_result ->
          Repo.update_all(from(x in PairingsEngine.Tournaments.Pairing, where: x.id == ^p.id),
            set: [result: result]
          )
      end
    end

    nil
  end

  defp apply_op(:add_player, pick, t) do
    Tournaments.create_player(t.id, %{"name" => "New #{pick}", "fide_rating" => 1200 + pick})
    nil
  end

  defp apply_op(op, pick, t) when op in [:rate, :extra, :absent, :withdraw, :bye_row] do
    players = Tournaments.list_players(t.id)
    p = Enum.at(players, rem(pick, length(players)))

    case op do
      :rate ->
        Tournaments.update_player(p, %{"fide_rating" => 1000 + pick * 30})

      :extra ->
        Tournaments.update_player(p, %{"extra_points" => to_string(rem(pick, 3) * 0.5)})

      :absent ->
        Tournaments.update_player(p, %{
          "absent_rounds" => to_string(Pairing.paired_rounds_count(t.id) + 1)
        })

      :withdraw ->
        Tournaments.update_player(p, %{"status" => "withdrawn"})

      :bye_row ->
        Repo.insert_all(
          "byes",
          [%{tournament_id: t.id, player_id: p.id, round: 6, type: "requested-half"}],
          on_conflict: :nothing
        )
    end

    nil
  end

  defp apply_op(:settings, pick, t) do
    attrs =
      Enum.at(
        [
          %{"points_win" => "3", "points_draw" => "1"},
          %{"points_win" => "1", "points_draw" => "0.5"},
          %{"tiebreaks" => ["SB", "BH"]},
          %{"tiebreaks" => ["BH", "SB", "DE"]},
          %{"count_extra_points" => "true"},
          %{"count_extra_points" => "false"}
        ],
        rem(pick, 6)
      )

    case Tournaments.update_tournament(t, attrs) do
      {:ok, t} -> t
      _ -> nil
    end
  end
end
