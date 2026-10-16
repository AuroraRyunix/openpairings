defmodule PairingsEngine.RoundRobinMultiCycleTest do
  @moduledoc """
  Round robins of three cycles and more: everyone plays everyone N times,
  each cycle the Berger table with the colours reversed relative to the one
  before (FIDE C.05 Annex 1), through the schedule, the app, the TRF and the
  app's own export format.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{
    Pairing,
    Repo,
    RoundRobin,
    Tournaments,
    TournamentExport,
    TournamentImport,
    TrfExport,
    TrfImport
  }

  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Federations.BEL.SwarExport
  alias PairingsEngine.Tournaments.{Match, Tournament}

  @moduletag :capture_log

  # Each player's colour per round of an `n`-player, `cycles`-cycle table.
  defp schedule_meetings(n, cycles, opts \\ []) do
    for r <- 1..RoundRobin.total_rounds(n, cycles),
        {:pairing, w, b} <- elem(RoundRobin.schedule(n, cycles, r, opts), 1),
        do: {r, w, b}
  end

  describe "schedule/4 over N cycles" do
    test "the round count is cycles times one cycle's length" do
      for n <- 2..12, cycles <- 1..Tournament.max_rr_cycles() do
        per_cycle = if rem(n, 2) == 0, do: n - 1, else: n
        total = RoundRobin.total_rounds(n, cycles)
        assert total == per_cycle * cycles

        assert {:ok, _} = RoundRobin.schedule(n, cycles, total)

        assert RoundRobin.schedule(n, cycles, total + 1) ==
                 {:error, {:all_rounds_paired, total}}
      end
    end

    test "everyone meets everyone exactly N times, colours alternating cycle by cycle" do
      for n <- 2..12, cycles <- [3, 5] do
        per_cycle = RoundRobin.total_rounds(n, 1)
        meetings = schedule_meetings(n, cycles)

        for a <- 1..n, b <- 1..n, a < b do
          games =
            meetings
            |> Enum.filter(fn {_r, w, bl} -> {w, bl} in [{a, b}, {b, a}] end)
            |> Enum.sort()

          assert length(games) == cycles, "#{n} players, #{cycles} cycles, #{a}-#{b}"

          # One game per cycle, and each cycle the other one has White.
          assert Enum.map(games, fn {r, _, _} -> div(r - 1, per_cycle) end) ==
                   Enum.to_list(0..(cycles - 1))

          whites = Enum.map(games, fn {_r, w, _b} -> w end)

          for [x, y] <- Enum.chunk_every(whites, 2, 1, :discard) do
            assert x != y, "#{n} players, #{a}-#{b}: same White in consecutive cycles"
          end
        end
      end
    end

    test "cycle k is cycle k-1 with the colours reversed" do
      for n <- 2..12, cycles <- [3, 5] do
        m = RoundRobin.total_rounds(n, 1)

        for r <- (m + 1)..(m * cycles) do
          {:ok, now} = RoundRobin.schedule(n, cycles, r)
          {:ok, before} = RoundRobin.schedule(n, cycles, r - m)

          flipped =
            Enum.map(before, fn
              {:pairing, w, b} -> {:pairing, b, w}
              bye -> bye
            end)

          assert Enum.sort(now) == Enum.sort(flipped), "#{n} players, round #{r}"
        end
      end
    end

    test "an odd field gives every player one bye per cycle" do
      for n <- [3, 5, 7, 9], cycles <- [3, 5] do
        byes =
          for r <- 1..RoundRobin.total_rounds(n, cycles),
              {:bye, p} <- elem(RoundRobin.schedule(n, cycles, r), 1),
              do: p

        assert Enum.frequencies(byes) == Map.new(1..n, &{&1, cycles})
      end
    end

    test "a longer schedule only adds rounds: round K is the same whatever the cycle count" do
      for n <- 2..10, r <- 1..RoundRobin.total_rounds(n, 2) do
        assert RoundRobin.schedule(n, 3, r) == RoundRobin.schedule(n, 2, r)
        assert RoundRobin.schedule(n, 5, r) == RoundRobin.schedule(n, 2, r)
      end
    end

    test "the reversed last two rounds belong to a double round robin only" do
      for n <- 4..10, cycles <- [3, 5], r <- 1..RoundRobin.total_rounds(n, cycles) do
        assert RoundRobin.schedule(n, cycles, r, reverse_last_two?: true) ==
                 RoundRobin.schedule(n, cycles, r)
      end
    end
  end

  ## ---------- through the app ----------

  defp individual_rr(n, attrs \\ []) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Keyword.merge(
            [
              name: "RR",
              type: "roundrobin",
              pairing_system: "round_robin",
              rounds_count: 9,
              rr_cycles: 1,
              fide_compliance_lost_round: 0
            ],
            attrs
          )
        )
      )

    for i <- 1..n do
      {:ok, _} =
        Tournaments.create_player(t.id, %{"name" => "P#{i}", "fide_rating" => "#{2100 - i}"})
    end

    t
  end

  defp games(t) do
    for r <- Tournaments.list_rounds(t.id),
        p <- Tournaments.get_round(t.id, r.number).pairings,
        p.white_player_id && p.black_player_id,
        do: {r.number, p.white_player_id, p.black_player_id}
  end

  test "an individual triple round robin of 5 players: 15 rounds, everyone meets three times" do
    t = individual_rr(5, rr_cycles: 3)
    {:ok, _} = RoundRobin.pair_all_rounds(t)
    t = Repo.reload!(t)

    assert t.rounds_count == 15
    assert Pairing.paired_rounds_count(t.id) == 15

    ids = t.id |> Tournaments.list_players() |> Enum.map(& &1.id)
    played = games(t)

    for a <- ids, b <- ids, a < b do
      between = Enum.filter(played, fn {_r, w, bl} -> {w, bl} in [{a, b}, {b, a}] end)
      assert length(between) == 3
      whites = between |> Enum.sort() |> Enum.map(&elem(&1, 1))
      assert Enum.at(whites, 0) != Enum.at(whites, 1)
      assert Enum.at(whites, 1) != Enum.at(whites, 2)
    end

    byes =
      from(b in "byes",
        join: p in "players",
        on: p.id == b.player_id,
        where: p.tournament_id == ^t.id,
        select: b.player_id
      )
      |> Repo.all()
      |> Enum.frequencies()

    assert byes == Map.new(ids, &{&1, 3})
  end

  test "a team round robin of three teams over five cycles" do
    {t, _} =
      team_round_robin([{"A", [2000, 1990]}, {"B", [1900, 1890]}, {"C", [1800, 1790]}],
        rr_cycles: 5,
        fide_compliance_lost_round: 0
      )

    t = pair_all!(t)
    assert t.rounds_count == 15

    meetings =
      from(m in Match,
        join: r in assoc(m, :round),
        where: r.tournament_id == ^t.id and not is_nil(m.team_b_id),
        select: {m.team_a_id, m.team_b_id}
      )
      |> Repo.all()

    pairs = Enum.frequencies_by(meetings, fn {a, b} -> Enum.sort([a, b]) end)
    assert map_size(pairs) == 3
    assert Enum.all?(Map.values(pairs), &(&1 == 5))
  end

  describe "changing the cycle count" do
    test "a double round robin can become a triple before its second cycle starts" do
      t = individual_rr(4, rr_cycles: 2, rr_reverse_last_two: false)
      {:ok, _} = Pairing.pair_next_round(t)

      assert {:ok, t} = Tournaments.update_tournament(Repo.reload!(t), %{"rr_cycles" => "3"})
      assert t.rr_cycles == 3
      assert t.rounds_count == 9
      refute t.rr_reverse_last_two
    end

    test "switching a fresh double to three cycles drops the reversed last two rounds" do
      t = individual_rr(6, rr_cycles: 2, rr_reverse_last_two: true)
      {:ok, _} = Pairing.pair_next_round(t)

      assert {:ok, t} = Tournaments.update_tournament(Repo.reload!(t), %{"rr_cycles" => "3"})
      refute t.rr_reverse_last_two
    end

    test "a double whose reversed rounds are paired cannot become a triple" do
      t = individual_rr(4, rr_cycles: 2, rr_reverse_last_two: true)
      # Round m-1 = 2 of the 3-round cycle is the first swapped one.
      {:ok, _} = Pairing.pair_next_round(t)
      {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Tournaments.update_tournament(Repo.reload!(t), %{"rr_cycles" => "3"})

      assert Keyword.has_key?(errors, :rr_cycles)
      t = Repo.reload!(t)
      assert t.rr_cycles == 2
      assert t.rr_reverse_last_two
    end

    test "above the maximum is refused" do
      t = individual_rr(4)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Tournaments.update_tournament(t, %{
                 "rr_cycles" => to_string(Tournament.max_rr_cycles() + 1)
               })

      assert Keyword.has_key?(errors, :rr_cycles)
    end
  end

  ## ---------- files ----------

  defp score_all(t) do
    for r <- Tournaments.list_rounds(t.id),
        p <- Tournaments.get_round(t.id, r.number).pairings,
        p.white_player_id && p.black_player_id && p.result in [nil, ""] do
      {:ok, _} = Tournaments.update_pairing_result(p, Enum.random(["1-0", "0-1", "1/2-1/2"]))
    end
  end

  defp check(text) do
    path = Path.join(System.tmp_dir!(), "rr-g3-#{System.unique_integer([:positive])}.trf")
    File.write!(path, text)

    try do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Process.put(:code, Ainalrami.CLI.run(["-c", path]))
        end)
      end)

      Process.get(:code)
    after
      File.rm(path)
    end
  end

  defp dated_rr(n, cycles) do
    individual_rr(n,
      rr_cycles: cycles,
      start_date: "2026-10-01",
      end_date: "2026-10-30",
      round_dates: for(d <- 1..30, do: "2026-10-#{String.pad_leading("#{d}", 2, "0")}")
    )
  end

  test "the TRF says BERGER_ROUNDROBIN_G3, ainalrami -c accepts it, and it imports as three cycles" do
    :rand.seed(:exsss, {3, 3, 3})

    for n <- [4, 5] do
      t = dated_rr(n, 3)
      {:ok, _} = RoundRobin.pair_all_rounds(t)
      score_all(Repo.reload!(t))

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      assert text =~ ~r/^192 BERGER_ROUNDROBIN_G3\r?$/m
      assert check(text) == 0, "#{n} players: ainalrami -c refused the report"

      assert {:ok, imported, _warnings} = TrfImport.import_text(text)
      assert imported.pairing_system == "round_robin"
      assert imported.rr_cycles == 3
      refute imported.rr_reverse_last_two
    end
  end

  test "the app's own export carries five cycles across" do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    t = individual_rr(3, rr_cycles: 5)
    {:ok, _} = RoundRobin.pair_all_rounds(t)
    t = Repo.reload!(t)
    assert t.rounds_count == 15

    envelope = TournamentExport.export_tournament(t)
    assert {:ok, [imported]} = TournamentImport.import(envelope, Scope.for_user(user))
    imported = Repo.reload!(imported)

    assert imported.rr_cycles == 5
    assert imported.rounds_count == 15
    assert length(Tournaments.list_rounds(imported.id)) == 15
  end

  test "the SWAR export goes as SWAR's double round robin and says so" do
    t = individual_rr(4, rr_cycles: 3)
    assert Enum.any?(SwarExport.export_notes(t), &(&1 =~ "3 cycles"))

    t2 = individual_rr(4, rr_cycles: 2)
    refute Enum.any?(SwarExport.export_notes(t2), &(&1 =~ "cycles go as"))
  end
end
