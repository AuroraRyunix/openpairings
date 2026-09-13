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

    assert %{"kind" => "team_swiss", "version" => 1} = round.explanation
    account = TeamRoundExplanation.for_round(round, teams)

    assert account.teams |> Enum.map(& &1.team.name) == ~w(T1 T2 T3 T4 T5)
    assert Enum.all?(account.teams, &(&1.match_points == 0.0 and &1.colours == []))

    # 3.4: lowest score, most matches played, highest number - T5, nobody passed over.
    bye_match = round.id |> Tournaments.list_matches() |> Enum.find(&is_nil(&1.team_b_id))
    assert account.bye.team.id == bye_match.team_a_id
    assert account.bye.team.name == "T5"
    assert [%{outcome: :chosen}] = account.bye.candidates
    assert account.bye.ineligible == []

    # One bracket at 0 points, its pairs the round's matches.
    assert [%{score: +0.0, upfloaters: [], exhaustive?: true} = bracket] = account.brackets
    assert names(bracket.residents) == ~w(T1 T2 T3 T4)

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

    assert [%{team: %{name: "T5"}, reason: :had_bye}] = account.bye.ineligible
    assert account.bye.team.name != "T5"
    assert List.last(account.bye.candidates).outcome == :chosen

    t5 = Enum.find(account.teams, &(&1.team.name == "T5"))
    assert t5.had_bye?
    assert t5.match_points == 1.0

    # Scores 2, 2, 1 (the bye) and 0, 0: an odd top group takes an upfloater.
    assert Enum.any?(account.brackets, &(&1.upfloaters != []))
    assert Enum.all?(account.brackets, &is_integer(&1.candidates))
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

  test "the bye record's order follows 3.4.2-3.4.4 from the teams the engine was told" do
    teams = [
      %Ainalrami.TeamPairing.Team{tpn: 1, match_points: 2.0, colours: [:white]},
      %Ainalrami.TeamPairing.Team{tpn: 2, match_points: 0.0, colours: [:black], had_pab?: false},
      %Ainalrami.TeamPairing.Team{tpn: 3, match_points: 1.0, had_pab?: true},
      %Ainalrami.TeamPairing.Team{tpn: 4, match_points: 0.0, colours: [:white]}
    ]

    result = %{pairs: [], bye: 2, brackets: []}
    account = TeamSwiss.explanation(result, teams, [], [], round: 2, expected_rounds: 4)

    assert account["bye"]["ineligible"] == [%{"tpn" => 3, "reason" => "had_bye"}]
    # 0 points, one played each: the higher number (4) comes first and was passed over.
    assert Enum.map(account["bye"]["candidates"], &{&1["tpn"], &1["outcome"]}) ==
             [{4, "passed_over"}, {2, "chosen"}]
  end
end
