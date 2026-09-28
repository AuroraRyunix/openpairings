defmodule PairingsEngine.LateEntryEdgeCasesTest do
  @moduledoc """
  Edge cases of "Rounds before a late entrant joins count as absences"
  (`PairingsEngine.LateEntry`) against the tournament's two absence caps
  (`abs_nbfois`, `abs_jusque`).

  Every case checks the SAME number in every place a score is derived:
  the standings (and so the crosstable, player card, printed lists and
  tie-breaks), the score the pairing engine is handed, the TRF report's
  `001` total, the results-site snapshot (its standings row, and each
  round's bye row against the standings' record for that round) and, for
  a SWAR-shaped event, the `.swar` file's points - see `assert_score/4`.

  The user's own case comes first: ½ per absence, three paid, through
  round 8; a player joins before round 4, so rounds 1-3 are his three paid
  absences, and an absence in round 4 is his fourth and pays nothing.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{
    LateEntry,
    Pairing,
    PlayerCard,
    Repo,
    Snapshot,
    Standings,
    TournamentExport,
    TournamentImport,
    Tournaments,
    TrfExport
  }

  alias PairingsEngine.Federations.BEL.{SwarExport, SwarImport}
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}
  alias PairingsEngine.Tournaments.Pairing, as: Board

  import Ecto.Query

  ## ---------- the event ----------

  # Six regulars (Anna..Frank) play rounds 1..`played` (`schedule/0`); a
  # seventh player, "Late Entrant", is added afterwards. By default his
  # start round is NOT set (1) - the join round is worked out, the way
  # every player added before "Joins in round" existed, and every accepted
  # registration, has it.
  defp event(attrs \\ %{}, opts \\ []) do
    played = Keyword.get(opts, :played, 3)
    rounds_count = Keyword.get(opts, :rounds_count, 9)

    tournament =
      Repo.insert!(
        struct(
          %Tournament{
            name: "Late entry edge cases",
            type: "swiss",
            pairing_system: "swiss",
            pairing_engine: "ainalrami",
            rounds_count: rounds_count,
            round_dates:
              for(d <- 1..rounds_count, do: Date.to_iso8601(Date.add(~D[2026-03-01], d))),
            tiebreaks: ["BH"],
            abs_value: 0.5,
            abs_nbfois: 3,
            abs_jusque: 8,
            publish_mode: "immediate",
            public_slug: "late-edge-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    regulars =
      for {name, no} <- [
            {"Anna", 1},
            {"Bert", 2},
            {"Cor", 3},
            {"Dirk", 4},
            {"Eva", 5},
            {"Frank", 6}
          ] do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: name,
          pairing_number: no,
          fide_rating: 2100 - no
        })
      end

    # The first five rounds of a round robin between the six, so the
    # pairing run can still find a legal round after them. In match format
    # each pair plays two legs, colours reversed.
    match? = tournament.swiss_match_format

    for n <- 1..played//1 do
      round = round!(tournament, n)
      {index, reversed?} = if match?, do: {div(n - 1, 2), rem(n, 2) == 0}, else: {n - 1, false}

      schedule()
      |> Enum.at(rem(index, 5))
      |> Enum.with_index(1)
      |> Enum.each(fn {{w, b, result}, board} ->
        {w, b} = if reversed?, do: {b, w}, else: {w, b}
        board!(round, board, Enum.at(regulars, w), Enum.at(regulars, b), result)
      end)
    end

    late =
      Repo.insert!(
        struct(
          %Player{
            tournament_id: tournament.id,
            name: "Late Entrant",
            pairing_number: 7,
            fide_rating: 1500
          },
          Keyword.get(opts, :late, %{})
        )
      )

    %{t: tournament, late: late, regulars: regulars}
  end

  # Anna..Frank are 0..5. Rounds 1-5 never repeat a pair.
  defp schedule,
    do: [
      [{0, 1, "1-0"}, {2, 3, "1/2-1/2"}, {4, 5, "1-0"}],
      [{0, 2, "1-0"}, {1, 4, "1/2-1/2"}, {3, 5, "0-1"}],
      [{0, 3, "1-0"}, {1, 5, "1/2-1/2"}, {2, 4, "0-1"}],
      [{0, 4, "1-0"}, {1, 3, "1/2-1/2"}, {2, 5, "0-1"}],
      [{0, 5, "1-0"}, {1, 2, "1/2-1/2"}, {3, 4, "0-1"}]
    ]

  defp round!(t, n),
    do: Repo.insert!(%Round{tournament_id: t.id, number: n, status: "finished"})

  defp board!(round, board, white, black, result) do
    Repo.insert!(%Board{
      round_id: round.id,
      board: board,
      white_player_id: white.id,
      black_player_id: black && black.id,
      result: result
    })
  end

  defp bye_row!(t, player, round, type) do
    Repo.insert_all("byes", [
      %{tournament_id: t.id, player_id: player.id, round: round, type: type}
    ])
  end

  # Pairs the next round with the real pairing run and plays it: white wins
  # every board.
  defp pair_and_play!(t, opts \\ []) do
    assert {:ok, round} = Pairing.pair_next_round(Tournaments.get_tournament!(t.id), opts)
    play!(t)
    round
  end

  defp play!(t) do
    for round <- Repo.all(from r in Round, where: r.tournament_id == ^t.id) do
      from(p in Board,
        where: p.round_id == ^round.id and p.result == "" and not is_nil(p.black_player_id)
      )
      |> Repo.update_all(set: [result: "1-0"])
    end
  end

  defp fresh(t), do: Tournaments.get_tournament!(t.id)

  ## ---------- the score, everywhere ----------

  defp entry(t, player),
    do: t |> fresh() |> Standings.standings() |> Enum.find(&(&1.player.id == player.id))

  defp pairing_input(t, player) do
    t = fresh(t)

    t
    |> Pairing.trf_player_rows(Tournaments.list_players(t.id))
    |> Enum.find(&(&1.id == player.id))
    |> Map.fetch!(:points)
  end

  defp trf_total(t, player) do
    player = Repo.reload!(player)
    {:ok, text} = TrfExport.export(fresh(t))

    line =
      text
      |> String.split(["\r\n", "\n"])
      |> Enum.find(&(String.starts_with?(&1, "001") and &1 =~ player.name))

    {points, _} = line |> String.slice(80, 4) |> String.trim() |> Float.parse()
    points
  end

  defp snapshot(t), do: Snapshot.build(fresh(t))

  defp snapshot_points(snapshot, player) do
    no = Repo.reload!(player).pairing_number
    row = Enum.find(snapshot["standings"]["rows"], &(&1["player"] == no))
    row && row["points"]
  end

  # `%{round => points}` for each round the snapshot publishes a bye row
  # (an allocated bye, a byes-table row, or a round before joining) for.
  defp snapshot_byes(snapshot, player) do
    no = Repo.reload!(player).pairing_number

    for round <- snapshot["rounds"],
        bye <- round["byes"] || [],
        bye["player"] == no,
        into: %{},
        do: {round["number"], bye["points"]}
  end

  defp swar_points(t, player) do
    {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
    swar = Enum.find(parsed.players, &(&1.name == Repo.reload!(player).name))
    swar.points / 4
  end

  # The one assertion every case makes: standings, pairing input, TRF 001
  # total, snapshot standings and (unless `swar: false`) the SWAR file all
  # say `expected`; and each round's bye row on the results site is worth
  # what the standings scored that round.
  defp assert_score(t, player, expected, opts \\ []) do
    standings = entry(t, player).points
    snap = snapshot(t)

    got = %{
      standings: standings,
      pairing_input: pairing_input(t, player),
      trf_001: trf_total(t, player),
      snapshot: snapshot_points(snap, player)
    }

    got =
      if Keyword.get(opts, :swar, true),
        do: Map.put(got, :swar, swar_points(t, player)),
        else: got

    assert got == Map.new(got, fn {k, _} -> {k, expected} end),
           "#{Repo.reload!(player).name}: expected #{expected} everywhere, got #{inspect(got)}"

    # Per round: the results site adds these figures up, so each must be the
    # standings' own record for the round.
    games = Map.new(entry(t, player).games, &{&1.round, &1})

    for {round, points} <- snapshot_byes(snap, player) do
      assert %{opponent_id: nil, points: standings_points} = Map.fetch!(games, round)

      assert points == standings_points,
             "round #{round}: snapshot #{points}, standings #{standings_points}"
    end

    got
  end

  # What the pages that list one round's absences show for a row (the
  # Pairings pool, the live round view, the print sheet, the public page):
  # with the counts map and without it.
  defp row_points(t, player, round) do
    t = fresh(t)
    row = %{player_id: player.id, round: round, type: "absent"}
    with_counts = Standings.bye_points_for_row(row, t, Standings.absent_counts(t))
    without = Standings.bye_points_for_row(row, t)
    assert with_counts == without
    with_counts
  end

  defp round_record(t, player, round),
    do: Enum.find(entry(t, player).games, &(&1.round == round))

  ## ---------- the user's case ----------

  describe "the user's case: ½ per absence, 3 paid, through round 8; joins before round 4" do
    test "absent in round 4 through `absent_rounds`, round 4 paired by the pairing run: no ½ point" do
      %{t: t, late: late} = event()
      {:ok, late} = Tournaments.update_player(late, %{absent_rounds: "4"})

      assert_score(t, late, 1.5)
      assert LateEntry.effective_start_rounds(fresh(t))[late.id] == {4, :next_round}

      pair_and_play!(t)

      # The pairing wrote his round-4 absence as a `byes` row.
      assert [%{type: "absent"}] =
               Enum.filter(Tournaments.list_byes_for_round(t.id, 4), &(&1.player_id == late.id))

      # Rounds 1-3: three paid absences. Round 4: the fourth, over the cap.
      assert Enum.map(1..4, &round_record(t, late, &1).points) == [0.5, 0.5, 0.5, 0.0]
      assert round_record(t, late, 4).bye_type == "absent"
      assert PlayerCard.result_label(round_record(t, late, 4), fresh(t)) == "0 bye"

      assert_score(t, late, 1.5)
      assert row_points(t, late, 4) == 0.0
      assert Standings.absent_counts(fresh(t))[{late.id, 4}] == 4
      assert LateEntry.effective_start_rounds(fresh(t))[late.id] == {4, :first_game}
      assert snapshot_byes(snapshot(t), late) == %{1 => 0.5, 2 => 0.5, 3 => 0.5, 4 => 0.0}

      # The Players-page line says the allowance is gone.
      assert LateEntry.note(fresh(t), 4, "4") ==
               "Rounds 1-3 count as absences: 1.5 points, no absences left."
    end

    test "absent in round 4 through a byes row (seat vacated, pool, import): no ½ point" do
      %{t: t, late: late, regulars: [a, b, c, d, e, f]} = event()

      r4 = round!(t, 4)
      board!(r4, 1, a, b, "1-0")
      board!(r4, 2, c, d, "1-0")
      board!(r4, 9, e, f, "1-0")
      bye_row!(t, late, 4, "absent")

      assert_score(t, late, 1.5)
      assert row_points(t, late, 4) == 0.0
      assert snapshot_byes(snapshot(t), late) == %{1 => 0.5, 2 => 0.5, 3 => 0.5, 4 => 0.0}
    end

    test "absent for the whole event (the `absent` flag): every round from 4 is unpaid" do
      %{t: t, late: late} = event()
      {:ok, late} = Tournaments.update_player(late, %{absent: true})

      pair_and_play!(t)
      pair_and_play!(t)

      assert Enum.map(1..5, &round_record(t, late, &1).points) == [0.5, 0.5, 0.5, 0.0, 0.0]
      assert_score(t, late, 1.5)
      assert row_points(t, late, 5) == 0.0
    end

    test "an explicit start round 4 gives the same answer as the worked-out one" do
      %{t: t, late: late} = event(%{}, late: %{start_round: 4, absent_rounds: "4"})

      assert LateEntry.effective_start_rounds(t)[late.id] == {4, :set}
      pair_and_play!(t)

      assert Enum.map(1..4, &round_record(t, late, &1).points) == [0.5, 0.5, 0.5, 0.0]
      assert_score(t, late, 1.5)
      assert row_points(t, late, 4) == 0.0
    end

    test "the score the pairing run brackets him by is the capped one" do
      %{t: t, late: late} = event()
      {:ok, _} = Tournaments.update_player(late, %{absent_rounds: "4"})
      pair_and_play!(t)

      # Round 5: he plays, and is paired on 1.5, not 2.0.
      {:ok, _} = Tournaments.update_player(Repo.reload!(late), %{absent_rounds: ""})
      assert pairing_input(t, late) == 1.5
      pair_and_play!(t)
      assert_score(t, late, entry(t, late).points)
      assert entry(t, late).points in [1.5, 2.5]
    end
  end

  ## ---------- the two caps ----------

  describe "the caps" do
    test "joins before round 10 with abs_jusque 8: at most 3 paid, round 9 unpaid" do
      %{t: t, late: late} = event(%{}, played: 9, rounds_count: 11)

      assert LateEntry.effective_start_rounds(t)[late.id] == {10, :next_round}

      assert Enum.map(1..9, &round_record(t, late, &1).points) ==
               [0.5, 0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

      assert_score(t, late, 1.5)
    end

    test "no count cap, abs_jusque 8, joins before round 10: rounds 1-8 paid, round 9 not" do
      %{t: t, late: late} = event(%{abs_nbfois: nil}, played: 9, rounds_count: 11)

      assert Enum.map(1..9, &round_record(t, late, &1).points) ==
               List.duplicate(0.5, 8) ++ [0.0]

      assert_score(t, late, 4.0)
      assert LateEntry.note(fresh(t), 10) == "Rounds 1-9 count as absences: 4 points."
    end

    test "the round cap bites before the count cap" do
      %{t: t, late: late} = event(%{abs_jusque: 2})

      assert Enum.map(1..3, &round_record(t, late, &1).points) == [0.5, 0.5, 0.0]
      assert_score(t, late, 1.0)
    end

    test "a count cap of 0: the rounds are absences, none of them paid" do
      %{t: t, late: late} = event(%{abs_nbfois: 0})

      assert Enum.map(1..3, &round_record(t, late, &1).bye_type) == ~w(absent absent absent)
      assert_score(t, late, 0.0)
      assert LateEntry.note(t, 4) == "Rounds 1-3 count as absences: 0 points, no absences left."
    end

    test "abs_value 0: the rule does not apply, the rounds are not absences, and his first absence is his first" do
      %{t: t, late: late, regulars: [a, b, c, d, e, f]} = event(%{abs_value: 0.0})

      refute LateEntry.applies?(t)
      assert entry(t, late).games == []
      assert_score(t, late, 0.0)

      r4 = round!(t, 4)
      board!(r4, 1, a, b, "1-0")
      board!(r4, 2, c, d, "1-0")
      board!(r4, 9, e, f, "1-0")
      bye_row!(t, late, 4, "absent")
      assert_score(t, late, 0.0)
    end
  end

  ## ---------- requested byes are not absences ----------

  describe "a requested bye after the allowance is used up" do
    # SWAR has no "requested bye" record at all: an announced absence is a
    # `TABLE_ABSENT` record, and `GetNbAbsence` (Utils.cpp:1102-1118) counts
    # exactly those. A ½-point bye in a SWAR file is `DRAW_BYE` on the bye
    # table (PairingSwiss.cpp:76), which `GetPoints` pays through
    # `GetSpecialByeValue`, never `GetSpecialAbsValue`, and which is not
    # counted. So: a requested bye pays its own value and uses no absence.
    test "a requested half-point bye still pays ½, and does not use an absence" do
      %{t: t, late: late, regulars: [a, b, c, d, e, f]} = event()

      r4 = round!(t, 4)
      board!(r4, 1, late, a, "0-1")
      board!(r4, 2, b, c, "1-0")
      board!(r4, 3, d, nil, "bye")
      board!(r4, 9, e, f, "1-0")

      r5 = round!(t, 5)
      board!(r5, 1, a, b, "1-0")
      board!(r5, 2, c, d, "1-0")
      board!(r5, 9, e, f, "1-0")
      bye_row!(t, late, 5, "requested-half")

      assert round_record(t, late, 5).points == 0.5
      # A voluntary unplayed round for the tie-breaks, like an absence.
      assert round_record(t, late, 5).voluntary
      assert_score(t, late, 2.0)

      # Round 6: an absence - his fourth (the half-point bye was not one).
      r6 = round!(t, 6)
      board!(r6, 1, a, b, "1-0")
      board!(r6, 2, c, d, "1-0")
      board!(r6, 9, e, f, "1-0")
      bye_row!(t, late, 6, "absent")

      assert round_record(t, late, 6).points == 0.0
      assert Standings.absent_counts(fresh(t))[{late.id, 6}] == 4
      assert row_points(t, late, 6) == 0.0
      assert_score(t, late, 2.0)
    end

    test "a requested zero-point bye pays nothing and uses nothing" do
      %{t: t, late: late, regulars: [a, b, c, d, e, f]} = event(%{abs_nbfois: 4})

      r4 = round!(t, 4)
      board!(r4, 1, a, b, "1-0")
      board!(r4, 2, c, d, "1-0")
      board!(r4, 9, e, f, "1-0")
      bye_row!(t, late, 4, "requested-zero")

      r5 = round!(t, 5)
      board!(r5, 1, a, b, "1-0")
      board!(r5, 2, c, d, "1-0")
      board!(r5, 9, e, f, "1-0")
      bye_row!(t, late, 5, "absent")

      # Rounds 1-3 and 5 are his four absences; round 4 was not one.
      assert Enum.map(1..5, &round_record(t, late, &1).points) == [0.5, 0.5, 0.5, 0.0, 0.5]
      assert_score(t, late, 2.0)
    end

    test "tie-breaks: his opponents' Buchholz counts his capped score, not 0.5 more" do
      %{t: t, late: late, regulars: [a, b, c, d, e, f]} = event()

      # Round 4: absent (his fourth absence, 0). Round 5: loses to Anna.
      r4 = round!(t, 4)
      board!(r4, 1, a, b, "1-0")
      board!(r4, 2, c, d, "1-0")
      board!(r4, 3, e, f, "1-0")
      bye_row!(t, late, 4, "absent")

      r5 = round!(t, 5)
      board!(r5, 1, late, a, "0-1")
      board!(r5, 2, b, c, "1-0")
      board!(r5, 3, d, e, "1-0")
      board!(r5, 4, f, nil, "bye")

      assert_score(t, late, 1.5)

      standings = t |> fresh() |> Standings.standings()
      points = Map.new(standings, &{&1.player.id, &1.points})
      anna = Enum.find(standings, &(&1.player.id == a.id))

      opponents =
        for g <- anna.games, g.opponent_id != nil, do: g.opponent_id

      assert late.id in opponents
      # Nobody Anna met has an unplayed round at the end, so C.07 adjusts
      # nothing: her Buchholz is her opponents' scores - his 1.5 among them.
      assert anna.tiebreaks["BH"] == opponents |> Enum.map(&points[&1]) |> Enum.sum()
    end

    test "tie-breaks: rounds before joining are unplayed rounds scored as absences" do
      %{t: t, late: late} = event()
      rounds = Enum.map(1..3, &round_record(t, late, &1))

      # `absent_counts_as_vur` (on by default): voluntary, like any absence.
      assert Enum.all?(rounds, &(&1.voluntary and not &1.played))

      off = event(%{absent_counts_as_vur: false})
      assert Enum.all?(Enum.map(1..3, &round_record(off.t, off.late, &1)), &(not &1.voluntary))
    end
  end

  ## ---------- the setting ----------

  describe "the setting" do
    test "off: the rounds score nothing, and an absence in round 4 is his first, paid" do
      %{t: t, late: late, regulars: [a, b, c, d, e, f]} = event(%{late_entry_absences: false})

      assert_score(t, late, 0.0)

      r4 = round!(t, 4)
      board!(r4, 1, a, b, "1-0")
      board!(r4, 2, c, d, "1-0")
      board!(r4, 9, e, f, "1-0")
      bye_row!(t, late, 4, "absent")

      assert_score(t, late, 0.5)
      assert row_points(t, late, 4) == 0.5
    end

    test "switched off and on again mid-event rescores everywhere at once" do
      %{t: t, late: late, regulars: [a, b, c, d, e, f]} = event()

      r4 = round!(t, 4)
      board!(r4, 1, a, b, "1-0")
      board!(r4, 2, c, d, "1-0")
      board!(r4, 9, e, f, "1-0")
      bye_row!(t, late, 4, "absent")
      assert_score(t, late, 1.5)

      {:ok, _} = Tournaments.update_tournament(fresh(t), %{late_entry_absences: false})
      assert_score(t, late, 0.5)
      assert row_points(t, late, 4) == 0.5

      {:ok, _} = Tournaments.update_tournament(fresh(t), %{late_entry_absences: true})
      assert_score(t, late, 1.5)
      assert row_points(t, late, 4) == 0.0
    end

    test "a finished event's backup from before the setting existed restores with it off" do
      %{t: t, late: late} = event(%{status: "finished"})

      envelope =
        t
        |> fresh()
        |> TournamentExport.export_tournament()
        |> Jason.encode!()
        |> Jason.decode!()
        |> update_in(
          ["tournaments", Access.at(0), "tournament"],
          &Map.delete(&1, "late_entry_absences")
        )

      assert {:ok, [copy]} = TournamentImport.import(envelope, user_scope())
      refute copy.late_entry_absences

      copy_late =
        Repo.one!(from p in Player, where: p.tournament_id == ^copy.id and p.name == ^late.name)

      assert_score(copy, copy_late, 0.0)
    end
  end

  ## ---------- what else can happen to the late entrant ----------

  describe "the late entrant afterwards" do
    test "withdraws after playing round 4: rounds 1-3 stay his absences" do
      %{t: t, late: late} = event()
      pair_and_play!(t)
      {:ok, late} = Tournaments.update_player(Repo.reload!(late), %{status: "withdrawn"})

      assert LateEntry.effective_start_rounds(fresh(t))[late.id] == {4, :first_game}
      assert_score(t, late, entry(t, late).points)
      assert Enum.map(1..3, &round_record(t, late, &1).points) == [0.5, 0.5, 0.5]
    end

    test "withdrawn before he ever played, start round not set: he never joined" do
      %{t: t, late: late} = event(%{}, late: %{status: "withdrawn"})
      assert LateEntry.effective_start_rounds(t)[late.id] == nil
      assert_score(t, late, 0.0)
    end

    test "forfeited (removed from pairing) before he ever played, start round not set: never joined" do
      %{t: t, late: late} = event(%{}, late: %{forfeit: true})
      assert LateEntry.effective_start_rounds(t)[late.id] == nil
      assert_score(t, late, 0.0)
    end

    test "forfeited with an explicit start round: the organiser's round stands" do
      %{t: t, late: late} = event(%{}, late: %{forfeit: true, start_round: 4})
      assert_score(t, late, 1.5)
    end

    test "loses round 4 by forfeit: the forfeit is a game, not an absence" do
      %{t: t, late: late, regulars: [a, b, c, d, e, f]} = event()

      r4 = round!(t, 4)
      board!(r4, 1, a, late, "1-0FF")
      board!(r4, 2, b, c, "1-0")
      board!(r4, 3, d, nil, "bye")
      board!(r4, 9, e, f, "1-0")

      assert_score(t, late, 1.5)

      # So a later absence is still his fourth.
      r5 = round!(t, 5)
      board!(r5, 1, a, b, "1-0")
      board!(r5, 2, c, d, "1-0")
      board!(r5, 9, e, f, "1-0")
      bye_row!(t, late, 5, "absent")
      assert_score(t, late, 1.5)
      assert row_points(t, late, 5) == 0.0
    end

    test "gets the pairing-allocated bye in round 4: bye value on top of his three absences" do
      %{t: t, late: late, regulars: [a, b, c, d, e, f]} = event()

      r4 = round!(t, 4)
      board!(r4, 1, a, b, "1-0")
      board!(r4, 2, c, d, "1-0")
      board!(r4, 9, e, f, "1-0")
      board!(r4, 3, late, nil, "bye")

      assert_score(t, late, 2.5)
      assert snapshot_byes(snapshot(t), late)[4] == 1.0
    end

    test "excluded from the bye: the pairing run gives it to someone else, and his score holds" do
      # No absence paid (cap 0), so he is last on 0 points and the natural
      # bye among seven; excluded, it goes to someone else.
      %{t: t, late: late} = event(%{abs_nbfois: 0})
      assert_score(t, late, 0.0)
      {:ok, _} = Tournaments.update_player(Repo.reload!(late), %{no_bye: true})

      round = pair_and_play!(t) |> Repo.preload(:pairings)
      bye = Enum.find(round.pairings, &is_nil(&1.black_player_id))
      assert bye && bye.white_player_id != late.id

      assert_score(t, late, entry(t, late).points)
      assert entry(t, late).points in [0.0, 1.0]
    end

    test "extra points (handicap, counted): game points everywhere, the extra on top in the total" do
      %{t: t, late: late} = event(%{count_extra_points: true}, late: %{extra_points: 1.0})

      assert_score(t, late, 1.5)
      assert entry(t, late).total == 2.5

      row =
        snapshot(t)["standings"]["rows"]
        |> Enum.find(&(&1["player"] == 7))

      assert row["extra_points"] == 1.0
      assert row["total"] == 2.5
    end

    test "acceleration points: the same game points everywhere" do
      %{t: t, late: late} =
        event(%{extra_points_mode: "acceleration", count_extra_points: false},
          late: %{extra_points: 1.0}
        )

      assert_score(t, late, 1.5)
    end
  end

  ## ---------- rounds changing under him ----------

  describe "rounds changing afterwards" do
    test "unpair round 4 and pair it again: same score before, between and after" do
      %{t: t, late: late} = event()
      {:ok, _} = Tournaments.update_player(late, %{absent_rounds: "4"})

      pair_and_play!(t)
      assert_score(t, late, 1.5)

      :ok = Pairing.delete_round(t.id, 4)
      assert Tournaments.list_byes_for_round(t.id, 4) == []
      assert_score(t, late, 1.5)

      pair_and_play!(t)
      assert_score(t, late, 1.5)
      assert row_points(t, late, 4) == 0.0
    end

    test "delete round 3 before he joins: worked out, he now joins in round 3" do
      %{t: t, late: late} = event()
      :ok = Pairing.delete_round(t.id, 3)

      assert LateEntry.effective_start_rounds(fresh(t))[late.id] == {3, :next_round}
      assert_score(t, late, 1.0)
    end

    test "delete round 3 with his start round set to 4: rounds 1-2 now, round 3 again once re-paired" do
      %{t: t, late: late} = event(%{}, late: %{start_round: 4})
      :ok = Pairing.delete_round(t.id, 3)
      assert_score(t, late, 1.0)

      pair_and_play!(t)

      refute Enum.any?(
               Tournaments.get_round(t.id, 3).pairings,
               &(late.id in [&1.white_player_id, &1.black_player_id])
             )

      assert_score(t, late, 1.5)
    end

    test "start round changed after his round-4 absence: the absences are re-counted" do
      %{t: t, late: late, regulars: [a, b, c, d, e, f]} = event()

      r4 = round!(t, 4)
      board!(r4, 1, a, b, "1-0")
      board!(r4, 2, c, d, "1-0")
      board!(r4, 9, e, f, "1-0")
      bye_row!(t, late, 4, "absent")
      assert_score(t, late, 1.5)

      # Joined in round 3 after all: rounds 1-2 are absences, round 3 (his,
      # with nothing in it) scores nothing, and round 4 is his third
      # absence - paid.
      {:ok, late} = Tournaments.update_player(Repo.reload!(late), %{start_round: 3})
      assert Enum.map(1..2, &round_record(t, late, &1).points) == [0.5, 0.5]
      assert round_record(t, late, 3) == nil
      assert row_points(t, late, 4) == 0.5
      assert_score(t, late, 1.5)

      # Joined in round 2: round 1 only, and round 4 is his second.
      {:ok, late} = Tournaments.update_player(late, %{start_round: 2})
      assert_score(t, late, 1.0)
    end

    test "a regular's postponed game in round 2 does not move anyone's join round" do
      %{t: t, late: late, regulars: [_a, _b, c | _]} = event(%{postponed_games: true})

      r2 = Tournaments.get_round(t.id, 2)
      board = Enum.find(r2.pairings, &(c.id in [&1.white_player_id, &1.black_player_id]))
      board |> Ecto.Changeset.change(result: "*") |> Repo.update!()

      assert LateEntry.effective_start_rounds(fresh(t)) == %{late.id => {4, :next_round}}
      assert Enum.map(1..3, &round_record(t, late, &1).points) == [0.5, 0.5, 0.5]
      assert_score(t, late, 1.5)
    end
  end

  ## ---------- other point systems and pairing systems ----------

  describe "other point systems" do
    test "3-1-0 with an absence worth 1: three paid at 1, the fourth at the loss value" do
      %{t: t, late: late, regulars: [a, b, c, d, e, f]} =
        event(%{points_win: 3.0, points_draw: 1.0, points_loss: 0.0, abs_value: 1.0})

      r4 = round!(t, 4)
      board!(r4, 1, a, b, "1-0")
      board!(r4, 2, c, d, "1-0")
      board!(r4, 9, e, f, "1-0")
      bye_row!(t, late, 4, "absent")

      assert Enum.map(1..4, &round_record(t, late, &1).points) == [1.0, 1.0, 1.0, 0.0]
      # SWAR has no 3-1-0 scale; its file is not a check here.
      assert_score(t, late, 3.0, swar: false)
    end

    test "2-1-0 with ½ per absence: ½ each, never mistaken for a draw" do
      %{t: t, late: late} = event(%{points_win: 2.0, points_draw: 1.0, points_loss: 0.0})
      assert_score(t, late, 1.5, swar: false)
    end
  end

  describe "systems the rule leaves alone" do
    test "round robin: no absences, whatever the setting" do
      %{t: t, late: late} = event(%{type: "roundrobin", pairing_system: "round_robin"})

      assert LateEntry.absences(t) == []
      assert entry(t, late).games == []
      assert entry(t, late).points == 0.0
    end

    test "Keizer: no absences from this rule" do
      t =
        Repo.insert!(%Tournament{
          name: "Keizer",
          type: "swiss",
          pairing_system: "keizer",
          rounds_count: 5,
          abs_value: 0.5,
          abs_nbfois: 3
        })

      p = Repo.insert!(%Player{tournament_id: t.id, name: "K", start_round: 4, pairing_number: 1})
      Repo.insert!(%Round{tournament_id: t.id, number: 1})

      refute LateEntry.applies?(t)
      assert LateEntry.absences(t) == []
      refute LateEntry.derives?(t)
      assert LateEntry.effective_start_rounds(t) == %{p.id => {4, :set}}
    end

    test "team events: no absences, and no join round worked out" do
      for type <- ["team-swiss", "team-roundrobin"] do
        %{t: t, late: late} = event(%{type: type})

        refute LateEntry.applies?(t)
        assert LateEntry.absences(t) == []
        assert LateEntry.effective_start_rounds(t)[late.id] == nil
        refute Enum.any?(entry(t, late).games, &Map.get(&1, :late_entry))
      end
    end
  end

  describe "match format (two legs per round)" do
    test "joins at the third match: rounds 1-4 before him, three paid; absent for both legs, unpaid" do
      %{t: t, late: late} =
        event(%{swiss_match_format: true}, played: 4, rounds_count: 8)

      assert LateEntry.effective_start_rounds(t)[late.id] == {5, :next_round}
      assert Enum.map(1..4, &round_record(t, late, &1).points) == [0.5, 0.5, 0.5, 0.0]
      assert_score(t, late, 1.5)

      {:ok, _} = Tournaments.update_player(late, %{absent_rounds: "5"})
      pair_and_play!(t)

      assert Enum.map(5..6, &round_record(t, late, &1).bye_type) == ~w(absent absent)
      assert Enum.map(5..6, &round_record(t, late, &1).points) == [0.0, 0.0]
      assert_score(t, late, 1.5)
    end

    # Left for the organiser to decide (see the report): a match's second
    # leg mirrors its first, so a player whose start round is set on it
    # cannot be seated there. Round 3 is before he joins (an absence);
    # round 4 is his, holds nothing, and scores nothing - consistently.
    test "a start round set on a match's second leg: that leg scores nothing, everywhere alike" do
      %{t: t, late: late} =
        event(%{swiss_match_format: true, abs_nbfois: nil},
          played: 2,
          rounds_count: 8,
          late: %{start_round: 4}
        )

      pair_and_play!(t)

      assert Enum.map(1..3, &round_record(t, late, &1).points) == [0.5, 0.5, 0.5]
      assert round_record(t, late, 4) == nil
      assert_score(t, late, 1.5)
    end
  end

  ## ---------- files ----------

  describe "files" do
    # A TRF of chosen rounds adds up those rounds' points - each worth what
    # the standings paid for it, which for an absence depends on how many
    # came BEFORE it, in rounds the file leaves out.
    test "a TRF of rounds 2-4 only: each absence at the value the standings gave it" do
      %{t: t, late: late} = event()
      {:ok, _} = Tournaments.update_player(late, %{absent_rounds: "4"})
      pair_and_play!(t)

      total = fn spec ->
        {:ok, text} = TrfExport.export(fresh(t), spec)

        line =
          text
          |> String.split(["\r\n", "\n"])
          |> Enum.find(&(String.starts_with?(&1, "001") and &1 =~ late.name))

        {points, _} = line |> String.slice(80, 4) |> String.trim() |> Float.parse()
        points
      end

      assert total.("1-4") == 1.5
      assert total.("2-4") == 1.0
      assert total.("4") == 0.0
      assert total.("3,4") == 0.5
    end

    test "backup and restore: the same scores, nothing written for the rounds before joining" do
      %{t: t, late: late} = event()
      {:ok, _} = Tournaments.update_player(late, %{absent_rounds: "4"})
      pair_and_play!(t)

      envelope =
        t |> fresh() |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()

      assert {:ok, [copy]} = TournamentImport.import(envelope, user_scope())
      assert copy.late_entry_absences

      copy_late =
        Repo.one!(from p in Player, where: p.tournament_id == ^copy.id and p.name == ^late.name)

      assert copy_late.start_round == 1

      assert Repo.all(
               from b in "byes",
                 where: b.player_id == ^copy_late.id and b.round < 4,
                 select: b.round
             ) == []

      assert_score(copy, copy_late, 1.5)
    end

    test "SWAR export, then import: the rounds before joining arrive as real absences, same score" do
      %{t: t, late: late} = event()
      {:ok, _} = Tournaments.update_player(late, %{absent_rounds: "4"})
      pair_and_play!(t)

      path = Path.join(System.tmp_dir!(), "late_edge_#{System.unique_integer([:positive])}.swar")
      File.write!(path, SwarExport.export(t.id))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, copy, _warnings} = SwarImport.import_file(path)
      # Public at once, so the snapshot has standings to compare.
      copy = copy |> fresh() |> Ecto.Changeset.change(publish_mode: "immediate") |> Repo.update!()
      assert copy.late_entry_absences
      assert {copy.abs_value, copy.abs_nbfois, copy.abs_jusque} == {0.5, 3, 8}

      copy_late =
        Repo.one!(from p in Player, where: p.tournament_id == ^copy.id and p.name == ^late.name)

      # SWAR's own records: four absences, rounds 1-4.
      assert Repo.all(
               from b in "byes",
                 where: b.player_id == ^copy_late.id and b.type == "absent",
                 order_by: b.round,
                 select: b.round
             ) == [1, 2, 3, 4]

      assert_score(copy, copy_late, 1.5)
      assert row_points(copy, copy_late, 4) == 0.0
    end

    # With the setting off the rounds before joining are worth nothing, and
    # the file writes them as rounds with nothing in them - which SWAR
    # scores 0 and does not count as absences (`GetPoints` pays `AbsValue`
    # only for `TABLE_ABSENT`, `GetNbAbsence` counts only those). Read back,
    # they must stay worth nothing.
    test "SWAR round trip with the setting off: the rounds before joining stay worth nothing" do
      %{t: t, late: late} = event(%{late_entry_absences: false}, late: %{start_round: 4})
      {:ok, _} = Tournaments.update_player(late, %{absent_rounds: "4"})
      pair_and_play!(t)

      # His round-4 absence is his first: paid.
      assert_score(t, late, 0.5)

      {copy, copy_late} = swar_round_trip(t, late)
      assert_score(copy, copy_late, 0.5)
    end

    test "SWAR round trip: a regular who withdrew keeps his score" do
      %{t: t, regulars: [a, b, c, d, e, f]} = event(%{}, played: 2)
      {:ok, f} = Tournaments.update_player(f, %{status: "withdrawn"})

      r3 = round!(t, 3)
      board!(r3, 1, a, b, "1-0")
      board!(r3, 2, c, d, "1-0")
      board!(r3, 3, e, nil, "bye")

      before = entry(t, f).points
      assert_score(t, f, before)

      {copy, copy_f} = swar_round_trip(t, f)
      assert_score(copy, copy_f, before)
    end
  end

  defp swar_round_trip(t, player) do
    path = Path.join(System.tmp_dir!(), "late_edge_#{System.unique_integer([:positive])}.swar")
    File.write!(path, SwarExport.export(t.id))
    on_exit(fn -> File.rm(path) end)

    assert {:ok, copy, _warnings} = SwarImport.import_file(path)
    copy = copy |> fresh() |> Ecto.Changeset.change(publish_mode: "immediate") |> Repo.update!()

    copy_player =
      Repo.one!(from p in Player, where: p.tournament_id == ^copy.id and p.name == ^player.name)

    {copy, copy_player}
  end

  describe "categories ranked separately" do
    test "the late entrant's category ranking carries the same score" do
      %{t: t, late: late} =
        event(
          %{
            categories_enabled: true,
            categories: ["A", "B"],
            categories_ranked_separately: true
          },
          late: %{category: "B"}
        )

      {:ok, _} = Tournaments.update_player(late, %{absent_rounds: "4"})
      pair_and_play!(t)

      assert_score(t, late, 1.5)
    end
  end

  ## ---------- helpers ----------

  defp user_scope do
    user =
      Repo.insert!(%PairingsEngine.Accounts.User{
        email: "late-edge#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    PairingsEngine.Accounts.Scope.for_user(user)
  end
end
