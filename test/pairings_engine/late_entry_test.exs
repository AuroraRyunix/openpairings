defmodule PairingsEngine.LateEntryTest do
  # "Rounds before a late entrant joins count as absences" - one rule, and
  # every place a score or a round's result is derived has to agree on it.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{LateEntry, Pairing, Repo, Snapshot, Standings, Tournaments, TrfExport}
  alias PairingsEngine.Federations.BEL.{SwarExport, SwarImport}
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}

  @dates for day <- 1..9, do: "2026-03-0#{day}"

  # Four regulars play rounds 1-3; "Late" is added before round 4. Half a
  # point per absence, three absences paid, through round 9 - the user's
  # own setup.
  defp setup_event(attrs \\ %{}) do
    tournament =
      Repo.insert!(
        struct(
          %Tournament{
            name: "Late entry",
            type: "swiss",
            pairing_system: "swiss",
            rounds_count: 9,
            round_dates: @dates,
            tiebreaks: [],
            abs_value: 0.5,
            abs_nbfois: 3,
            abs_jusque: 9,
            publish_mode: "manual",
            public_slug: "late-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    [a, b, c, d] =
      for {name, no} <- [{"Anna", 1}, {"Bert", 2}, {"Cor", 3}, {"Dirk", 4}] do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: name,
          pairing_number: no,
          fide_rating: 2100 - no
        })
      end

    for n <- 1..3 do
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: n, status: "finished"})
      pairing!(round, 1, a, b, "1-0")
      pairing!(round, 2, c, d, "1/2-1/2")
    end

    late =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Late Entrant",
        pairing_number: 5,
        fide_rating: 1500,
        start_round: 4
      })

    %{tournament: tournament, late: late, players: [a, b, c, d]}
  end

  defp pairing!(round, board, white, black, result) do
    Repo.insert!(%PairingsEngine.Tournaments.Pairing{
      round_id: round.id,
      board: board,
      white_player_id: white.id,
      black_player_id: black && black.id,
      result: result
    })
  end

  defp round!(tournament, number),
    do: Repo.insert!(%Round{tournament_id: tournament.id, number: number, status: "finished"})

  defp absent!(tournament, player, round) do
    Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: player.id, round: round, type: "absent"}
    ])
  end

  defp points(tournament, player) do
    tournament
    |> Standings.standings()
    |> Enum.find(&(&1.player.id == player.id))
    |> Map.fetch!(:points)
  end

  defp games(tournament, player) do
    tournament
    |> Standings.standings()
    |> Enum.find(&(&1.player.id == player.id))
    |> Map.fetch!(:games)
  end

  describe "the user's case: ½ per absence, three paid, until round 9, joined in round 4" do
    test "1.5 points after round 3, and no absences left" do
      %{tournament: t, late: late} = setup_event()

      assert points(t, late) == 1.5
      assert LateEntry.note(t, 4) == "Rounds 1-3 count as absences: 1.5 points, no absences left."
    end

    test "rounds 1-3 are absences in the crosstable, not blanks" do
      %{tournament: t, late: late} = setup_event()

      rounds = t |> games(late) |> Enum.sort_by(& &1.round)
      assert Enum.map(rounds, & &1.round) == [1, 2, 3]
      assert Enum.all?(rounds, &(&1.bye_type == "absent" and &1.late_entry))
      assert Enum.all?(rounds, &(&1.points == 0.5))

      assert Enum.map(rounds, &PairingsEngine.PlayerCard.result_label(&1, t)) ==
               List.duplicate("½ bye", 3)
    end

    test "a later absence in round 5 pays nothing: the allowance is used up" do
      %{tournament: t, late: late, players: [a, b, c, d]} = setup_event()

      r4 = round!(t, 4)
      pairing!(r4, 1, late, a, "0-1")
      pairing!(r4, 2, b, c, "1-0")
      pairing!(r4, 3, d, nil, "bye")

      r5 = round!(t, 5)
      pairing!(r5, 1, a, b, "1-0")
      pairing!(r5, 2, c, d, "1-0")
      absent!(t, late, 5)

      assert points(t, late) == 1.5

      # What a page shows for that row agrees - with and without the counts.
      counts = Standings.absent_counts(t)
      row = %{player_id: late.id, round: 5, type: "absent"}
      assert Standings.bye_points_for_row(row, t, counts) == 0.0
      assert Standings.bye_points_for_row(row, t) == 0.0
    end

    test "the pairing input carries the same score" do
      %{tournament: t, late: late} = setup_event()
      players = Tournaments.list_players(t.id)

      row = t |> Pairing.trf_player_rows(players) |> Enum.find(&(&1.id == late.id))
      assert row.points == 1.5
      assert Enum.map(row.games, & &1.result) == ~w(Z Z Z)
    end
  end

  describe "the caps and the setting" do
    test "the last round an absence pays cuts the rounds before joining off too" do
      %{tournament: t, late: late} = setup_event(%{abs_jusque: 2, abs_nbfois: nil})

      assert points(t, late) == 1.0
      assert LateEntry.note(t, 4) == "Rounds 1-3 count as absences: 1 point."
    end

    test "fewer rounds than the allowance leave some over" do
      %{tournament: t, late: late} = setup_event()
      {:ok, late} = Tournaments.update_player(late, %{start_round: 2})

      assert points(t, late) == 0.5
      assert LateEntry.note(t, 2) == "Round 1 counts as an absence: 0.5 points, 2 absences left."
    end

    test "with the setting off, the rounds before joining score nothing and use nothing" do
      %{tournament: t, late: late, players: [a, b, c, d]} =
        setup_event(%{late_entry_absences: false})

      assert points(t, late) == 0.0
      assert games(t, late) == []

      r4 = round!(t, 4)
      pairing!(r4, 1, a, b, "1-0")
      pairing!(r4, 2, c, d, "1-0")
      absent!(t, late, 4)

      # Their own first absence is their first: paid.
      assert points(t, late) == 0.5

      assert LateEntry.note(t, 4) ==
               "Rounds 1-3 are before this player joins and score nothing."
    end

    test "a FIDE event without absence points is unchanged" do
      %{tournament: t, late: late} =
        setup_event(%{abs_value: nil, abs_nbfois: nil, abs_jusque: nil})

      refute LateEntry.applies?(t)
      assert points(t, late) == 0.0
      assert games(t, late) == []

      players = Tournaments.list_players(t.id)
      row = t |> Pairing.trf_player_rows(players) |> Enum.find(&(&1.id == late.id))
      assert row.points == 0.0
    end

    test "Keizer, round robin and team events are left alone" do
      refute LateEntry.applies?(%Tournament{
               abs_value: 0.5,
               pairing_system: "keizer",
               type: "swiss"
             })

      refute LateEntry.applies?(%Tournament{
               abs_value: 0.5,
               pairing_system: "round_robin",
               type: "swiss"
             })

      refute LateEntry.applies?(%Tournament{
               abs_value: 0.5,
               pairing_system: "swiss",
               type: "team-swiss"
             })

      assert LateEntry.applies?(%Tournament{
               abs_value: 0.5,
               pairing_system: "swiss",
               type: "swiss"
             })
    end

    test "changing the start round rescores at once, both ways" do
      %{tournament: t, late: late} = setup_event()

      {:ok, late} = Tournaments.update_player(late, %{start_round: 3})
      assert points(t, late) == 1.0

      {:ok, late} = Tournaments.update_player(late, %{start_round: 1})
      assert points(t, late) == 0.0

      {:ok, late} = Tournaments.update_player(late, %{start_round: 4})
      assert points(t, late) == 1.5
    end

    test "a round they were seated in, or have a row for, is theirs" do
      %{tournament: t, late: late} = setup_event()

      Repo.insert_all("byes", [
        %{tournament_id: t.id, player_id: late.id, round: 2, type: "requested-half"}
      ])

      # Round 2 is their own half-point bye; rounds 1 and 3 are absences.
      assert points(t, late) == 1.5
      assert t |> games(late) |> Enum.count(&(&1.bye_type == "absent")) == 2
    end

    test "an absence entered for a round before joining is covered, or said to be ignored" do
      %{tournament: t} = setup_event()

      assert LateEntry.note(t, 4, "2") ==
               "Rounds 1-3 count as absences: 1.5 points, no absences left. " <>
                 "The absence entered for round 2 is already one of them."

      off = %{t | late_entry_absences: false}

      assert LateEntry.note(off, 4, "2,5") ==
               "Rounds 1-3 are before this player joins and score nothing. " <>
                 "The absence entered for round 2 is before this player joins, so it is not counted."
    end

    test "nothing to say for a player starting in round 1" do
      %{tournament: t} = setup_event()
      assert LateEntry.note(t, 1) == nil
    end
  end

  describe "a player added after rounds were paired" do
    test "is offered the next round, and keeps whatever start round is given" do
      %{tournament: t} = setup_event()

      assert Tournaments.next_start_round(t.id) == 4

      # Never a hidden default: the add form shows the offer, and a player
      # added any other way starts where they are told to.
      {:ok, added} = Tournaments.create_player(t.id, %{name: "Newcomer"})
      assert added.start_round == 1

      {:ok, chosen} = Tournaments.create_player(t.id, %{"name" => "Chosen", "start_round" => "2"})
      assert chosen.start_round == 2

      {:ok, blank} = Tournaments.create_player(t.id, %{"name" => "Blank", "start_round" => ""})
      assert blank.start_round == 1
    end

    test "is offered round 1 before anything is paired" do
      tournament = Repo.insert!(%Tournament{name: "Fresh", type: "swiss", rounds_count: 5})
      assert Tournaments.next_start_round(tournament.id) == 1
    end

    test "a player with nothing in the first rounds is pointed at the right start round" do
      %{tournament: t} = setup_event()

      {:ok, added} =
        Tournaments.create_player(t.id, %{"name" => "Old style", "start_round" => "1"})

      assert LateEntry.unrecorded_leading_rounds(added, t.id) == 3

      %{late: late} = %{late: Repo.get!(Player, added.id)}
      {:ok, late} = Tournaments.update_player(late, %{start_round: 4})
      assert LateEntry.unrecorded_leading_rounds(late, t.id) == 0
    end
  end

  describe "exports" do
    test "the TRF report's 001 total adds up with the rounds before joining" do
      %{tournament: t} = setup_event()

      {:ok, text} = TrfExport.export(t)

      line =
        text
        |> String.split(["\r\n", "\n"])
        |> Enum.find(&(String.starts_with?(&1, "001") and &1 =~ "Late Entrant"))

      assert line |> String.slice(80, 4) |> String.trim() == "1.5"
      assert length(Regex.scan(~r/0000 - Z/, line)) == 3
    end

    test "the SWAR file keeps the rounds before joining as SWAR's own absences" do
      %{tournament: t} = setup_event()

      {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
      late = Enum.find(parsed.players, &(&1.name == "Late Entrant"))

      assert Enum.map(late.rounds, &{&1.round_nr, &1.table, &1.advers, &1.result}) == [
               {1, 0x4000, -1, 0},
               {2, 0x4000, -1, 0},
               {3, 0x4000, -1, 0}
             ]

      # SWAR's quarter points: 1.5.
      assert late.points == 6
    end

    test "with the setting off the SWAR file writes them as not played" do
      %{tournament: t} = setup_event(%{late_entry_absences: false})

      {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
      late = Enum.find(parsed.players, &(&1.name == "Late Entrant"))

      assert Enum.map(late.rounds, &{&1.round_nr, &1.table}) == [{1, 0}, {2, 0}, {3, 0}]
      assert late.points == 0
    end

    test "the results site gets each round's absence with its points, adding up to the standings" do
      %{tournament: t, late: late} = setup_event()

      for n <- 1..3 do
        {:ok, _} = Tournaments.publish_round_now(Tournaments.get_round(t.id, n))
      end

      {:ok, t} = Tournaments.publish_standings_through(Tournaments.get_tournament!(t.id), 3)
      snapshot = Snapshot.build(t)

      per_round =
        for round <- snapshot["rounds"],
            bye <- round["byes"],
            bye["player"] == late.pairing_number,
            do: {round["number"], bye["kind"], bye["points"]}

      assert Enum.sort(per_round) == [{1, "absent", 0.5}, {2, "absent", 0.5}, {3, "absent", 0.5}]

      row = Enum.find(snapshot["standings"]["rows"], &(&1["player"] == late.pairing_number))
      assert row["points"] == 1.5
    end
  end
end
