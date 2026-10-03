defmodule PairingsEngine.RoundRobinCyclesTest do
  @moduledoc """
  A round robin switched from one cycle to two after it has started, team
  and individual, and FIDE C.05 Annex 1's reversed last two rounds of a
  double round robin's first cycle (`tournaments.rr_reverse_last_two`).
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Pairing, Repo, RoundRobin, Tournaments, TrfExport}
  alias PairingsEngine.Tournaments.{Match, Round, Tournament}

  @moduletag :capture_log

  # Every Berger schedule for 2-16 participants, one and two cycles, as the
  # app paired them before `schedule/4` grew its option - the fingerprint
  # of `{n, cycles, round, schedule(n, cycles, round)}` for all 381 rounds.
  @golden "9efaf9cf8216755556b195892b162b5c37de5431f7cac0cfdf3dbc27c1c6c025"

  defp fingerprint(fun) do
    all =
      for n <- 2..16,
          c <- 1..2,
          r <- 1..RoundRobin.total_rounds(n, c),
          do: {n, c, r, fun.(n, c, r)}

    :crypto.hash(:sha256, :erlang.term_to_binary(all)) |> Base.encode16(case: :lower)
  end

  describe "schedule/4 without the reversal" do
    test "is byte for byte the schedule it always was" do
      assert fingerprint(&RoundRobin.schedule/3) == @golden

      assert fingerprint(&RoundRobin.schedule(&1, &2, &3, reverse_last_two?: false)) == @golden
    end

    test "the option changes nothing for a single cycle" do
      for n <- 2..16, r <- 1..RoundRobin.total_rounds(n, 1) do
        assert RoundRobin.schedule(n, 1, r, reverse_last_two?: true) ==
                 RoundRobin.schedule(n, 1, r)
      end
    end
  end

  describe "schedule/4 with the reversal (FIDE C.05 Annex 1)" do
    # Each player's colour per round, :bye for the round they sit out.
    defp colours(n, opts) do
      total = RoundRobin.total_rounds(n, 2)

      for r <- 1..total, reduce: %{} do
        acc ->
          {:ok, entries} = RoundRobin.schedule(n, 2, r, opts)

          Enum.reduce(entries, acc, fn
            {:pairing, w, b}, acc ->
              acc
              |> Map.update(w, [:w], &(&1 ++ [:w]))
              |> Map.update(b, [:b], &(&1 ++ [:b]))

            {:bye, p}, acc ->
              Map.update(acc, p, [:bye], &(&1 ++ [:bye]))
          end)
      end
    end

    defp three_running_at_boundary(n, opts) do
      cycle = RoundRobin.total_rounds(n, 1)

      for {player, seq} <- colours(n, opts),
          # Rounds m-1, m, m+1 and m, m+1, m+2: every run of three that
          # crosses from the first cycle into the second.
          start <- [cycle - 1, cycle],
          start >= 1,
          window = Enum.slice(seq, start - 1, 3),
          length(window) == 3,
          Enum.uniq(window) in [[:w], [:b]],
          do: {player, start}
    end

    test "nobody has the same colour three times running where the cycles meet, 4-16 players" do
      for n <- 4..16 do
        assert three_running_at_boundary(n, reverse_last_two?: true) == [],
               "#{n} players: #{inspect(three_running_at_boundary(n, reverse_last_two?: true))}"
      end
    end

    test "which the plain table does not avoid" do
      assert Enum.any?(4..16, &(three_running_at_boundary(&1, []) != []))
    end

    test "only rounds m-1 and m of the first cycle trade places; the second cycle is the table's" do
      for n <- 3..16 do
        m = RoundRobin.total_rounds(n, 1)

        for r <- 1..(2 * m) do
          expected =
            cond do
              r == m - 1 -> m
              r == m -> m - 1
              true -> r
            end

          assert RoundRobin.schedule(n, 2, r, reverse_last_two?: true) ==
                   RoundRobin.schedule(n, 2, expected),
                 "#{n} players, round #{r}"
        end
      end
    end

    test "every pair still meets twice, once with each colour" do
      for n <- 2..16 do
        meetings =
          for r <- 1..RoundRobin.total_rounds(n, 2),
              {:pairing, w, b} <- elem(RoundRobin.schedule(n, 2, r, reverse_last_two?: true), 1),
              do: {w, b}

        for a <- 1..n, b <- 1..n, a < b do
          assert Enum.count(meetings, &(&1 == {a, b})) == 1
          assert Enum.count(meetings, &(&1 == {b, a})) == 1
        end
      end
    end
  end

  ## ---------- switching single -> double after round 1 ----------

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

  # `{white_id, black_id}` per board, per round - players or teams.
  defp board_colours(t, number) do
    round = Tournaments.get_round(t.id, number)

    if Tournament.team_round_robin?(t) do
      from(m in Match, where: m.round_id == ^round.id and not is_nil(m.team_b_id))
      |> Repo.all()
      |> Enum.map(&{&1.team_a_id, &1.team_b_id})
    else
      round.pairings
      |> Enum.filter(&(&1.white_player_id && &1.black_player_id))
      |> Enum.map(&{&1.white_player_id, &1.black_player_id})
    end
    |> Enum.sort()
  end

  defp assert_every_pair_twice_reversed(t, total) do
    meetings = Enum.flat_map(1..total, &board_colours(t, &1))

    for {a, b} <- meetings do
      assert Enum.count(meetings, &(&1 == {a, b})) == 1, "#{inspect({a, b})} twice the same way"
      assert {b, a} in meetings, "#{inspect({a, b})} never reversed"
    end
  end

  for n <- [2, 3, 4] do
    test "a team round robin of #{n} teams, one cycle, becomes two after round 1" do
      n = unquote(n)
      teams = for i <- 1..n, do: {"T#{i}", [2000 - i * 10, 1900 - i * 10]}
      {t, _} = team_round_robin(teams, fide_compliance_lost_round: 0)

      _ = pair_next!(t)
      cycle = RoundRobin.total_rounds(n, 1)
      assert Repo.reload!(t).rounds_count == cycle

      refute :rr_cycles in Tournaments.locked_fields(Repo.reload!(t))
      assert {:ok, t} = Tournaments.update_tournament(Repo.reload!(t), %{"rr_cycles" => "2"})
      assert t.rounds_count == 2 * cycle
      # Team round robins keep the plain Berger order.
      refute t.rr_reverse_last_two

      t = pair_all!(t)
      assert Pairing.paired_rounds_count(t.id) == 2 * cycle

      for k <- 1..cycle do
        reversed = board_colours(t, k) |> Enum.map(fn {a, b} -> {b, a} end) |> Enum.sort()
        assert board_colours(t, cycle + k) == reversed
      end

      assert_every_pair_twice_reversed(t, 2 * cycle)
    end

    test "an individual round robin of #{n} players, one cycle, becomes two after round 1" do
      n = unquote(n)
      t = individual_rr(n)

      {:ok, _} = Pairing.pair_next_round(t)
      cycle = RoundRobin.total_rounds(n, 1)

      assert {:ok, t} = Tournaments.update_tournament(Repo.reload!(t), %{"rr_cycles" => "2"})
      assert t.rounds_count == 2 * cycle
      # Round m-1 of the first cycle is not paired yet (or there is no such
      # pair of rounds), so the reversal comes on with the second cycle.
      assert t.rr_reverse_last_two == 1 < cycle - 1

      {:ok, _} = RoundRobin.pair_all_rounds(Repo.reload!(t))
      assert Pairing.paired_rounds_count(t.id) == 2 * cycle
      assert_every_pair_twice_reversed(Repo.reload!(t), 2 * cycle)
    end
  end

  test "a whole single cycle already paired can still get its second cycle" do
    {t, _} =
      team_round_robin([{"A", [2000]}, {"B", [1900]}, {"C", [1800]}],
        fide_compliance_lost_round: 0,
        boards: 1
      )

    t = pair_all!(t)
    assert Repo.reload!(t).rounds_count == 3
    refute :rr_cycles in Tournaments.locked_fields(t)

    assert {:ok, t} = Tournaments.update_tournament(t, %{"rr_cycles" => "2"})
    assert t.rounds_count == 6
    t = pair_all!(t)
    assert_every_pair_twice_reversed(t, 6)

    # Inside the second cycle the count is fixed: going back would drop
    # rounds already on the board.
    assert :rr_cycles in Tournaments.locked_fields(Repo.reload!(t))
  end

  test "an individual double cycle switched on late keeps the plain order it already paired" do
    t = individual_rr(4)
    {:ok, _} = RoundRobin.pair_all_rounds(t)
    assert Pairing.paired_rounds_count(t.id) == 3

    assert {:ok, t} = Tournaments.update_tournament(Repo.reload!(t), %{"rr_cycles" => "2"})
    assert t.rounds_count == 6
    refute t.rr_reverse_last_two
    assert :rr_reverse_last_two in Tournaments.locked_fields(t)
  end

  test "going back to one cycle is refused once the second cycle is paired" do
    t = individual_rr(2, rr_cycles: 2)
    {:ok, _} = RoundRobin.pair_all_rounds(t)
    t = Repo.reload!(t)
    assert t.rounds_count == 2

    assert {:error, %Ecto.Changeset{errors: errors}} =
             Tournaments.update_tournament(t, %{"rr_cycles" => "1"}, unlock: [:rr_cycles])

    assert Keyword.has_key?(errors, :rr_cycles)
    assert Repo.reload!(t).rr_cycles == 2
  end

  test "an individual round robin created double pairs the reversed first cycle" do
    t = individual_rr(4, rr_cycles: 2, rr_reverse_last_two: true)
    {:ok, 6} = RoundRobin.pair_all_rounds(t)
    t = Repo.reload!(t)

    numbers =
      t.id
      |> Tournaments.list_players()
      |> Map.new(&{&1.id, &1.pairing_number})

    for r <- 1..6 do
      {:ok, expected} = RoundRobin.schedule(4, 2, r, reverse_last_two?: true)

      expected =
        for {:pairing, w, b} <- expected, do: {w, b}

      got =
        t
        |> board_colours(r)
        |> Enum.map(fn {w, b} -> {numbers[w], numbers[b]} end)

      assert Enum.sort(got) == Enum.sort(expected), "round #{r}"
    end

    assert Repo.exists?(from r in Round, where: r.tournament_id == ^t.id and r.number == 6)
  end

  describe "the TRF of a double round robin with the reversed rounds" do
    defp score_all(t) do
      for r <- t.id |> Tournaments.list_rounds(),
          p <- Tournaments.get_round(t.id, r.number).pairings,
          p.white_player_id && p.black_player_id && p.result in [nil, ""] do
        {:ok, _} = Tournaments.update_pairing_result(p, Enum.random(["1-0", "0-1", "1/2-1/2"]))
      end
    end

    defp check(text) do
      path = Path.join(System.tmp_dir!(), "rr-reverse-#{System.unique_integer([:positive])}.trf")
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

    test "is FIDE_DOUBLEROUNDROBIN and passes ainalrami -c, 4-10 players" do
      :rand.seed(:exsss, {7, 7, 7})

      for n <- 4..10 do
        t =
          individual_rr(n,
            rr_cycles: 2,
            rr_reverse_last_two: true,
            start_date: "2026-10-01",
            end_date: "2026-10-20",
            round_dates: for(d <- 1..20, do: "2026-10-#{String.pad_leading("#{d}", 2, "0")}")
          )

        {:ok, _} = RoundRobin.pair_all_rounds(t)
        t = Repo.reload!(t)
        score_all(t)

        {:ok, text} = TrfExport.export(Repo.reload!(t))
        assert text =~ ~r/^192 FIDE_DOUBLEROUNDROBIN\r?$/m
        assert check(text) == 0, "#{n} players: ainalrami -c refused the report"

        # The same boards called a plain double round robin are not the
        # Berger table's - so the check above really read the order.
        plain = String.replace(text, "192 FIDE_DOUBLEROUNDROBIN", "192 BERGER_ROUNDROBIN_G2")
        assert check(plain) != 0, "#{n} players: the plain code passed too"
      end
    end
  end
end
