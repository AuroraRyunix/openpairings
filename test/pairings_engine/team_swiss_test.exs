defmodule PairingsEngine.TeamSwissTest do
  @moduledoc """
  Team Swiss (C.04.6) end to end: dispatch, the engine's view of the stored
  matches, whole events against the absolute criteria as seen from the
  database, the pairing-allocated bye's points, and C.07 Art. 16 in the team
  tie-breaks.
  """
  # Whole rounds written in sequence; SQLite's single writer.
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Pairing, Repo, TeamStandings, TeamSwiss, Tournaments}
  alias PairingsEngine.Tournaments.{Match, Player, Tournament}

  defp teams(n, boards \\ 2) do
    for i <- 1..n, do: {"T#{i}", Enum.map(1..boards, &(2000 - i * 10 - &1))}
  end

  defp team_ids(t), do: t.id |> Tournaments.list_teams() |> Map.new(&{&1.name, &1})

  # `{team_a_name, team_b_name | :bye}` per match of a round, match order.
  defp round_matches(t, number) do
    round = Tournaments.get_round(t.id, number)
    names = t.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1.name})

    round.id
    |> Tournaments.list_matches()
    |> Enum.map(fn m ->
      {names[m.team_a_id], if(m.team_b_id, do: names[m.team_b_id], else: :bye)}
    end)
  end

  describe "Tournament.paired_as_teams?/1" do
    test "a team round robin, and a team Swiss paired by teams or not yet paired" do
      assert Tournament.paired_as_teams?(%Tournament{
               type: "team-roundrobin",
               pairing_system: "round_robin"
             })

      assert Tournament.paired_as_teams?(%Tournament{type: "team-swiss", pairing_system: "swiss"})

      assert Tournament.paired_as_teams?(%Tournament{
               type: "team-swiss",
               pairing_system: "swiss",
               team_pairing_mode: "teams"
             })
    end

    test "not an old team Swiss paired player by player, and not an individual event" do
      refute Tournament.paired_as_teams?(%Tournament{
               type: "team-swiss",
               pairing_system: "swiss",
               team_pairing_mode: "players"
             })

      refute Tournament.paired_as_teams?(%Tournament{type: "swiss", pairing_system: "swiss"})

      refute Tournament.paired_as_teams?(%Tournament{
               type: "roundrobin",
               pairing_system: "round_robin"
             })

      # A TRF-imported team round robin pairs as a Swiss, player by player.
      refute Tournament.paired_as_teams?(%Tournament{
               type: "team-roundrobin",
               pairing_system: "swiss"
             })
    end
  end

  describe "dispatch" do
    test "a new team Swiss pairs team against team and records it" do
      {t, _} = team_swiss(teams(4))
      round = pair_next!(t)

      assert round.number == 1
      assert round_matches(t, 1) == [{"T1", "T3"}, {"T4", "T2"}]

      t = Repo.reload!(t)
      assert t.team_pairing_mode == "teams"
      assert t.initial_colour_drawn == "white"
      # Four boards, two per match, numbered on through the round.
      assert length(Repo.preload(round, :pairings).pairings) == 4
    end

    test "an old team Swiss paired player by player carries on player by player" do
      {t, _} = team_swiss(teams(4), team_pairing_mode: "players")
      round = pair_next!(t)

      assert Tournaments.list_matches(round.id) == []
      assert length(Repo.preload(round, :pairings).pairings) == 4
      assert Repo.reload!(t).team_pairing_mode == "players"
    end

    test "settle_mode/1 decides a missing mode from what is on the board" do
      {t, _} = team_swiss(teams(4))
      assert TeamSwiss.settle_mode(t).team_pairing_mode == nil

      # Rounds without matches: paired player by player.
      Repo.insert!(%PairingsEngine.Tournaments.Round{
        tournament_id: t.id,
        number: 1,
        status: "playing"
      })

      assert TeamSwiss.settle_mode(t).team_pairing_mode == "players"

      {t2, _} = team_swiss(teams(4))
      pair_next!(t2)
      t2 = t2 |> Repo.reload!() |> Ecto.Changeset.change(team_pairing_mode: nil) |> Repo.update!()
      assert TeamSwiss.settle_mode(t2).team_pairing_mode == "teams"
    end

    test "unpairing everything opens the mode again" do
      {t, _} = team_swiss(teams(4), team_pairing_mode: "players")
      pair_next!(t)
      assert :ok = Pairing.delete_round(t.id, 1)

      assert Repo.reload!(t).team_pairing_mode == nil
      pair_next!(t)
      assert Repo.reload!(t).team_pairing_mode == "teams"
    end

    test "a Black draw gives the first match's other team White on board 1 (4.3.1)" do
      {t, _} = team_swiss(teams(4))
      t |> Tournaments.ensure_initial_colour(fn -> "black" end)
      pair_next!(t)

      assert round_matches(t, 1) == [{"T3", "T1"}, {"T2", "T4"}]
    end

    test "the next round waits for every result" do
      {t, _} = team_swiss(teams(4))
      pair_next!(t)

      assert {:error, "Round 1 still has missing results"} =
               Pairing.pair_next_round(Repo.reload!(t))
    end
  end

  describe "the engine's view of stored matches" do
    # R1: T1-T3 forfeited whole by T3, T4-T2 played. T3 then withdraws.
    defp forfeit_history do
      {t, _} = team_swiss(teams(4), rounds: 3, tiebreaks: ~w(MP GP BH SB EMGSB))
      pair_next!(t)
      assert round_matches(t, 1) == [{"T1", "T3"}, {"T4", "T2"}]

      # T1 is team A: White on board 1, Black on board 2. T3 did not turn up.
      enter!(t, 1, "T1", "T3", ["1-0FF", "0-1FF"])
      enter!(t, 1, "T4", "T2", ["1/2-1/2", "1/2-1/2"])

      withdraw!(t, "T3")
      Repo.reload!(t)
    end

    defp withdraw!(t, name) do
      team = team_ids(t)[name]

      Repo.update_all(from(p in Player, where: p.team_id == ^team.id), set: [status: "withdrawn"])
    end

    defp view(t, number) do
      teams = PairingsEngine.TeamRounds.numbered_teams(t.id)
      {field, _out} = TeamSwiss.split_field(t, teams, number)
      input = TeamSwiss.engine_input(t, teams, field, number)
      {Map.new(input.teams, &{&1.tpn, &1}), input.absent}
    end

    test "colours from team A and B, a forfeited match is no meeting and no colour, and wins by forfeit" do
      t = forfeit_history()
      {by_tpn, absent} = view(t, 2)

      # T3 withdrew after arriving: not in the field, but numbered for 4.3.1.
      assert Map.keys(by_tpn) |> Enum.sort() == [1, 2, 4]
      assert absent == [3]

      t1 = by_tpn[1]
      assert t1.opponents == [], "C.04.2 3.5: a match not played is not a meeting"
      assert t1.colours == [], "C.04.6 1.6.1: only a played match has a colour"
      assert t1.won_by_forfeit?
      assert {t1.match_points, t1.game_points} == {2.0, 2.0}

      assert by_tpn[4].colours == [:white]
      assert by_tpn[2].colours == [:black]
      assert by_tpn[2].opponents == [4]
      refute by_tpn[2].won_by_forfeit?
      assert {by_tpn[2].match_points, by_tpn[2].game_points} == {1.0, 1.0}
    end

    test "open question 6: one game played makes it a played match, not a forfeit win" do
      {t, _} = team_swiss(teams(4), rounds: 3)
      pair_next!(t)
      # T1 wins board 1 over the board; board 2 is forfeited by T3.
      enter!(t, 1, "T1", "T3", ["1-0", "0-1FF"])
      enter!(t, 1, "T4", "T2", ["1-0", "0-1"])

      {by_tpn, _} = view(Repo.reload!(t), 2)

      refute by_tpn[1].won_by_forfeit?
      assert by_tpn[1].opponents == [3]
      assert by_tpn[1].colours == [:white]
    end

    test "the bye, and floats" do
      {t, _} = team_swiss(teams(5), rounds: 4)
      pair_next!(t)
      # Five teams: T5 takes the bye (3.4.4, largest number).
      assert round_matches(t, 1) == [{"T1", "T3"}, {"T4", "T2"}, {"T5", :bye}]
      enter!(t, 1, "T1", "T3", ["1-0", "0-1"])
      enter!(t, 1, "T4", "T2", ["1-0", "0-1"])

      {by_tpn, _} = view(Repo.reload!(t), 2)
      assert by_tpn[5].had_pab?
      assert by_tpn[5].colours == []
      assert {by_tpn[5].match_points, by_tpn[5].game_points} == {1.0, 1.0}
      refute by_tpn[5].floated_last_round?, "a bye has no opponent, so no float"

      pair_next!(t)
      # Round 2: T1 and T4 on 2, T5 on 1, T2 and T3 on 0 - T5 is paired
      # against a team on another score, so both floated.
      round2 = round_matches(t, 2)
      [{a, b}] = Enum.filter(round2, fn {a, b} -> "T5" in [a, b] end)
      other = if a == "T5", do: b, else: a

      for {_m, boards} <- [match_between(t, 2, a, b)], p <- boards do
        {:ok, _} = Tournaments.update_pairing_result(p, "1/2-1/2")
      end

      for {x, y} <- round2, y != :bye, "T5" not in [x, y], do: enter!(t, 2, x, y, ["1-0", "0-1"])

      {by_tpn, _} = view(Repo.reload!(t), 3)
      other_tpn = team_ids(t)[other].pairing_number
      assert by_tpn[5].floated_last_round?
      assert by_tpn[other_tpn].floated_last_round?
    end
  end

  describe "a whole event, checked from the database" do
    test "seven teams, five rounds: [C1], [C2], [C3] every round, and the bye scores a draw" do
      {t, _} = team_swiss(teams(7, 2), rounds: 5, tiebreaks: ~w(MP GP BH SB EMGSB))
      :rand.seed(:exsss, {7, 11, 13})

      for number <- 1..5 do
        pair_next!(t)
        t = Repo.reload!(t)

        matches =
          TeamStandings.matches(t, through_round: number) |> Enum.filter(&(&1.round == number))

        # [C3]: every team exactly once, one bye for seven teams.
        ids =
          Enum.flat_map(
            matches,
            &Enum.reject([&1.team_a_id, &1.team_b_id], fn id -> is_nil(id) end)
          )

        assert Enum.sort(ids) ==
                 t.id |> Tournaments.list_teams() |> Enum.map(& &1.id) |> Enum.sort()

        assert Enum.count(matches, & &1.bye?) == 1

        for m <- matches, not m.bye? do
          {_match, boards} = match_by_id(t, number, m.match_id)

          for p <- boards do
            {:ok, _} = Tournaments.update_pairing_result(p, Enum.random(~w(1-0 0-1 1/2-1/2)))
          end
        end
      end

      all = TeamStandings.matches(Repo.reload!(t))

      # [C1]: no two teams met twice.
      meetings =
        for m <- all, not m.bye?, do: Enum.sort([m.team_a_id, m.team_b_id])

      assert Enum.uniq(meetings) == meetings

      # [C2]: no second bye.
      byes = for m <- all, m.bye?, do: m.team_a_id
      assert Enum.uniq(byes) == byes
      assert length(byes) == 5

      # 1.4: the bye pays a drawn match - 1 match point, a draw on both boards.
      standings = TeamStandings.standings(Repo.reload!(t))

      for id <- byes do
        entry = Enum.find(standings, &(&1.team.id == id))
        bye = Enum.find(entry.records, & &1.bye?)
        assert {bye.mp, bye.gp} == {1.0, 1.0}
      end
    end
  end

  describe "team tie-breaks under C.07 Art. 16" do
    # Three teams, two boards, three rounds, every team one bye. Worked by
    # hand:
    #
    #   R1 T1-T2 2-0, T3 bye     R2 T1-T3 1-1, T2 bye     R3 T3-T2 0-2, T1 bye
    #
    #   team  MP GP  BH                          SB                      EMGSB
    #   T1    4  4   T2 3 + T3 2 + bye 3 = 8     3x2 + 2x1 + 3x1 = 11    3x2 + 2x1 + 3x1 = 11
    #   T2    3  3   T1 4 + bye 3 + T3 2 = 9     4x0 + 3x1 + 2x2 = 7     4x0 + 3x1 + 2x2 = 7
    #   T3    2  2   bye 2 + T1 4 + T2 3 = 9     2x1 + 4x1 + 3x0 = 6     2x1 + 4x1 + 3x0 = 6
    #
    # A bye counts against a dummy whose score is the team's own, capped at a
    # draw's match points times the rounds (16.4.2): T1's 4 is capped at 3.
    test "the pairing-allocated bye as a dummy, capped" do
      {t, _} = team_swiss(teams(3), rounds: 3, tiebreaks: ~w(MP GP BH SB EMGSB))

      pair_next!(t)
      assert round_matches(t, 1) == [{"T1", "T2"}, {"T3", :bye}]
      enter!(t, 1, "T1", "T2", ["1-0", "0-1"])

      pair_next!(t)
      [{x, y}, {"T2", :bye}] = round_matches(t, 2)
      assert Enum.sort([x, y]) == ["T1", "T3"]
      # One board each: a 1-1 draw whichever team is A.
      enter!(t, 2, x, y, ["1-0", "1-0"])

      pair_next!(t)
      [{a, b}, {"T1", :bye}] = round_matches(t, 3)
      assert Enum.sort([a, b]) == ["T2", "T3"]
      t2_white? = a == "T2"
      enter!(t, 3, a, b, if(t2_white?, do: ["1-0", "0-1"], else: ["0-1", "1-0"]))

      e = t |> Repo.reload!() |> TeamStandings.standings() |> Map.new(&{&1.team.name, &1})

      assert {e["T1"].mp, e["T2"].mp, e["T3"].mp} == {4.0, 3.0, 2.0}
      assert {e["T1"].gp, e["T2"].gp, e["T3"].gp} == {4.0, 3.0, 2.0}

      assert {e["T1"].tiebreaks["BH"], e["T2"].tiebreaks["BH"], e["T3"].tiebreaks["BH"]} ==
               {8.0, 9.0, 9.0}

      assert {e["T1"].tiebreaks["SB"], e["T2"].tiebreaks["SB"], e["T3"].tiebreaks["SB"]} ==
               {11.0, 7.0, 6.0}

      assert {e["T1"].tiebreaks["EMGSB"], e["T2"].tiebreaks["EMGSB"], e["T3"].tiebreaks["EMGSB"]} ==
               {11.0, 7.0, 6.0}
    end

    # Four teams, two boards, three rounds.
    #
    #   R1 T1-T3: T3 does not turn up (forfeit win for T1); T4-T2 drawn 1-1.
    #   T3 withdraws.
    #   R2 T1-T2 2-0, T4 bye.   R3 T1-T4 1-1, T2 bye.
    #
    #   MP: T1 5, T2 2, T3 0, T4 3.
    #   T3's R2 and R3 are requested byes followed only by unplayed rounds
    #   (16.2.5), so for its opponents T3 counts 0 + 1 + 1 = 2 (16.3.2).
    #
    #   T1  BH: R1 forfeit win, dummy = min(own 5, T3's adjusted 2) = 2 (16.4.1)
    #           + R2 T2 2 + R3 T4 3 = 7
    #       SB: 2x2 + 2x2 + 3x1 = 11      EMGSB: 2x2 + 2x2 + 3x1 = 11
    #   T2  BH: T4 3 + T1 5 + bye min(2, 1x3) 2 = 10
    #   T3  BH: forfeit loss min(0, 5) 0 + two byes min(0, 3) 0 = 0
    #   T4  BH: T2 2 + bye min(3, 3) 3 + T1 5 = 10
    test "a forfeit win against a team that then withdrew" do
      t = forfeit_history()

      pair_next!(t)

      assert round_matches(t, 2) == [{"T1", "T2"}, {"T4", :bye}] or
               round_matches(t, 2) == [{"T2", "T1"}, {"T4", :bye}]

      [{a, b}, _] = round_matches(t, 2)
      enter!(t, 2, a, b, if(a == "T1", do: ["1-0", "0-1"], else: ["0-1", "1-0"]))

      pair_next!(t)
      [{c, d}, {"T2", :bye}] = round_matches(t, 3)
      assert Enum.sort([c, d]) == ["T1", "T4"]
      enter!(t, 3, c, d, ["1/2-1/2", "1/2-1/2"])

      e = t |> Repo.reload!() |> TeamStandings.standings() |> Map.new(&{&1.team.name, &1})

      assert {e["T1"].mp, e["T2"].mp, e["T3"].mp, e["T4"].mp} == {5.0, 2.0, 0.0, 3.0}
      assert e["T1"].tiebreaks["BH"] == 7.0
      assert e["T1"].tiebreaks["SB"] == 11.0
      assert e["T1"].tiebreaks["EMGSB"] == 11.0
      assert e["T2"].tiebreaks["BH"] == 10.0
      assert e["T3"].tiebreaks["BH"] == 0.0
      assert e["T4"].tiebreaks["BH"] == 10.0

      # Article 16's unplayed rounds are named by what they were.
      kinds = e["T1"].working["BH"] |> Enum.map(& &1.kind)
      assert kinds == [:forfeit_win, :played, :played]

      assert e["T3"].working["BH"] |> Enum.map(& &1.kind) == [:forfeit_loss, :bye, :bye]
    end

    test "a round robin is untouched: no adjustment, and its bye scores nothing" do
      {t, _} = team_round_robin(teams(3), tiebreaks: ~w(MP GP BH))
      t = pair_all!(t)
      e = TeamStandings.standings(t)

      refute Enum.any?(e, &Map.has_key?(&1, :slots))

      for entry <- e, record <- entry.records, record.bye? do
        assert {record.mp, record.gp} == {nil, 0.0}
      end
    end
  end

  defp match_by_id(t, number, match_id) do
    round = Tournaments.get_round(t.id, number)
    match = Repo.get!(Match, match_id)
    boards = round.pairings |> Enum.filter(&(&1.match_id == match.id)) |> Enum.sort_by(& &1.board)
    {match, boards}
  end

  ## ---------- what the arbiter sees when the search gives up ----------
  ##
  ## Forces `:budget_exhausted`, `:no_legal_pairing`, `:no_legal_bye` and a
  ## crash without a 300-500 team event, by swapping in a stub for
  ## `Ainalrami.TeamPairing` through the `:team_pairing_module` seam
  ## (`PairingsEngine.TeamSwiss.team_pairing_module/0`). Also the
  ## no-partial-state guarantee: a refusal or a crash must leave the round
  ## unpaired and the tournament otherwise unchanged.

  defmodule RefusingStub do
    @moduledoc "Always refuses with whatever reason the test put in the process dictionary."
    def pair_round(_teams, _opts), do: {:error, Process.get(:team_swiss_stub_reason)}
  end

  defmodule CrashingStub do
    @moduledoc "Always raises, to force the crash guard."
    def pair_round(_teams, _opts), do: raise("stub engine crash")
  end

  defp with_stub(module, fun) do
    previous = Application.get_env(:pairings_engine, :team_pairing_module)
    Application.put_env(:pairings_engine, :team_pairing_module, module)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:pairings_engine, :team_pairing_module, previous),
        else: Application.delete_env(:pairings_engine, :team_pairing_module)
    end
  end

  describe "pair_next_round/1 when the engine refuses or crashes" do
    for reason <- [:budget_exhausted, :no_legal_pairing, :no_legal_bye] do
      test "#{reason}: the round stays unpaired and the tournament unchanged" do
        reason = unquote(reason)
        {t, _} = team_swiss(teams(4), rounds: 3)
        Process.put(:team_swiss_stub_reason, reason)

        result =
          with_stub(RefusingStub, fn ->
            TeamSwiss.pair_next_round(Repo.reload!(t))
          end)

        assert result == {:error, {:team_pairing, reason, 1}}
        # No round was created - not partial, not silently different.
        assert Tournaments.list_rounds(t.id) == []
        assert Tournament.paired_as_teams?(Repo.reload!(t))
        assert Repo.reload!(t).team_pairing_mode == nil
      end
    end

    test "an unexpected crash is caught, logged without team data, and leaves nothing changed" do
      {t, _} = team_swiss(teams(4), rounds: 3)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          with_stub(CrashingStub, fn -> TeamSwiss.pair_next_round(Repo.reload!(t)) end)
        end)

      assert result == {:error, {:team_pairing, :pairing_crashed, 1}}
      assert Tournaments.list_rounds(t.id) == []

      # Logged - but never a team or player name (the stub raises before any
      # are touched; this also guards against a future stub leaking them).
      assert log =~ "Team pairing crashed for tournament #{t.id} round 1"
      assert log =~ "RuntimeError"
      refute log =~ "T1"
      refute log =~ "T2"
    end

    test "a crash never leaves a half-written round: pairing again afterwards succeeds cleanly" do
      {t, _} = team_swiss(teams(4), rounds: 3)

      with_stub(CrashingStub, fn -> TeamSwiss.pair_next_round(Repo.reload!(t)) end)

      {:ok, round} = TeamSwiss.pair_next_round(Repo.reload!(t))
      assert round.number == 1
      assert length(Tournaments.list_matches(round.id)) == 2
    end
  end
end
