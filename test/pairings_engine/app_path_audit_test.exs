defmodule PairingsEngine.AppPathAuditTest do
  @moduledoc """
  The 2026-10 app-path audit (docs/audit-app-path-2026-10.md): one test per
  place where the app tells the engine, or says about the engine, something
  the engine does not hold.

  The tests of findings that are NOT fixed are tagged `:app_path_open` and
  skipped; `APP_PATH_OPEN=1 mix test test/pairings_engine/app_path_audit_test.exs`
  runs them, and they fail, which is the point of them.
  """

  use PairingsEngine.DataCase, async: true

  import Ecto.Query

  alias PairingsEngine.{
    Pairing,
    PairingRationale,
    Repo,
    RestrictionCheck,
    Snapshot,
    Standings,
    TournamentExport,
    TournamentImport,
    Tournaments,
    TrfExport,
    TrfImport
  }

  @open System.get_env("APP_PATH_OPEN") == "1"

  defp tournament(attrs) do
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

  defp add_players(t, ratings) do
    for {rating, i} <- Enum.with_index(ratings, 1) do
      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "P#{String.pad_leading("#{i}", 2, "0")}",
          "fide_rating" => rating
        })

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

  # Every board of round `number`: the result `fun` gives for it, or the
  # higher-rated player's win.
  defp play(t, number, fun \\ fn _board -> nil end) do
    rating = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.fide_rating})

    for b <- boards(t, number), b.black_player_id do
      result =
        fun.(b) ||
          if(rating[b.white_player_id] >= rating[b.black_player_id], do: "1-0", else: "0-1")

      {:ok, _} = Tournaments.update_pairing_result(b, result, [])
    end

    :ok
  end

  defp names(t, number) do
    name = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.name})
    for b <- boards(t, number), do: {name[b.white_player_id], name[b.black_player_id]}
  end

  defp publish_all(t) do
    paired = Pairing.paired_rounds_count(t.id)

    for n <- 1..paired,
        do: {:ok, _} = Tournaments.publish_round_now(Tournaments.get_round(t.id, n))

    for n <- 1..paired, do: {:ok, _} = Tournaments.publish_results(fresh(t), n)
    fresh(t)
  end

  # `%{{player no, round} => [points]}` and the standings rows of a snapshot.
  defp snapshot_figures(snapshot) do
    for round <- snapshot["rounds"], reduce: %{} do
      acc ->
        acc =
          Enum.reduce(round["boards"], acc, fn b, acc ->
            acc
            |> Map.update(
              {b["white"], round["number"]},
              [b["points"]["white"]],
              &[b["points"]["white"] | &1]
            )
            |> Map.update(
              {b["black"], round["number"]},
              [b["points"]["black"]],
              &[b["points"]["black"] | &1]
            )
          end)

        Enum.reduce(round["byes"], acc, fn b, acc ->
          Map.update(acc, {b["player"], round["number"]}, [b["points"]], &[b["points"] | &1])
        end)
    end
  end

  ## ---------- F1: a forfeit is not a game, so the next one is not a rematch ----------

  describe "the explanation page and a pair whose first board was a forfeit" do
    # Two players, two rounds. Round 1 is forfeited, so the two have not
    # played (C.04.1 art. 1 counts games), and the engine pairs them again -
    # it has nobody else. The page then called its own engine's pairing a
    # REMATCH anomaly, in the danger colour.
    setup do
      t = tournament(%{"rounds_count" => 2})
      add_players(t, [2200, 2100])
      pair!(t)
      play(t, 1, fn _ -> "1-0FF" end)
      pair!(t)
      %{t: t}
    end

    test "the engine pairs them again", %{t: t} do
      assert [{w, b}] = names(t, 2)
      assert Enum.sort([w, b]) == ["P01", "P02"]
    end

    test "the page does not call it a rematch", %{t: t} do
      rationale = PairingRationale.for_round(fresh(t), 2)
      assert rationale.summary.rematches == 0
      refute Enum.any?(rationale.boards, & &1.rematch_anomaly)
    end

    test "a game that was played still is one", %{t: t} do
      {:ok, :ok} = {:ok, Pairing.delete_round(t.id, 2)}
      [board] = boards(t, 1)
      {:ok, _} = Tournaments.update_pairing_result(board, "1-0", [])

      # Nobody can pair this round; put the board there by hand to ask the
      # page about it.
      round =
        Repo.insert!(%PairingsEngine.Tournaments.Round{tournament_id: t.id, number: 2})

      Repo.insert!(%PairingsEngine.Tournaments.Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: board.black_player_id,
        black_player_id: board.white_player_id,
        result: ""
      })

      assert PairingRationale.for_round(fresh(t), 2).summary.rematches == 1
    end
  end

  ## ---------- F2: the Restrictions page's "cannot be paired" ----------

  describe "the restriction check and forfeited boards" do
    # The page says "not pairable is a proof: no engine can pair that round".
    # It counted a forfeited board as a game played, so its proof covered a
    # round the engine pairs without blinking.
    test "two players whose only board was a forfeit can still be paired" do
      t = tournament(%{"rounds_count" => 2})
      add_players(t, [2200, 2100])
      pair!(t)
      play(t, 1, fn _ -> "0-0FF" end)

      check = RestrictionCheck.next_round(fresh(t))
      assert check.pairable == true
      assert check.isolated == []
      assert {:ok, _round} = Pairing.pair_next_round(fresh(t))
    end

    test "a played game still closes the pair" do
      t = tournament(%{"rounds_count" => 2})
      add_players(t, [2200, 2100])
      pair!(t)
      play(t, 1)

      assert RestrictionCheck.next_round(fresh(t)).pairable == false
    end
  end

  ## ---------- F3: a prohibition's first round, after an unpairing ----------

  describe "a forbidden pair added after a round that is then unpaired" do
    # Four players. Round 2 is 1-2 and 3-4; the arbiter forbids 1-2 after
    # seeing it ("from round 3", says the row), unpairs round 2 and pairs it
    # again. The engine is handed the prohibition for round 2 - that is why
    # the arbiter unpaired it - so round 2 is the first round it holds for,
    # and the TRF's `260` has to say so.
    setup do
      t = tournament(%{"rounds_count" => 3})
      add_players(t, [2400, 2300, 2200, 2100])
      pair!(t)
      play(t, 1)
      pair!(t)

      assert Enum.sort(Enum.map(names(t, 2), fn {w, b} -> Enum.sort([w, b]) end)) ==
               [["P01", "P02"], ["P03", "P04"]]

      {:ok, _} =
        Tournaments.add_forbidden_pairing(fresh(t), player(t, "P01").id, player(t, "P02").id)

      assert [%{from_round: 3}] = Tournaments.list_forbidden_pairings(t.id)
      :ok = Pairing.delete_round(t.id, 2)
      %{t: t}
    end

    test "the round paired again keeps them apart", %{t: t} do
      pair!(t)
      refute ["P01", "P02"] in Enum.map(names(t, 2), fn {w, b} -> Enum.sort([w, b]) end)
    end

    test "and the prohibition is on record from that round", %{t: t} do
      assert [%{from_round: 2}] = Tournaments.list_forbidden_pairings(t.id)
    end

    test "unpaired back to nothing, it holds for the whole event", %{t: t} do
      :ok = Pairing.delete_round(t.id, 1)
      assert [%{from_round: nil}] = Tournaments.list_forbidden_pairings(t.id)
    end
  end

  describe "a pairing rule added after a round that is then unpaired" do
    # The same gesture with a rule instead of a pair, and the worse half of
    # the finding: a rule reads its own first round, so the round paired
    # again came out exactly as before and the arbiter was left wondering
    # what the rule was for.
    test "holds for the round paired again" do
      t = tournament(%{"rounds_count" => 3})
      add_players(t, [2400, 2300, 2200, 2100])
      pair!(t)
      play(t, 1)
      pair!(t)

      {:ok, _} =
        Tournaments.add_pairing_rule(fresh(t), %{
          "kind" => "group",
          "player_ids" => [player(t, "P01").id, player(t, "P02").id]
        })

      assert [%{from_round: 3}] = Tournaments.list_pairing_rules(t.id)
      :ok = Pairing.delete_round(t.id, 2)
      assert [%{from_round: 2}] = Tournaments.list_pairing_rules(t.id)

      pair!(t)
      refute ["P01", "P02"] in Enum.map(names(t, 2), fn {w, b} -> Enum.sort([w, b]) end)
    end

    test "a rule that was there all along is left alone" do
      t = tournament(%{"rounds_count" => 3})
      add_players(t, [2400, 2300, 2200, 2100])

      {:ok, _} =
        Tournaments.add_pairing_rule(fresh(t), %{
          "kind" => "group",
          "player_ids" => [player(t, "P01").id, player(t, "P02").id]
        })

      pair!(t)
      play(t, 1)
      pair!(t)
      :ok = Pairing.delete_round(t.id, 2)
      assert [%{from_round: nil}] = Tournaments.list_pairing_rules(t.id)
    end
  end

  ## ---------- F4: OpenResults is sent a figure for every round ----------

  describe "the snapshot's per-round figures" do
    # OpenResults adds each round's figures up into the score a player
    # brings to the next round, and a round with no figure is an unknown: a
    # dash from there on. A late entrant's rounds before joining were the
    # first case (0.83.0's predecessor); a player who withdrew and came
    # back, and one who simply stays withdrawn, were the same case nobody
    # had looked at.
    setup do
      t = tournament(%{"rounds_count" => 4})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      pair!(t)
      play(t, 1)

      {:ok, _} = Tournaments.update_player(player(t, "P03"), %{"status" => "withdrawn"})
      {:ok, _} = Tournaments.update_player(player(t, "P06"), %{"status" => "withdrawn"})
      pair!(t)
      play(t, 2)

      {:ok, _} = Tournaments.update_player(player(t, "P03"), %{"status" => "active"})
      pair!(t)
      play(t, 3)

      t = publish_all(t)
      {:ok, t} = Tournaments.publish_standings_through(t, 3)
      %{t: t, snapshot: Snapshot.build(t)}
    end

    test "every player in the standings has one figure per round", %{snapshot: snapshot} do
      figures = snapshot_figures(snapshot)
      assert snapshot["standings"]["after_round"] == 3

      for row <- snapshot["standings"]["rows"], round <- 1..3 do
        assert [points] = Map.get(figures, {row["player"], round}, []),
               "player #{row["player"]} round #{round}: #{inspect(Map.get(figures, {row["player"], round}))}"

        assert is_number(points)
      end
    end

    test "and the figures add up to the standings", %{snapshot: snapshot} do
      figures = snapshot_figures(snapshot)

      for row <- snapshot["standings"]["rows"] do
        sum =
          for(round <- 1..3, p <- Map.get(figures, {row["player"], round}, []), do: p)
          |> Enum.sum()

        assert_in_delta sum, row["points"], 0.001
      end
    end

    test "the round a withdrawn player sat out is named for what it is", %{
      t: t,
      snapshot: snapshot
    } do
      no = player(t, "P03").pairing_number
      round2 = Enum.find(snapshot["rounds"], &(&1["number"] == 2))

      assert %{"kind" => "not-paired", "points" => +0.0} =
               Enum.find(round2["byes"], &(&1["player"] == no))
    end

    test "a round whose results are withheld gets no figure it did not have", %{t: t} do
      {:ok, _} = Tournaments.unpublish_standings_through(fresh(t), 3)
      {:ok, t} = Tournaments.unpublish_results(fresh(t), 3)
      snapshot = Snapshot.build(fresh(t))
      round3 = Enum.find(snapshot["rounds"], &(&1["number"] == 3))
      no = player(t, "P06").pairing_number

      # The pairing sheet says who is not on it; that is not a result.
      assert %{"kind" => "not-paired"} = Enum.find(round3["byes"], &(&1["player"] == no))
      assert Enum.all?(round3["boards"], &is_nil(&1["result"]))
    end
  end

  ## ---------- F5: an absence paid a win's worth ----------

  describe "an announced absence worth a full point" do
    # C.07 16.1.1: a requested bye is a half-point bye or a zero-point bye.
    # An unplayed round paid what a win is paid is a full-point bye
    # (16.2.1), and the TRF says so: the app writes it `F`. The standings
    # filed it under requested byes anyway, so in the last round it counted
    # as a draw in the opponents' Buchholz (16.3.2) - and the rank column of
    # the app's own file disagreed with the file.
    setup do
      t = tournament(%{"rounds_count" => 3, "abs_value" => 1.0, "tiebreaks" => ~w(BH SB)})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900, 1800, 1700])
      pair!(t)
      play(t, 1)
      pair!(t)
      play(t, 2)
      # Somebody is away for the last round, and is paid a point for it.
      {:ok, _} = Tournaments.update_player(player(t, "P05"), %{"absent_rounds" => "3"})
      pair!(t)
      play(t, 3)
      %{t: t}
    end

    test "counts at its value in the opponents' Buchholz", %{t: t} do
      table = Standings.standings(fresh(t))
      by_id = Map.new(table, &{&1.player.id, &1})
      absentee = Enum.find(table, &(&1.player.name == "P05"))
      assert Enum.find(absentee.games, &(&1.round == 3)).points == 1.0

      # An opponent of the absentee with three games of their own: their
      # Buchholz is their opponents' scores, the absentee's point included.
      opponent =
        Enum.find(table, fn e ->
          Enum.all?(e.games, & &1.opponent_id) and
            Enum.any?(e.games, &(&1.opponent_id == absentee.player.id))
        end)

      assert opponent
      expected = opponent.games |> Enum.map(&by_id[&1.opponent_id].points) |> Enum.sum()
      assert_in_delta opponent.tiebreaks["BH"], expected, 0.001
    end

    test "the file's rank column follows from the file", %{t: t} do
      {:ok, text} = TrfExport.export(fresh(t))
      assert text =~ "0000 - F"
      refute check_output(text) =~ "do not follow"
    end

    test "an absence paid half a point is still a requested bye" do
      t = tournament(%{"rounds_count" => 3, "abs_value" => 0.5, "tiebreaks" => ~w(BH)})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900, 1800, 1700])
      pair!(t)
      play(t, 1)
      pair!(t)
      play(t, 2)
      {:ok, _} = Tournaments.update_player(player(t, "P05"), %{"absent_rounds" => "3"})
      pair!(t)
      play(t, 3)

      absentee = t |> fresh() |> Standings.standings() |> Enum.find(&(&1.player.name == "P05"))
      assert %{voluntary: true, points: 0.5} = Enum.find(absentee.games, &(&1.round == 3))
    end
  end

  defp check_output(text) do
    path = Path.join(System.tmp_dir!(), "audit-#{System.unique_integer([:positive])}.trf")
    File.write!(path, text)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        out = ExUnit.CaptureIO.capture_io(fn -> Ainalrami.CLI.run(["-c", path]) end)
        IO.write(:stderr, out)
      end)

    File.rm(path)
    output
  end

  ## ---------- F6: a withdrawal does not survive a TRF ----------

  describe "a withdrawn player, exported to TRF and imported again" do
    # TRF has no record for "withdrew". The file shows a player with nothing
    # in the later rounds, which is also what an absentee looks like, and
    # the import brings them back as active: the copy pairs somebody the
    # original would not.
    @tag skip: if(@open, do: false, else: "open finding F6 - APP_PATH_OPEN=1 runs it")
    test "the copy does not pair them in the next round" do
      t = tournament(%{"rounds_count" => 4})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      pair!(t)
      play(t, 1)
      {:ok, _} = Tournaments.update_player(player(t, "P06"), %{"status" => "withdrawn"})
      pair!(t)
      play(t, 2)

      {:ok, text} = TrfExport.export(fresh(t))
      {:ok, copy, _warnings} = TrfImport.import_text(text)
      {:ok, _} = Pairing.pair_next_round(fresh(copy))

      refute "P06" in Enum.flat_map(names(copy, 3), &Tuple.to_list/1)
    end
  end

  ## ---------- F7: a file from before `absent_counts_as_vur` ----------

  describe "an export written before absent_counts_as_vur existed" do
    # The migration gave every tournament already there `false`; the schema
    # default is `true`. A backup of such a tournament carries no key, and
    # restoring it handed it the schema's answer - so the same tournament
    # broke ties one way where it stood and another way out of its own
    # backup.
    test "comes back the way the migration left the tournament it was taken from" do
      t = tournament(%{"rounds_count" => 3})
      add_players(t, [2400, 2300, 2200, 2100])
      scope = PairingsEngine.AccountsFixtures.user_scope_fixture()

      data =
        t |> fresh() |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()

      [exported] = data["tournaments"]
      assert exported["tournament"]["absent_counts_as_vur"] == true

      old =
        put_in(data, ["tournaments"], [
          update_in(exported, ["tournament"], &Map.delete(&1, "absent_counts_as_vur"))
        ])

      {:ok, [copy]} = TournamentImport.import(old, scope)
      assert copy.absent_counts_as_vur == false

      {:ok, [current]} = TournamentImport.import(data, scope)
      assert current.absent_counts_as_vur == true
    end
  end

  ## ---------- F9: the TRF's rank column and a player who is not in the file ----------

  describe "the TRF's places when the standings hold a player the file does not" do
    # A late entrant added after round 1, in a tournament that pays the
    # round they missed: half a point already, no game yet, so no pairing
    # number and no `001` line. The standings rank them above the round-1
    # losers, and the file's places skipped the one they hold.
    test "the places in the file are 1 to N" do
      t = tournament(%{"rounds_count" => 3, "abs_value" => 0.5, "late_entry_absences" => true})
      add_players(t, [2400, 2300, 2200, 2100])
      pair!(t)
      play(t, 1)

      {:ok, late} =
        Tournaments.create_player(t.id, %{
          "name" => "Late, Entrant",
          "fide_rating" => 2000,
          "start_round" => 2
        })

      assert is_nil(late.pairing_number)
      table = Standings.standings(fresh(t))
      assert Enum.find(table, &(&1.player.id == late.id)).rank == 3

      {:ok, text} = TrfExport.export(fresh(t))

      places =
        for "001" <> _ = line <- String.split(text, "\n"),
            do: line |> binary_part(85, 4) |> String.trim() |> String.to_integer()

      assert Enum.sort(places) == [1, 2, 3, 4]
    end
  end

  ## ---------- F10: an earlier round is judged under its own rules ----------

  describe "the field a paired round is checked in" do
    # "Players of the same club do not meet in the first round." Round 1 is
    # paired under it. The checker behind a manual pairing alteration, the
    # re-explanation and the page's "why not" answers all rebuild round 1's
    # field - and built it for the round after the last one paired, where
    # the rule no longer holds. So the engine's verdict on round 1 was a
    # verdict on a round with other rules.
    setup do
      t = tournament(%{"rounds_count" => 4})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])

      # 1 and 4 would meet in round 1 (top half against bottom half).
      for name <- ~w(P01 P04) do
        {:ok, _} = Tournaments.update_player(player(t, name), %{"club" => "Same"})
      end

      {:ok, _} =
        Tournaments.add_pairing_rule(fresh(t), %{
          "kind" => "club",
          "window" => "first",
          "window_rounds" => 1
        })

      pair!(t)
      %{t: t}
    end

    test "the rule kept the two apart in round 1", %{t: t} do
      refute ["P01", "P04"] in Enum.map(names(t, 1), fn {w, b} -> Enum.sort([w, b]) end)
    end

    test "the rebuilt field of round 1 holds the rule it was paired under", %{t: t} do
      {:ok, field} = Pairing.engine_field(fresh(t), 1)
      rank = field.local_rank_by_player_id
      pair = Enum.sort([rank[player(t, "P01").id], rank[player(t, "P04").id]])

      assert pair in Enum.map(field.opts[:forbidden_pairs] || [], &Enum.sort/1)
    end

    test "a rule that starts later is not read back into an earlier round", %{t: t} do
      play(t, 1)

      {:ok, _} =
        Tournaments.add_pairing_rule(fresh(t), %{
          "kind" => "group",
          "player_ids" => [player(t, "P02").id, player(t, "P03").id]
        })

      # Added with round 1 paired: from round 2. Round 1's field has no
      # business with it.
      {:ok, field} = Pairing.engine_field(fresh(t), 1)
      rank = field.local_rank_by_player_id
      pair = Enum.sort([rank[player(t, "P02").id], rank[player(t, "P03").id]])

      refute pair in Enum.map(field.opts[:forbidden_pairs] || [], &Enum.sort/1)
    end
  end

  ## ---------- F8: Baku rounds on the explanation page ----------

  describe "the explanation page in a Baku round" do
    # Round 2 of a Baku event pairs Group A's losers (0 + 1 virtual) with
    # Group B's winners (1 + 0): one bracket, nobody floats. The page builds
    # its brackets on game points, says so in a note, and then counts every
    # one of those boards as a floater.
    @tag skip: if(@open, do: false, else: "open finding F8 - APP_PATH_OPEN=1 runs it")
    test "a board inside one pairing-score bracket is not a floater" do
      t = tournament(%{"rounds_count" => 6, "acceleration" => "baku"})
      add_players(t, [2400, 2350, 2300, 2250, 2200, 2150, 2100, 2050])
      pair!(t)
      play(t, 1)
      pair!(t)

      assert PairingRationale.for_round(fresh(t), 2).summary.floaters == 0
    end
  end
end
