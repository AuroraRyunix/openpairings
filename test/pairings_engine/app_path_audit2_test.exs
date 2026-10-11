defmodule PairingsEngine.AppPathAudit2Test do
  @moduledoc """
  The second pass of the 2026-10 app-path audit
  (docs/audit-app-path-2026-10-part2.md): round robin, Keizer, team events,
  norms, the Belgian file format, postponed games and the pages themselves.
  One test per place where the app tells an engine, or says about its own
  figures, something that is not so.

  Six of the twelve findings were left open by the audit and closed after
  it, on the decisions written up in that document; their tests were skipped
  until then and are ordinary tests now. Nothing here is skipped.
  """

  use PairingsEngine.DataCase, async: true

  import Ecto.Query

  alias PairingsEngine.{
    Keizer,
    Pairing,
    Repo,
    RoundRobin,
    Snapshot,
    Tournaments,
    TrfExport
  }

  alias PairingsEngine.Federations.BEL.{SwarExport, SwarImport}
  alias PairingsEngine.Norms.TitleNorms

  defp tournament(attrs) do
    rounds = Map.get(attrs, "rounds_count", 5)
    dates = for r <- 1..rounds, do: Date.to_iso8601(Date.add(~D[2026-08-01], (r - 1) * 7))

    {:ok, t} =
      Tournaments.create_tournament(
        Map.merge(
          %{
            "name" => "Audit 2 #{System.unique_integer([:positive])}",
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

  defp round_robin(attrs),
    do: tournament(Map.merge(%{"type" => "roundrobin", "pairing_system" => "round_robin"}, attrs))

  # `extra` gives the attributes of player `i` beyond name and rating.
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
  defp player(t, name), do: Enum.find(Tournaments.list_players(t.id), &(&1.name == name))

  defp pair!(t) do
    {:ok, round} = Pairing.pair_next_round(fresh(t))
    round
  end

  defp boards(t, number) do
    Repo.all(
      from p in PairingsEngine.Tournaments.Pairing,
        join: r in PairingsEngine.Tournaments.Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^t.id and r.number == ^number,
        order_by: p.board
    )
  end

  # Every open two-player board of round `number`: what `fun` gives for it,
  # or White's win.
  defp play(t, number, fun \\ fn _board -> nil end) do
    for b <- boards(t, number), b.white_player_id && b.black_player_id, b.result == "" do
      {:ok, _} = Tournaments.update_pairing_result(b, fun.(b) || "1-0", [])
    end

    :ok
  end

  defp publish_all(t) do
    paired = Pairing.paired_rounds_count(t.id)

    for n <- 1..paired,
        do: {:ok, _} = Tournaments.publish_round_now(Tournaments.get_round(t.id, n))

    for n <- 1..paired, do: {:ok, _} = Tournaments.publish_results(fresh(t), n)
    {:ok, _} = Tournaments.publish_standings_through(fresh(t), paired)
    fresh(t)
  end

  # `%{player no => %{round => [points]}}` of a snapshot's rounds.
  defp figures(snapshot) do
    for round <- snapshot["rounds"], reduce: %{} do
      acc ->
        n = round["number"]

        acc =
          Enum.reduce(round["boards"], acc, fn b, acc ->
            acc
            |> put_figure(b["white"], n, get_in(b, ["points", "white"]))
            |> put_figure(b["black"], n, get_in(b, ["points", "black"]))
          end)

        Enum.reduce(round["byes"], acc, fn b, acc ->
          put_figure(acc, b["player"], n, b["points"])
        end)
    end
  end

  defp put_figure(acc, no, round, points),
    do:
      Map.update(
        acc,
        no,
        %{round => [points]},
        &Map.update(&1, round, [points], fn l -> [points | l] end)
      )

  defp check(verdicts, title, name) do
    verdicts
    |> Enum.find(&(&1.title == title))
    |> Map.fetch!(:checks)
    |> Enum.find(&(&1.name == name))
  end

  ## ---------- agreed: the app's Berger table and the engine's ----------

  # Two constructions of C.05 Annex 1, written apart: the one the app pairs
  # a round robin with and the one `ainalrami -c` checks its report against.
  # Every size to 30, one to three cycles, the double round robin's reversed
  # last two rounds of the first cycle. (A single cycle has nothing to
  # reverse for the app, which ignores the switch there.)
  test "RoundRobin.schedule/4 is Ainalrami.Berger.round/4, round for round" do
    for n <- 2..30,
        cycles <- 1..3,
        reverse? <- if(cycles == 1, do: [false], else: [false, true]),
        round <- 1..RoundRobin.total_rounds(n, cycles) do
      {:ok, matches} = RoundRobin.schedule(n, cycles, round, reverse_last_two?: reverse?)
      {:ok, pairs, free} = Ainalrami.Berger.round(n, cycles, round, reverse_last_two?: reverse?)

      assert Enum.sort(for({:pairing, w, b} <- matches, do: {w, b})) == Enum.sort(pairs),
             "n=#{n} cycles=#{cycles} reversed=#{reverse?} round #{round}"

      assert for({:bye, p} <- matches, do: p) == List.wrap(free)
    end
  end

  ## ---------- G1: a round robin and the Forfeit tick (C.05 6.6) ----------

  describe "a round-robin player withdrawn with the Forfeit tick" do
    # C.05 6.6 (2) 1: "If a player has completed less than 50 % of his
    # games, the results shall remain in the tournament table (for rating
    # and historical purposes), but they shall not be counted in the final
    # standings." The Players page withdraws a player with **Forfeit**
    # (manual, chapter 5); the rule read `status` only, which that tick does
    # not touch.
    defp withdrawal_event(played_by_last) do
      t = round_robin(%{})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      {:ok, 5} = RoundRobin.pair_all_rounds(fresh(t))
      out = player(t, "P06")

      # P06 wins `played_by_last` games, then forfeits the rest.
      for n <- 1..5 do
        play(t, n, fn b ->
          cond do
            out.id not in [b.white_player_id, b.black_player_id] -> "1-0"
            n <= played_by_last and b.white_player_id == out.id -> "1-0"
            n <= played_by_last -> "0-1"
            b.white_player_id == out.id -> "0-1FF"
            true -> "1-0FF"
          end
        end)
      end

      {:ok, _} = Tournaments.update_player(out, %{"forfeit" => true})
      {t, out}
    end

    test "after two games of five: their results count for nobody" do
      {t, out} = withdrawal_event(2)
      table = PairingsEngine.Standings.standings(fresh(t))
      last = List.last(table)

      assert last.player.id == out.id
      assert last.c05_uncounted

      # Ten games among the other five; the five against P06 are out.
      kept = Enum.reject(table, &(&1.player.id == out.id))
      assert kept |> Enum.map(& &1.points) |> Enum.sum() == 10.0
    end

    test "after three games of five: counted, as before" do
      {t, _out} = withdrawal_event(3)
      table = PairingsEngine.Standings.standings(fresh(t))

      refute Enum.any?(table, &Map.get(&1, :c05_uncounted))
      assert table |> Enum.map(& &1.points) |> Enum.sum() == 15.0
    end

    # Decided 2026-10-11: the rule is the regulation's, not the Players
    # page's, so a round robin that arrives in a SWAR file with a "forfait
    # général" player is read the same way. The file holds the Forfeit tick
    # (code 1) and the importer sets it.
    test "the same event imported from a SWAR file: not counted there either" do
      {t, _out} = withdrawal_event(2)

      path = Path.join(System.tmp_dir!(), "audit2-rr-#{System.unique_integer([:positive])}.swar")
      File.write!(path, SwarExport.export(fresh(t)))
      scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
      result = SwarImport.import_file(path, scope)
      File.rm(path)
      {:ok, copy, _warnings} = result

      assert fresh(copy).pairing_system == "round_robin"
      assert player(copy, "P06").forfeit

      table = PairingsEngine.Standings.standings(fresh(copy))
      last = List.last(table)

      assert last.player.name == "P06"
      assert last.c05_uncounted

      kept = Enum.reject(table, &(&1.player.name == "P06"))
      assert kept |> Enum.map(& &1.points) |> Enum.sum() == 10.0
    end

    test "a Swiss is not touched by it" do
      t = tournament(%{})
      add_players(t, [2400, 2300, 2200, 2100])
      pair!(t)
      play(t, 1)
      {:ok, _} = Tournaments.update_player(player(t, "P04"), %{"forfeit" => true})

      refute Enum.any?(PairingsEngine.Standings.standings(fresh(t)), &Map.get(&1, :c05_uncounted))
    end
  end

  ## ---------- G3: norms, the federation mix (B.01 1.4.2, 1.4.3) ----------

  describe "a norm and an opponent under the FIDE flag" do
    # B.01 1.4.2: "Players with federation 'FID' are accepted, but do not
    # count as a foreign player." 1.4.3: "At least two federations other
    # than that of the title applicant must be included".
    test "FID is not one of the two foreign federations" do
      t = round_robin(%{"rounds_count" => 9})

      # P01 is the applicant (BEL). Nine opponents: four BEL, four FID, one
      # NED. One foreign federation, by FIDE's count.
      add_players(t, [2450, 2500, 2490, 2480, 2470, 2460, 2440, 2430, 2420, 2410], fn i ->
        fed =
          cond do
            i <= 5 -> "BEL"
            i <= 9 -> "FID"
            true -> "NED"
          end

        %{"federation" => fed, "title" => "IM"}
      end)

      {:ok, _} = RoundRobin.pair_all_rounds(fresh(t))
      for n <- 1..9, do: play(t, n)

      verdicts = TitleNorms.evaluate(fresh(t))[player(t, "P01").id].verdicts
      mix = check(verdicts, "IM", :foreign_federations)

      refute mix.ok?, mix.detail
      assert mix.detail =~ "opponents from 1 federation "
    end

    test "two real foreign federations still pass, with FID opponents beside them" do
      t = round_robin(%{"rounds_count" => 9})

      add_players(t, [2450, 2500, 2490, 2480, 2470, 2460, 2440, 2430, 2420, 2410], fn i ->
        fed =
          cond do
            i <= 4 -> "BEL"
            i <= 7 -> "FID"
            i <= 9 -> "FRA"
            true -> "NED"
          end

        %{"federation" => fed, "title" => "IM"}
      end)

      {:ok, _} = RoundRobin.pair_all_rounds(fresh(t))
      for n <- 1..9, do: play(t, n)

      verdicts = TitleNorms.evaluate(fresh(t))[player(t, "P01").id].verdicts
      assert check(verdicts, "IM", :foreign_federations).ok?
    end
  end

  ## ---------- G4: the snapshot of a round robin with a table per category ----------

  describe "the snapshot's per-round figures in a round robin" do
    # The results site adds each player's rounds up; a round with no figure
    # is "unknown" from there on and prints a dash (finding F4 of the first
    # pass, fixed there for an individual Swiss only).
    test "a category with the shorter Berger table has a figure in the longer one's last rounds" do
      t =
        round_robin(%{
          "categories_enabled" => true,
          "categories" => ["A", "B"],
          "pair_by_category" => true
        })

      # Six in A (five rounds), four in B (three).
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900, 1800, 1700, 1600, 1500], fn i ->
        %{"category" => if(i <= 6, do: "A", else: "B")}
      end)

      {:ok, 5} = RoundRobin.pair_all_rounds(fresh(t))
      for n <- 1..5, do: play(t, n)

      snapshot = Snapshot.build(publish_all(t))
      figures = figures(snapshot)

      assert snapshot["standings"]["after_round"] == 5

      for row <- snapshot["standings"]["rows"] do
        mine = Map.get(figures, row["player"], %{})

        assert Enum.sort(Map.keys(mine)) == [1, 2, 3, 4, 5],
               "player #{row["player"]} has figures for rounds #{inspect(Enum.sort(Map.keys(mine)))} only"

        assert mine |> Map.values() |> List.flatten() |> Enum.sum() == row["points"]
      end

      # And it says why: not paired, nothing scored.
      round_five = Enum.find(snapshot["rounds"], &(&1["number"] == 5))
      b_player = player(t, "P10").pairing_number

      entry = Enum.find(round_five["byes"], &(&1["player"] == b_player))
      assert entry["kind"] == "not-paired"
      assert entry["points"] == 0.0
    end

    test "a round robin over one table is published as it was" do
      t = round_robin(%{})
      add_players(t, [2400, 2300, 2200, 2100, 2000])
      {:ok, 5} = RoundRobin.pair_all_rounds(fresh(t))
      for n <- 1..5, do: play(t, n)

      snapshot = Snapshot.build(publish_all(t))

      refute Enum.any?(snapshot["rounds"], fn r ->
               Enum.any?(r["byes"], &(&1["kind"] == "not-paired"))
             end)
    end
  end

  ## ---------- G5, G6: the Belgian file ----------

  describe "an expelled player, exported to SWAR's format" do
    defp swar_copy(t) do
      path =
        Path.join(System.tmp_dir!(), "audit2-#{System.unique_integer([:positive])}.swar")

      File.write!(path, SwarExport.export(fresh(t)))
      scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
      result = SwarImport.import_file(path, scope)
      File.rm(path)
      {:ok, copy, _warnings} = result
      copy
    end

    test "is written as SWAR's Forfeit, not as Present" do
      t = tournament(%{})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      pair!(t)
      play(t, 1)
      # The Players page's Expelled tick, and its Forfeit tick.
      {:ok, _} = Tournaments.update_player(player(t, "P06"), %{"status" => "expelled"})
      {:ok, _} = Tournaments.update_player(player(t, "P05"), %{"forfeit" => true})

      {:ok, data} = SwarImport.parse(SwarExport.export(fresh(t)))
      by_name = Map.new(data.players, &{&1.name, &1.absent})

      # Absent: 1 = Forfeit, 2 = Absent, 4 = Present (SWAR manual 5.19).
      assert by_name["P06"] == 1
      assert by_name["P05"] == 1
      assert by_name["P01"] == 4
    end

    test "is not paired in the next round of the copy" do
      t = tournament(%{})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      pair!(t)
      play(t, 1)
      {:ok, _} = Tournaments.update_player(player(t, "P06"), %{"status" => "expelled"})

      copy = swar_copy(t)
      {:ok, _} = Pairing.pair_next_round(fresh(copy))
      gone = player(copy, "P06").id

      refute Enum.any?(boards(copy, 2), &(gone in [&1.white_player_id, &1.black_player_id]))

      # The same five the original pairs.
      pair!(t)
      names = fn t -> Map.new(Tournaments.list_players(t.id), &{&1.id, &1.name}) end

      seated = fn t ->
        for b <- boards(t, 2), do: {names.(t)[b.white_player_id], names.(t)[b.black_player_id]}
      end

      assert seated.(copy) == seated.(t)
    end

    test "the export says what the file makes of them" do
      t = tournament(%{})
      add_players(t, [2400, 2300, 2200, 2100])
      refute Enum.any?(SwarExport.export_notes(fresh(t)), &(&1 =~ "expelled"))

      pair!(t)
      {:ok, _} = Tournaments.update_player(player(t, "P04"), %{"status" => "expelled"})
      assert Enum.any?(SwarExport.export_notes(fresh(t)), &(&1 =~ "expelled"))
    end
  end

  describe "an absence worth more than half a point, exported to SWAR's format" do
    # SWAR's "Pt ABSENT" is a tick box: half a point, or nothing.
    test "the export says the file holds half a point" do
      t = tournament(%{"abs_value" => 1.0})
      add_players(t, [2400, 2300, 2200, 2100])

      assert Enum.any?(SwarExport.export_notes(fresh(t)), &(&1 =~ "absence half a point"))
    end

    test "half a point, or none, needs no sentence" do
      for value <- [0.5, nil] do
        t = tournament(%{"abs_value" => value})
        add_players(t, [2400, 2300, 2200, 2100])
        refute Enum.any?(SwarExport.export_notes(fresh(t)), &(&1 =~ "absence half a point"))
      end
    end
  end

  ## ---------- G7: the phone, and a board the desk has just filled ----------

  describe "a helper's phone that is a moment behind" do
    # A helper fills a blank board and nothing else (`Mobile.permit_result/4`,
    # "fill-once"). The page hands in the board as it last saw it.
    test "may not write over a result entered since the page was drawn" do
      t = tournament(%{})
      add_players(t, [2400, 2300, 2200, 2100])
      pair!(t)
      {:ok, helper} = PairingsEngine.Mobile.create_enrollment(t.id, level: "helper")

      [seen | _] = boards(t, 1)
      assert :ok = PairingsEngine.Mobile.permit_result(helper, seen, 1, 1)

      # The arbiter enters it at the desk; the phone still holds `seen`.
      {:ok, _} = Tournaments.update_pairing_result(seen, "1-0", [])

      assert {:error, :already_set} = PairingsEngine.Mobile.permit_result(helper, seen, 1, 1)
    end

    test "a deputy corrects, as before" do
      t = tournament(%{})
      add_players(t, [2400, 2300, 2200, 2100])
      pair!(t)
      {:ok, deputy} = PairingsEngine.Mobile.create_enrollment(t.id, level: "deputy")

      [seen | _] = boards(t, 1)
      {:ok, _} = Tournaments.update_pairing_result(seen, "1-0", [])
      assert :ok = PairingsEngine.Mobile.permit_result(deputy, seen, 1, 1)
    end
  end

  ## ---------- G2, G12: Keizer and a player who leaves ----------

  describe "Keizer: an opponent who is expelled" do
    # The ladder was every player whose status is "active". A win pays the
    # opponent's value, and an opponent who is not on the ladder has none -
    # so the day a player was expelled, everybody who had beaten them lost
    # those points. The manual says of an expelled player that "the
    # opponents keep the points and tie-breaks those games gave them"
    # (chapter 5). Now they do: the expelled player keeps a rung for the
    # games already played against them and loses only the row. (A player
    # withdrawn with the Forfeit tick always stayed on the ladder.)
    test "a win over them keeps its value" do
      t = tournament(%{"pairing_system" => "keizer", "rounds_count" => 4})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      pair!(t)
      play(t, 1)

      [board | _] = boards(t, 1)
      before = Enum.find(Keizer.standings(fresh(t)), &(&1.player.id == board.white_player_id))
      assert before.points > 0

      {:ok, _} =
        Tournaments.update_player(
          Tournaments.get_player!(t.id, board.black_player_id),
          %{"status" => "expelled"}
        )

      table = Keizer.standings(fresh(t))
      winner = Enum.find(table, &(&1.player.id == board.white_player_id))

      assert winner.points > 0,
             "the win over a player who was then expelled is worth #{winner.points} (it was #{before.points})"

      # The whole of it: nobody's value moved, because the ladder is as long
      # as it was.
      assert winner.points == before.points
      assert winner.value == before.value
    end

    test "their own row is gone, and the places close up" do
      t = tournament(%{"pairing_system" => "keizer", "rounds_count" => 4})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      pair!(t)
      play(t, 1)

      [board | _] = boards(t, 1)
      # The winner this time: the row that leaves is the top one.
      {:ok, _} =
        Tournaments.update_player(
          Tournaments.get_player!(t.id, board.white_player_id),
          %{"status" => "expelled"}
        )

      table = Keizer.standings(fresh(t))

      refute Enum.any?(table, &(&1.player.id == board.white_player_id))
      assert Enum.map(table, & &1.rank) == [1, 2, 3, 4, 5]

      # And they are not offered a board.
      pair!(t)

      refute Enum.any?(
               boards(t, 2),
               &(board.white_player_id in [&1.white_player_id, &1.black_player_id])
             )
    end

    test "a player who left before ever being paired has no rung" do
      t = tournament(%{"pairing_system" => "keizer", "rounds_count" => 4})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      {:ok, _} = Tournaments.update_player(player(t, "P06"), %{"status" => "expelled"})
      pair!(t)
      play(t, 1)

      table = Keizer.standings(fresh(t))
      assert length(table) == 5
      # Five on the ladder: the top value is 2 x 5.
      assert hd(table).value == 10
    end

    # The snapshot's rounds carried game points by the Swiss arithmetic
    # (`Standings.bye_points_for_row/3`: an absence pays `abs_value`); the
    # Keizer row's "score" pays an absence nothing. The rounds now say what
    # the ladder says (`Keizer.raw_bye_points/2`).
    test "the snapshot's rounds add up to the Keizer row's score" do
      t = tournament(%{"pairing_system" => "keizer", "rounds_count" => 4, "abs_value" => 0.5})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      pair!(t)
      play(t, 1)
      {:ok, _} = Tournaments.update_player(player(t, "P06"), %{"absent_rounds" => "2"})
      pair!(t)
      play(t, 2)

      snapshot = Snapshot.build(publish_all(t))
      figures = figures(snapshot)

      for row <- snapshot["standings"]["rows"] do
        sum =
          figures |> Map.get(row["player"], %{}) |> Map.values() |> List.flatten() |> Enum.sum()

        assert sum == row["score"],
               "player #{row["player"]}: rounds #{sum}, score #{row["score"]}"
      end

      # The absence is still in the document, worth what Keizer's score
      # gives it.
      round_two = Enum.find(snapshot["rounds"], &(&1["number"] == 2))
      absence = Enum.find(round_two["byes"], &(&1["player"] == player(t, "P06").pairing_number))
      assert absence["kind"] == "absent"
      assert absence["points"] == 0.0
    end

    test "a Swiss with the same setting still publishes the absence at its value" do
      t = tournament(%{"rounds_count" => 4, "abs_value" => 0.5})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      pair!(t)
      play(t, 1)
      {:ok, _} = Tournaments.update_player(player(t, "P06"), %{"absent_rounds" => "2"})
      pair!(t)
      play(t, 2)

      snapshot = Snapshot.build(publish_all(t))
      round_two = Enum.find(snapshot["rounds"], &(&1["number"] == 2))
      absence = Enum.find(round_two["byes"], &(&1["player"] == player(t, "P06").pairing_number))
      assert absence["points"] == 0.5
    end
  end

  ## ---------- G8: a round robin and C.05 6.6 on the results site ----------

  describe "a round-robin player whose results are not counted (C.05 6.6)" do
    # The arbiter's Standings page prints "-" for the place and says why.
    # The snapshot sent the row last, with a place and with points the
    # players above it do not have, and nothing to tell the two apart. It
    # now carries `"uncounted": true`, on that row only; OpenResults reads
    # it (and leaves the games against that player out of the others'
    # running scores).
    test "the snapshot says so" do
      t = round_robin(%{})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      {:ok, 5} = RoundRobin.pair_all_rounds(fresh(t))
      out = player(t, "P06")

      # P06 wins the first two games, forfeits the rest and withdraws.
      for n <- 1..5 do
        play(t, n, fn b ->
          cond do
            out.id not in [b.white_player_id, b.black_player_id] -> "1-0"
            n <= 2 and b.white_player_id == out.id -> "1-0"
            n <= 2 -> "0-1"
            b.white_player_id == out.id -> "0-1FF"
            true -> "1-0FF"
          end
        end)
      end

      {:ok, _} = Tournaments.update_player(out, %{"forfeit" => true})
      snapshot = Snapshot.build(publish_all(t))
      row = Enum.find(snapshot["standings"]["rows"], &(&1["player"] == out.pairing_number))

      assert row["uncounted"] == true,
             "the withdrawn player's row is #{inspect(Map.take(row, ~w(rank points)))} and nothing else"

      # Additive: the row is still last and still has what it had, and no
      # other row has the key at all.
      rows = snapshot["standings"]["rows"]
      assert List.last(rows) == row
      assert is_integer(row["rank"])
      refute Enum.any?(rows -- [row], &Map.has_key?(&1, "uncounted"))

      # The working of a tie-break explains the number beside it: neither
      # counts a game against the withdrawn player.
      for other <- rows -- [row],
          {_code, %{"total" => total, "parts" => parts}} <- other["working"] do
        refute Enum.any?(parts, &(&1["opponent"] == out.pairing_number))
        assert total in other["tiebreaks"]
      end

      assert row["working"] == %{}
    end

    test "a round robin where everybody stayed has no such key" do
      t = round_robin(%{})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      {:ok, 5} = RoundRobin.pair_all_rounds(fresh(t))
      for n <- 1..5, do: play(t, n)

      snapshot = Snapshot.build(publish_all(t))
      refute Enum.any?(snapshot["standings"]["rows"], &Map.has_key?(&1, "uncounted"))
    end
  end

  ## ---------- G9: the TRF26 of a tournament with a postponed game ----------

  describe "a TRF26 with an unknown result, the game counted as a win meanwhile" do
    # The file scores `?` at its own `X`, a draw - deliberately, so that it
    # adds up from itself (`TrfExport.report_unknown/2`). Its place column
    # was still the standings', which count the board as the win it was
    # given: the player in first place had fewer points, in the file, than
    # the player in second. Such a file now takes its places from itself.
    test "the places follow from the file's own points" do
      t =
        tournament(%{
          "rounds_count" => 3,
          "points_win" => 3.0,
          "points_draw" => 1.0,
          "bye_value" => 3.0,
          "postponed_games" => true,
          "postponed_requester_outcome" => "win",
          "postponed_opponent_outcome" => "loss"
        })

      add_players(t, [2400, 2300, 2200, 2100])
      pair!(t)
      [first, second] = boards(t, 1)
      {:ok, _} = Tournaments.update_pairing_result(first, "*W", [])
      {:ok, _} = Tournaments.update_pairing_result(second, "1-0", [])

      {:ok, text} = TrfExport.export(fresh(t))

      rows =
        for "001" <> _ = line <- String.split(text, ~r/\r?\n/) do
          {line |> String.slice(80, 4) |> String.trim() |> String.to_float(),
           line |> String.slice(85, 4) |> String.trim() |> String.to_integer()}
        end

      by_place = rows |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
      assert by_place == Enum.sort(by_place, :desc), "points in place order: #{inspect(by_place)}"
    end
  end

  ## ---------- G10: norms, B.01 1.4.2 ----------

  describe "a norm in a round robin with an unrated player who scored nothing" do
    # B.01 1.4.2: not included are "Games against unrated players who score
    # zero against rated opponents in round robin tournaments."
    test "the game against them is not one of the norm's games" do
      t = round_robin(%{"rounds_count" => 9})

      add_players(t, [2450, 2500, 2490, 2480, 2470, 2460, 2440, 2430, 2420, 0], fn i ->
        %{"federation" => Enum.at(~w(BEL NED FRA GER), rem(i, 4)), "title" => "IM"}
      end)

      {:ok, _} = RoundRobin.pair_all_rounds(fresh(t))
      unrated = player(t, "P10")

      # The unrated player loses every game; everybody else's are White wins.
      for n <- 1..9 do
        play(t, n, fn b ->
          cond do
            b.white_player_id == unrated.id -> "0-1"
            b.black_player_id == unrated.id -> "1-0"
            true -> nil
          end
        end)
      end

      assert TitleNorms.evaluate(fresh(t))[player(t, "P01").id].games == 8
    end

    # The reading decided on 2026-10-11: "score zero" is the total from
    # games actually played. A point nobody had to sit down for is not a
    # score.
    defp norm_event(results_of_unrated) do
      t = round_robin(%{"rounds_count" => 9})

      add_players(t, [2450, 2500, 2490, 2480, 2470, 2460, 2440, 2430, 2420, 0], fn i ->
        %{"federation" => Enum.at(~w(BEL NED FRA GER), rem(i, 4)), "title" => "IM"}
      end)

      {:ok, _} = RoundRobin.pair_all_rounds(fresh(t))
      unrated = player(t, "P10")
      names = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.name})

      # `results_of_unrated` gives, by opponent name, the result from the
      # unrated player's side; every other game of theirs is a loss.
      for n <- 1..9 do
        play(t, n, fn b ->
          cond do
            b.white_player_id == unrated.id ->
              case Map.get(results_of_unrated, names[b.black_player_id]) do
                :draw -> "1/2-1/2"
                :forfeit_win -> "1-0FF"
                nil -> "0-1"
              end

            b.black_player_id == unrated.id ->
              case Map.get(results_of_unrated, names[b.white_player_id]) do
                :draw -> "1/2-1/2"
                :forfeit_win -> "0-1FF"
                nil -> "1-0"
              end

            true ->
              nil
          end
        end)
      end

      {t, unrated}
    end

    test "a point for a game that was never played is not a score: still left out" do
      # P05 does not turn up against the unrated player, who has a point on
      # the table and nothing from a game.
      {t, unrated} = norm_event(%{"P05" => :forfeit_win})

      table = PairingsEngine.Standings.standings(fresh(t))
      assert Enum.find(table, &(&1.player.id == unrated.id)).points == 1.0

      norms = TitleNorms.evaluate(fresh(t))
      assert norms[player(t, "P01").id].games == 8
      # P05: the forfeit was never a norm game, and the unrated player's
      # other games are out, which for P05 changes nothing.
      assert norms[player(t, "P05").id].games == 8
    end

    test "one draw, and their games count for everybody" do
      {t, _unrated} = norm_event(%{"P02" => :draw})

      norms = TitleNorms.evaluate(fresh(t))
      assert norms[player(t, "P01").id].games == 9
      assert norms[player(t, "P02").id].games == 9
    end

    test "a rated player who scored nothing is not the subject" do
      t = round_robin(%{"rounds_count" => 9})

      add_players(t, [2450, 2500, 2490, 2480, 2470, 2460, 2440, 2430, 2420, 2000], fn i ->
        %{"federation" => Enum.at(~w(BEL NED FRA GER), rem(i, 4)), "title" => "IM"}
      end)

      {:ok, _} = RoundRobin.pair_all_rounds(fresh(t))
      last = player(t, "P10")

      for n <- 1..9 do
        play(t, n, fn b ->
          cond do
            b.white_player_id == last.id -> "0-1"
            b.black_player_id == last.id -> "1-0"
            true -> nil
          end
        end)
      end

      assert TitleNorms.evaluate(fresh(t))[player(t, "P01").id].games == 9
    end

    test "a Swiss is not a round robin: the article does not reach it" do
      t = tournament(%{"rounds_count" => 1})
      add_players(t, [2450, 0])
      pair!(t)
      play(t, 1, fn b -> if(b.white_player_id == player(t, "P02").id, do: "0-1", else: "1-0") end)

      assert TitleNorms.evaluate(fresh(t))[player(t, "P01").id].games == 1
    end
  end

  ## ---------- G11: a result written from a page that is behind ----------

  describe "a result entered on a board somebody else has just changed" do
    # `update_pairing_result/3` writes `result` onto the row whose id the
    # caller holds. The warnings were read from the row as stored; who sits
    # at the board was not. Between a co-arbiter's swap and this page's
    # refresh, "1-0 for the board I am looking at" landed on two other
    # players. The seats are compared now, and a difference refuses.
    test "is refused when the players at the board are no longer the ones the caller saw" do
      t = tournament(%{})
      add_players(t, [2400, 2300, 2200, 2100])
      round = pair!(t)
      [seen, other] = boards(t, 1)

      {:ok, _} =
        Tournaments.swap_players_in_round(
          Tournaments.get_round(t.id, round.number),
          seen.white_player_id,
          other.black_player_id
        )

      assert {:error, :board_changed} = Tournaments.update_pairing_result(seen, "1-0", [])

      # Nothing was written, on either board.
      assert Enum.map(boards(t, 1), & &1.result) == ["", ""]

      # The board as it is now takes the result.
      [now | _] = boards(t, 1)
      assert {:ok, %{result: "1-0"}} = Tournaments.update_pairing_result(now, "1-0", [])
    end

    test "a result somebody else entered meanwhile is still last-write-wins" do
      t = tournament(%{})
      add_players(t, [2400, 2300, 2200, 2100])
      pair!(t)
      [seen | _] = boards(t, 1)

      {:ok, _} = Tournaments.update_pairing_result(seen, "1/2-1/2", [])
      # The same players, another result on file: that is a disagreement
      # between two arbiters, not a board that moved.
      assert {:ok, %{result: "1-0"}} = Tournaments.update_pairing_result(seen, "1-0", [])
    end

    test "the page says it in words" do
      text = PairingsEngineWeb.SettingsSupport.error_text(:board_changed)
      assert text =~ "this board changed"
      assert text =~ "Reload"
    end
  end
end
