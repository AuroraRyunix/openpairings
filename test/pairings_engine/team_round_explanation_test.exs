defmodule PairingsEngine.TeamRoundExplanationTest do
  @moduledoc """
  A team Swiss round keeps the team engine's account of how it was paired -
  the bye, the brackets and upfloaters, the colour criteria - and the
  rationale page shows it.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Repo, TeamRoundExplanation, TeamSwiss, Tournaments}
  alias Ainalrami.TeamPairing.Team, as: EngineTeam
  alias PairingsEngine.Tournaments.Match

  defp teams(n), do: for(i <- 1..n, do: {"T#{i}", [2000 - i * 10, 1990 - i * 10]})

  # Team A wins every board: White on the odd boards, Black on the even ones.
  defp team_a_wins!(t, number) do
    Tournaments.get_round(t.id, number).pairings
    |> Enum.each(fn p ->
      result = if rem(p.board, 2) == 1, do: "1-0", else: "0-1"
      {:ok, _} = Tournaments.update_pairing_result(p, result)
    end)
  end

  defp names(teams), do: Enum.map(teams, & &1.name)

  test "round 1 of an odd field: every team, the bye, the brackets and the colours" do
    {t, _} = team_swiss(teams(5), rounds: 4)
    round = pair_next!(t)
    teams = Tournaments.list_teams(t.id)

    assert %{"kind" => "team_swiss", "version" => 2} = round.explanation
    account = TeamRoundExplanation.for_round(round, teams)
    assert account.reasons?

    assert account.teams |> Enum.map(& &1.team.name) == ~w(T1 T2 T3 T4 T5)
    assert Enum.all?(account.teams, &(&1.match_points == 0.0 and &1.colours == []))

    # 3.4, as the engine reported it: nobody passed over, T5 ahead of T4 on
    # the higher number.
    bye_match = round.id |> Tournaments.list_matches() |> Enum.find(&is_nil(&1.team_b_id))
    assert account.bye.team.id == bye_match.team_a_id
    assert account.bye.team.name == "T5"
    assert account.bye.passed_over == []
    assert account.bye.ineligible == []
    assert {account.bye.next.team.name, account.bye.decided_by} == {"T4", "3.4.4"}

    # One bracket at 0 points, its pairs the round's matches; nothing floats,
    # which the engine reports as [C4].
    assert [%{score: +0.0, upfloaters: [], exhaustive?: true} = bracket] = account.brackets
    assert names(bracket.residents) == ~w(T1 T2 T3 T4)
    assert %{c4: 0, decided_by: "C4", runner_up: nil} = bracket.selection

    # Round 1: nobody has played, so every board-1 colour is 4.3.1's.
    assert Enum.all?(account.pairs, &(&1.colour_rule == "4.3.1"))
    assert Enum.all?(account.pairs, &(&1.first_team_rule == "4.2.3"))

    played =
      round.id
      |> Tournaments.list_matches()
      |> Enum.reject(&is_nil(&1.team_b_id))
      |> MapSet.new(&MapSet.new([&1.team_a_id, &1.team_b_id]))

    assert MapSet.new(account.pairs, &MapSet.new([&1.white.id, &1.black.id])) == played

    assert TeamRoundExplanation.divergence(round, Tournaments.list_matches(round.id)) ==
             :unchanged
  end

  test "a team that had the bye is recorded as not eligible, and the score groups show upfloaters" do
    {t, _} = team_swiss(teams(5), rounds: 4)
    pair_next!(t)

    team_a_wins!(Repo.reload!(t), 1)
    round2 = pair_next!(t)
    account = TeamRoundExplanation.for_round(round2, Tournaments.list_teams(t.id))

    assert [%{team: %{name: "T5"}, reasons: [:had_bye]}] = account.bye.ineligible
    assert account.bye.team.name != "T5"

    t5 = Enum.find(account.teams, &(&1.team.name == "T5"))
    assert t5.had_bye?
    assert t5.match_points == 1.0

    # Scores 2, 2, 1 (the bye) and 0, 0: an odd top group takes an upfloater.
    assert Enum.any?(account.brackets, &(&1.upfloaters != []))
    assert Enum.all?(account.brackets, &is_integer(&1.candidates))

    # Each bracket's chosen set is its upfloaters, with the engine's reason.
    for b <- account.brackets do
      assert Enum.map(b.selection.chosen.upfloaters, & &1.id) == Enum.map(b.upfloaters, & &1.id)
      assert b.selection.decided_by in ["C4", "C5", "C6", "C7", "3.5.4"]
    end

    assert Enum.all?(account.pairs, &(&1.colour_rule =~ ~r/^4\.3\.\d$/))
  end

  test "a match changed afterwards is reported as a divergence" do
    {t, _} = team_swiss(teams(4), rounds: 3)
    round = pair_next!(t)
    [m1, m2] = Tournaments.list_matches(round.id)

    # Swap one team of each match.
    Repo.update_all(from(m in Match, where: m.id == ^m1.id), set: [team_b_id: m2.team_b_id])
    Repo.update_all(from(m in Match, where: m.id == ^m2.id), set: [team_b_id: m1.team_b_id])

    assert {:changed, 2} =
             TeamRoundExplanation.divergence(round, Tournaments.list_matches(round.id))
  end

  test "a round with no stored account reads as none" do
    {t, _} = team_swiss(teams(4), rounds: 3)
    round = pair_next!(t)
    round = round |> Ecto.Changeset.change(explanation: nil) |> Repo.update!()

    assert TeamRoundExplanation.for_round(round, Tournaments.list_teams(t.id)) == nil
    assert TeamRoundExplanation.divergence(round, []) == :no_record
  end

  test "the bye account is the engine's: passed over for 3.4.1 only when the engine found so" do
    # 1, 2 and 3 have met each other and 6, and 6 may not take the bye. Only
    # 4, 5 and 7 can partner 1, 2 and 3, so byeing 7, 5 or 4 - the first
    # three in 3.4.2-3.4.4's order - strands one of them. 3 is the first
    # that does not.
    teams = [
      %EngineTeam{tpn: 1, opponents: [2, 3, 6]},
      %EngineTeam{tpn: 2, opponents: [1, 3, 6]},
      %EngineTeam{tpn: 3, opponents: [1, 2, 6]},
      %EngineTeam{tpn: 4},
      %EngineTeam{tpn: 5},
      %EngineTeam{tpn: 6, opponents: [1, 2, 3], had_pab?: true, won_by_forfeit?: true},
      %EngineTeam{tpn: 7}
    ]

    opts = [round: 2, expected_rounds: 4, explain: true]
    {:ok, result} = Ainalrami.TeamPairing.pair_round(teams, opts)
    account = TeamSwiss.explanation(result, teams, [], [], opts)

    assert account["version"] == 2
    assert account["bye"]["tpn"] == 3

    assert account["bye"]["ineligible"] == [
             %{"tpn" => 6, "reasons" => ["had_bye", "won_by_forfeit"]}
           ]

    assert Enum.map(account["bye"]["passed_over"], & &1["tpn"]) == [7, 5, 4]
    assert account["bye"]["next"]["tpn"] == 2
    assert account["bye"]["decided_by"] == "3.4.4"
    assert Enum.all?(account["pairs"], &is_binary(&1["colour_rule"]))
  end

  test "a result without the engine's reasons is stored as version 1, and reads with the note's shape" do
    teams = [%EngineTeam{tpn: 1}, %EngineTeam{tpn: 2}, %EngineTeam{tpn: 3}]
    {:ok, result} = Ainalrami.TeamPairing.pair_round(teams)
    account = TeamSwiss.explanation(result, teams, [], [], round: 1, expected_rounds: 3)

    assert account["version"] == 1
    assert account["bye"] == %{"tpn" => 3}
    assert Enum.all?(account["brackets"], &is_nil(&1["selection"]))
  end

  test "a version 1 account - a round paired before the engine reported reasons - still reads" do
    {t, _} = team_swiss(teams(5), rounds: 4)
    round = pair_next!(t)
    teams = Tournaments.list_teams(t.id)
    ids = Map.new(teams, &{Integer.to_string(&1.pairing_number), &1.id})

    # The shape TeamSwiss stored before version 2, OpenPairings' own labels
    # included.
    v1 = %{
      "kind" => "team_swiss",
      "version" => 1,
      "team_ids" => ids,
      "teams" => [],
      "bye" => %{
        "tpn" => 5,
        "ineligible" => [%{"tpn" => 1, "reason" => "won_by_forfeit"}],
        "candidates" => [
          %{"tpn" => 4, "match_points" => 0.0, "matches_played" => 0, "outcome" => "passed_over"},
          %{"tpn" => 5, "match_points" => 0.0, "matches_played" => 0, "outcome" => "chosen"}
        ]
      },
      "brackets" => [
        %{
          "score" => 0.0,
          "residents" => [1, 2, 3, 4],
          "upfloaters" => [],
          "pairs" => [[1, 3], [2, 4]],
          "c8" => 0,
          "c9" => 0,
          "c10" => 0,
          "candidates" => 1,
          "exhaustive" => true
        }
      ],
      "pairs" => [%{"white" => 1, "black" => 3, "first_team" => 1, "score_difference" => 0.0}]
    }

    round = round |> Ecto.Changeset.change(explanation: v1) |> Repo.update!()
    account = TeamRoundExplanation.for_round(round, teams)

    refute account.reasons?
    assert [%{reasons: [:won_by_forfeit]}] = account.bye.ineligible
    assert [%{team: %{name: "T4"}, matches_played: 0}] = account.bye.passed_over
    assert {account.bye.next, account.bye.decided_by} == {nil, nil}
    assert [%{selection: nil}] = account.brackets
    assert [%{colour_rule: nil, first_team_rule: nil}] = account.pairs
  end
end
