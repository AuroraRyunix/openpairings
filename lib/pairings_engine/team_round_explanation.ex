defmodule PairingsEngine.TeamRoundExplanation do
  @moduledoc """
  Reads back the account `PairingsEngine.TeamSwiss.explanation/5` stored on a
  team Swiss round, with pairing numbers resolved to teams - the team
  counterpart of `PairingsEngine.RoundExplanation`.

  Presentation of a record only: nothing is recomputed. A round whose
  matches were changed afterwards (a TRF import rebuilds matches but records
  no account; a restore drops it) says so through `divergence/2`.
  """

  alias PairingsEngine.Tournaments.Team

  @doc """
  The stored account with teams resolved, or nil when the round has none.

      %{teams: [%{team, tpn, match_points, game_points, colours, preference,
                  had_bye?, won_by_forfeit?, floated_last_round?, opponents}],
        bye: nil | %{team, ineligible: [%{team, reason}], candidates: [%{team,
                  match_points, matches_played, outcome}]},
        brackets: [%{score, residents, upfloaters, pairs: [{team, team}], c8,
                  c9, c10, candidates, exhaustive?}],
        pairs: [%{white, black, first_team, score_difference}],
        absent: [team], last_round?: bool, last_two_rounds?: bool}

  A team is `%Team{}` when it still exists, else `%{name: "#n"}`.
  """
  def for_round(%{explanation: %{"kind" => "team_swiss"} = account}, teams) do
    by_id = Map.new(teams, &{&1.id, &1})
    ids = account["team_ids"] || %{}
    team = fn tpn -> resolve(tpn, ids, by_id) end

    %{
      teams:
        for t <- account["teams"] || [] do
          %{
            team: team.(t["tpn"]),
            tpn: t["tpn"],
            match_points: t["match_points"],
            game_points: t["game_points"],
            colours: t["colours"] || [],
            preference: t["preference"],
            had_bye?: t["had_bye"] == true,
            won_by_forfeit?: t["won_by_forfeit"] == true,
            floated_last_round?: t["floated_last_round"] == true,
            opponents: Enum.map(t["opponents"] || [], team)
          }
        end,
      bye: bye(account["bye"], team),
      brackets:
        for b <- account["brackets"] || [] do
          %{
            score: b["score"],
            residents: Enum.map(b["residents"] || [], team),
            upfloaters: Enum.map(b["upfloaters"] || [], team),
            pairs: Enum.map(b["pairs"] || [], fn [x, y] -> {team.(x), team.(y)} end),
            c8: b["c8"],
            c9: b["c9"],
            c10: b["c10"],
            candidates: b["candidates"],
            exhaustive?: b["exhaustive"] == true
          }
        end,
      pairs:
        for p <- account["pairs"] || [] do
          %{
            white: team.(p["white"]),
            black: team.(p["black"]),
            first_team: team.(p["first_team"]),
            score_difference: p["score_difference"]
          }
        end,
      absent: Enum.map(account["absent"] || [], team),
      last_round?: account["last_round"] == true,
      last_two_rounds?: account["last_two_rounds"] == true
    }
  end

  def for_round(_round, _teams), do: nil

  defp bye(nil, _team), do: nil

  defp bye(b, team) do
    %{
      team: team.(b["tpn"]),
      ineligible:
        for i <- b["ineligible"] || [] do
          %{team: team.(i["tpn"]), reason: reason(i["reason"])}
        end,
      candidates:
        for c <- b["candidates"] || [] do
          %{
            team: team.(c["tpn"]),
            match_points: c["match_points"],
            matches_played: c["matches_played"],
            outcome: if(c["outcome"] == "chosen", do: :chosen, else: :passed_over)
          }
        end
    }
  end

  defp reason("had_bye"), do: :had_bye
  defp reason(_), do: :won_by_forfeit

  defp resolve(tpn, ids, by_id) do
    case Map.get(by_id, Map.get(ids, to_string(tpn))) do
      %Team{} = team -> team
      nil -> %{name: "##{tpn}"}
    end
  end

  @doc """
  Whether the round's matches are still the pairs the account explains:
  `:unchanged`, `{:changed, count}` with the number of explained pairs no
  longer played as a match, or `:no_record`. Colours are not compared - a
  reseated match is the same pairing decision.
  """
  def divergence(%{explanation: %{"kind" => "team_swiss"} = account}, matches) do
    ids = account["team_ids"] || %{}

    explained =
      MapSet.new(account["pairs"] || [], fn p ->
        MapSet.new([Map.get(ids, to_string(p["white"])), Map.get(ids, to_string(p["black"]))])
      end)

    played =
      matches
      |> Enum.reject(&is_nil(&1.team_b_id))
      |> MapSet.new(&MapSet.new([&1.team_a_id, &1.team_b_id]))

    case MapSet.size(MapSet.difference(explained, played)) do
      0 -> :unchanged
      n -> {:changed, n}
    end
  end

  def divergence(_round, _matches), do: :no_record
end
