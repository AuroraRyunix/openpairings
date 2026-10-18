defmodule PairingsEngine.PairingAudit1018Test do
  @moduledoc """
  The pairing-flow audit of 2026-10-18 (docs/audits/pairing-flow-2026-10-18.md):
  one test per finding that can make the app pair a round on state that is
  not the tournament's. Every test here FAILS on main at the time of the
  audit; each is tagged `:audit` so the suite can exclude them until the
  finding is fixed (`mix test --only audit` runs them).
  """

  use PairingsEngine.DataCase, async: false

  import Ecto.Query

  alias PairingsEngine.{Pairing, Repo, Tournaments, TrfExport, TrfImport}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Tournaments.Round

  @moduletag :audit

  ## ---------- helpers ----------

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(attrs \\ %{}) do
    rounds = Map.get(attrs, "rounds_count", 5)
    dates = for r <- 1..rounds, do: Date.to_iso8601(Date.add(~D[2026-08-01], (r - 1) * 7))

    {:ok, t} =
      Tournaments.create_tournament(
        Map.merge(
          %{
            "name" => "Audit #{System.unique_integer([:positive])}",
            "type" => "swiss",
            "city" => "Pelt",
            "federation" => "BEL",
            "chief_arbiter" => "Arbiter, Test",
            "rounds_count" => rounds,
            "start_date" => hd(dates),
            "end_date" => List.last(dates),
            "round_dates" => dates
          },
          attrs
        )
      )

    t
  end

  defp add_players(t, ratings, extra \\ fn _i -> %{} end) do
    for {rating, i} <- Enum.with_index(ratings, 1) do
      {:ok, p} =
        Tournaments.create_player(
          t.id,
          Map.merge(
            %{"name" => "P#{String.pad_leading("#{i}", 2, "0")}", "fide_rating" => rating},
            extra.(i)
          )
        )

      p
    end
  end

  defp fresh(t), do: Tournaments.get_tournament!(t.id)

  defp pair!(t) do
    {:ok, round} = Pairing.pair_next_round(fresh(t))
    round
  end

  defp boards(t, number) do
    Repo.all(
      from p in PairingsEngine.Tournaments.Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^t.id and r.number == ^number,
        order_by: p.board
    )
  end

  # Every two-player board of round `number`: the higher-rated player wins.
  defp play(t, number) do
    rating = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.fide_rating})

    for b <- boards(t, number), b.black_player_id, b.result == "" do
      result =
        if rating[b.white_player_id] >= rating[b.black_player_id], do: "1-0", else: "0-1"

      {:ok, _} = Tournaments.update_pairing_result(b, result, [])
    end

    :ok
  end

  # The TRF text handed to the engine for `round` (`:trf_built` telemetry).
  defp capture_trf(fun, round) do
    test_pid = self()
    ref = make_ref()
    id = "audit-1018-#{inspect(ref)}"

    :telemetry.attach(
      id,
      [:pairings_engine, :pairing, :trf_built],
      fn _event, _m, meta, _ -> if meta.round == round, do: send(test_pid, {ref, meta.trf}) end,
      nil
    )

    try do
      result = fun.()
      assert_received {^ref, trf}
      {result, trf}
    after
      :telemetry.detach(id)
    end
  end

  defp accelerations_by_name(trf) do
    parsed = Ainalrami.Trf.parse(trf)
    Map.new(parsed.players, &{String.trim(&1.name), &1[:accelerations] || []})
  end

  ## ---------- P1: a TRF with a round still being played ----------

  describe "P1: a TRF whose last round is paired and not finished" do
    test "the open boards of a foreign file are kept, and the next round is not paired over them" do
      lines = [
        "012 Audit mid-round",
        "XXR 5",
        player_line(1, "Alpha", 2000, "2.0", [{3, "w", "1"}, {2, "w", "1"}]),
        player_line(2, "Bravo", 1900, "1.0", [{4, "w", "1"}, {1, "b", "0"}]),
        # Round 2, board 2: paired, White and Black known, result not in yet.
        player_line(3, "Charlie", 1800, "0.0", [{1, "b", "0"}, {4, "w", " "}]),
        player_line(4, "Delta", 1700, "0.0", [{2, "b", "0"}, {3, "b", " "}])
      ]

      {:ok, t, _report} =
        TrfImport.import_with_report(Enum.join(lines, "\n") <> "\n", user_scope())

      seated = for b <- boards(t, 2), b.black_player_id, do: {b.white_player_id, b.result}

      assert length(seated) == 2,
             "round 2 of the file has two boards; the import kept #{length(seated)} " <>
               "(the one without a result was dropped)"

      assert match?({:error, _}, Pairing.pair_next_round(fresh(t))),
             "round 3 was paired while a round-2 game of the file is still to be played"
    end

    test "this app's own TRF, exported mid-round, comes back with the round's open boards" do
      t = tournament()
      add_players(t, [2000, 1900, 1800, 1700, 1600, 1500])
      pair!(t)
      play(t, 1)
      pair!(t)
      [first | _] = boards(t, 2)
      {:ok, _} = Tournaments.update_pairing_result(first, "1-0", [])

      {:ok, text} = TrfExport.export(fresh(t))
      {:ok, copy, _report} = TrfImport.import_with_report(text, user_scope())

      assert length(boards(copy, 2)) == length(boards(t, 2)),
             "the original's round 2 has #{length(boards(t, 2))} boards, the copy " <>
               "#{length(boards(copy, 2))}: the two without a result were dropped"

      assert match?({:error, _}, Pairing.pair_next_round(fresh(copy))),
             "the copy paired round 3 while two round-2 games are still being played"
    end
  end

  ## ---------- P2: an earlier round's result cleared ----------

  describe "P2: a result cleared in a round before the last" do
    test "a pair whose earlier result was cleared is not paired again" do
      t = tournament()
      add_players(t, [2000, 1900, 1800, 1700, 1600, 1500])
      pair!(t)
      play(t, 1)
      pair!(t)
      play(t, 2)

      # The arbiter clears a round-1 result (to re-enter it, or by mistake).
      # Allowed even in FIDE mode: round 1 is the round before the last.
      cleared = boards(t, 1) |> Enum.filter(& &1.black_player_id) |> Enum.at(1)
      assert {:ok, _} = Tournaments.update_pairing_result(cleared, "", [])

      {result, trf} = capture_trf(fn -> Pairing.pair_next_round(fresh(t)) end, 3)

      # The engine was handed the round-1 game with no result: an unplayed
      # game, so no colour, no point and no meeting (C.04.2 3.5).
      parsed = Ainalrami.Trf.parse(trf)
      sent = Enum.find(parsed.players, &(Enum.at(&1.games, 0).result in [nil, ""]))

      pair = MapSet.new([cleared.white_player_id, cleared.black_player_id])

      again? =
        match?({:ok, _}, result) and
          Enum.any?(boards(t, 3), &(MapSet.new([&1.white_player_id, &1.black_player_id]) == pair))

      refute again?,
             "the two players of a round-1 game whose result was cleared were paired " <>
               "against each other again in round 3 (engine input for round 1: " <>
               "#{inspect(sent && Enum.at(sent.games, 0))})"

      assert match?({:error, _}, result),
             "round 3 was paired while a round-1 board has no result"
    end
  end

  describe "P2b: the Swiss match format checks only the second leg" do
    test "the next match is not paired while a first-leg board has no result" do
      t = tournament(%{"rounds_count" => 4, "swiss_match_format" => true})
      add_players(t, [2000, 1900, 1800, 1700, 1600, 1500])
      # One click pairs both legs (rounds 1 and 2).
      pair!(t)
      assert Pairing.paired_rounds_count(t.id) == 2

      # The second leg is entered in full, the first leg not at all.
      play(t, 2)

      result = Pairing.pair_next_round(fresh(t))

      assert match?({:error, _}, result),
             "match 2 (rounds 3-4) was paired while every first-leg board of match 1 " <>
               "has no result"
    end
  end

  ## ---------- P3: Baku's virtual-point history follows today's settings ----------

  describe "P3: the virtual points of rounds already paired (C.04.7)" do
    setup do
      t = tournament(%{"rounds_count" => 9, "acceleration" => "baku"})
      add_players(t, Enum.map(0..11, &(2200 - &1 * 50)))
      {:ok, t} = Tournaments.leave_fide_mode(fresh(t))

      {_round, round3_trf} =
        capture_trf(
          fn ->
            pair!(t)
            play(t, 1)
            pair!(t)
            play(t, 2)
            pair!(t)
          end,
          3
        )

      play(t, 3)
      %{t: t, round3: accelerations_by_name(round3_trf)}
    end

    test "changing the number of rounds does not rewrite them", %{t: t, round3: round3} do
      {:ok, _} = Tournaments.update_tournament(fresh(t), %{"rounds_count" => 5})
      {_r, trf} = capture_trf(fn -> Pairing.pair_next_round(fresh(t)) end, 4)
      round4 = accelerations_by_name(trf)

      for {name, as_paired} <- round3, as_paired != [] do
        assert Enum.take(Map.get(round4, name, []), 3) == as_paired,
               "#{name}: rounds 1-3 were paired with #{inspect(as_paired)} virtual points; " <>
                 "round 4's engine input says #{inspect(Enum.take(Map.get(round4, name, []), 3))}"
      end
    end

    test "switching acceleration off does not erase them", %{t: t, round3: round3} do
      {:ok, _} = Tournaments.update_tournament(fresh(t), %{"acceleration" => "none"})
      {_r, trf} = capture_trf(fn -> Pairing.pair_next_round(fresh(t)) end, 4)
      round4 = accelerations_by_name(trf)

      for {name, as_paired} <- round3, as_paired != [] do
        assert Enum.take(Map.get(round4, name, []), 3) == as_paired,
               "#{name}: rounds 1-3 were paired with #{inspect(as_paired)} virtual points; " <>
                 "round 4's engine input has #{inspect(Map.get(round4, name, []))}"
      end
    end
  end

  ## ---------- P4: pairing by category, a category of one ----------

  describe "P4: pairing by category with a category of one player" do
    test "the lone player is not given the pairing-allocated bye a second time (C.04.3 C2)" do
      t =
        tournament(%{
          "categories_enabled" => true,
          "pair_by_category" => true,
          "categories" => ["Open", "Junior"]
        })

      add_players(t, [2000, 1900, 1800, 1700, 1200], fn
        5 -> %{"category" => "Junior"}
        _ -> %{"category" => "Open"}
      end)

      pair!(t)
      play(t, 1)
      pair!(t)

      lone = Enum.find(Tournaments.list_players(t.id), &(&1.name == "P05"))

      byes =
        for n <- [1, 2],
            b <- boards(t, n),
            b.white_player_id == lone.id and is_nil(b.black_player_id),
            do: n

      assert byes != [1, 2],
             "the only Junior was given the pairing-allocated bye in rounds 1 and 2"
    end
  end

  ## ---------- P5: Baku's Group A after the pairing numbers move ----------

  describe "P5: Group A once the pairing numbers are corrected (C.04.7 1.3.2)" do
    setup do
      t = tournament(%{"rounds_count" => 7, "acceleration" => "baku"})
      # Eight players: Group A is 2 * ceil(8 / 4) = 4, numbers 1-4.
      # P04 and P05 share a rating, so an exchange between them is allowed.
      add_players(t, [2200, 2150, 2100, 2050, 2050, 1950, 1900, 1850])

      {_round, round1_trf} = capture_trf(fn -> pair!(t) end, 1)
      play(t, 1)
      %{t: t, round1: accelerations_by_name(round1_trf)}
    end

    test "a regeneration after round 1 keeps Group A's players and their history",
         %{t: t, round1: round1} do
      # A rating correction before round 4 (C.04.2 2.3), which the Pairings
      # page then asks to regenerate the numbers for.
      p07 = Enum.find(Tournaments.list_players(t.id), &(&1.name == "P07"))
      {:ok, _} = Tournaments.update_player(p07, %{"fide_rating" => 2300})
      assert {:ok, _} = PairingsEngine.Tpn.regenerate(fresh(t))

      {_r, trf} = capture_trf(fn -> Pairing.pair_next_round(fresh(t)) end, 2)
      round2 = accelerations_by_name(trf)

      for name <- ~w(P01 P02 P03 P04 P05 P06 P07 P08) do
        assert Enum.take(Map.get(round2, name, []), 1) == Map.get(round1, name, []),
               "#{name}: round 1 was paired with #{inspect(Map.get(round1, name, []))} " <>
                 "virtual points; round 2's engine input says " <>
                 "#{inspect(Map.get(round2, name, []))}"
      end
    end

    test "an exchange of two equal ratings across the line keeps Group A's players",
         %{t: t, round1: round1} do
      [p04, p05] =
        Tournaments.list_players(t.id)
        |> Enum.filter(&(&1.name in ~w(P04 P05)))
        |> Enum.sort_by(& &1.name)

      assert {:ok, _} = PairingsEngine.Tpn.exchange(fresh(t), p04.id, p05.id)

      {_r, trf} = capture_trf(fn -> Pairing.pair_next_round(fresh(t)) end, 2)
      round2 = accelerations_by_name(trf)

      for name <- ~w(P04 P05) do
        assert Enum.take(Map.get(round2, name, []), 1) == Map.get(round1, name, []),
               "#{name}: round 1 was paired with #{inspect(Map.get(round1, name, []))} " <>
                 "virtual points; round 2's engine input says " <>
                 "#{inspect(Map.get(round2, name, []))}"
      end
    end
  end

  ## ---------- R1: two pairing runs over one late entrant ----------

  describe "R1: a late entrant numbered by two pairing runs at once" do
    test "the second run does not number them again" do
      t = tournament()
      add_players(t, [2000, 1900, 1800, 1700])
      pair!(t)
      play(t, 1)

      {:ok, _late} =
        Tournaments.create_player(t.id, %{"name" => "Late", "fide_rating" => 1950})

      # Two Pair clicks (two tabs, two arbiters) each read the roster before
      # either has written: both hold the late entrant without a number.
      stale = Pairing.active_players(t.id)
      Pairing.ensure_pairing_numbers(fresh(t), stale)
      Pairing.ensure_pairing_numbers(fresh(t), stale)

      numbers =
        t.id |> Tournaments.list_players() |> Enum.map(& &1.pairing_number) |> Enum.sort()

      assert numbers == [1, 2, 3, 4, 5],
             "the numbers after two runs are #{inspect(numbers)}"
    end
  end

  ## ---------- R2: the open hand-edit session is guarded by the page only ----------

  describe "R2: a round created by hand and not finished" do
    test "the next round is not paired over it" do
      t = tournament()
      add_players(t, [2000, 1900, 1800, 1700])
      pair!(t)
      play(t, 1)

      {:ok, round} = Pairing.create_round_by_hand(fresh(t))
      {:ok, _} = PairingsEngine.ManualPairing.start(round, [])

      result = Pairing.pair_next_round(fresh(t))

      assert match?({:error, _}, result),
             "round 3 was paired while round 2, created by hand, has no boards " <>
               "and its hand-edit session is open"
    end
  end

  ## ---------- the TRF line builder ----------

  defp col(line, position, text) do
    text = to_string(text)
    needed = position - 1 + String.length(text)
    line = if String.length(line) < needed, do: String.pad_trailing(line, needed), else: line
    {before, rest} = String.split_at(line, position - 1)
    {_, after_} = String.split_at(rest, String.length(text))
    before <> text <> after_
  end

  defp player_line(rank, name, rating, points, games) do
    line =
      ""
      |> col(1, "001")
      |> col(5, String.pad_leading(to_string(rank), 4))
      |> col(15, name)
      |> col(49, String.pad_leading(to_string(rating), 4))
      |> col(81, String.pad_leading(points, 4))
      |> col(86, String.pad_leading(to_string(rank), 4))

    games
    |> Enum.with_index(1)
    |> Enum.reduce(line, fn {{opp, colour, result}, r}, l ->
      base = 92 + (r - 1) * 10

      l
      |> col(base, String.pad_leading(to_string(opp), 4))
      |> col(base + 5, colour)
      |> col(base + 7, result)
    end)
  end
end
