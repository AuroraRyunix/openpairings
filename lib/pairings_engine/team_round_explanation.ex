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

      %{reasons?: bool,
        teams: [%{team, tpn, match_points, game_points, colours, preference,
                  had_bye?, won_by_forfeit?, floated_last_round?, opponents}],
        bye: nil | %{team, match_points, matches_played,
                  ineligible: [%{team, reasons: [:had_bye | :won_by_forfeit]}],
                  ineligible_omitted, passed_over: [%{team, match_points,
                  matches_played}], passed_over_omitted, next: nil | %{team,
                  match_points, matches_played}, decided_by},
        brackets: [%{score, residents, upfloaters, pairs: [{team, team}], c8,
                  c9, c10, candidates, exhaustive?, selection: nil | selection}],
        pairs: [%{white, black, first_team, first_team_rule, colour_rule,
                  score_difference}],
        absent: [team], last_round?: bool, last_two_rounds?: bool}

      selection = %{c4, sizes_without_legal_set, chosen: set, runner_up: nil | set,
                    decided_by, considered: [set], considered_omitted,
                    rejected: [%{upfloaters: [team], c4, c5, failed}],
                    rejected_omitted}
      set       = %{upfloaters: [team], c4, c5: [score], c6, c7}

  `reasons?` is true for an account that carries the engine's own reasons
  (version 2: the bye's 3.4 walk, each bracket's `selection`, each pair's
  Article 4 rules). A version 1 account - a round paired before Ainalrami
  reported them - reads with `selection`, the rules, `next` and `decided_by`
  nil, and its bye's passed-over teams as they were stored then.

  A team is `%Team{}` when it still exists, else `%{name: "#n"}`.
  """
  def for_round(%{explanation: %{"kind" => "team_swiss"} = account}, teams) do
    by_id = Map.new(teams, &{&1.id, &1})
    ids = account["team_ids"] || %{}
    team = fn tpn -> resolve(tpn, ids, by_id) end

    %{
      reasons?: (account["version"] || 1) >= 2,
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
            exhaustive?: b["exhaustive"] == true,
            selection: selection(b["selection"], team)
          }
        end,
      pairs:
        for p <- account["pairs"] || [] do
          %{
            white: team.(p["white"]),
            black: team.(p["black"]),
            first_team: team.(p["first_team"]),
            first_team_rule: p["first_team_rule"],
            colour_rule: p["colour_rule"],
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

  # Version 2: the engine's 3.4 walk, stored as it reported it.
  defp bye(%{"passed_over" => passed} = b, team) do
    %{
      team: team.(b["tpn"]),
      match_points: b["match_points"],
      matches_played: b["matches_played"],
      ineligible:
        for i <- b["ineligible"] || [] do
          %{team: team.(i["tpn"]), reasons: Enum.map(i["reasons"] || [], &reason/1)}
        end,
      ineligible_omitted: b["ineligible_omitted"] || 0,
      passed_over: Enum.map(passed, &bye_team(&1, team)),
      passed_over_omitted: b["passed_over_omitted"] || 0,
      next: b["next"] && bye_team(b["next"], team),
      decided_by: b["decided_by"]
    }
  end

  # Version 1: the eligible teams in 3.4.2-3.4.4's order up to the bye, with
  # "passed over" as OpenPairings labelled them at the time. Shown as stored.
  defp bye(b, team) do
    candidates = b["candidates"] || []
    chosen = Enum.find(candidates, &(&1["outcome"] == "chosen")) || %{}

    %{
      team: team.(b["tpn"]),
      match_points: chosen["match_points"],
      matches_played: chosen["matches_played"],
      ineligible:
        for i <- b["ineligible"] || [] do
          %{team: team.(i["tpn"]), reasons: [reason(i["reason"])]}
        end,
      ineligible_omitted: 0,
      passed_over:
        candidates |> Enum.reject(&(&1["outcome"] == "chosen")) |> Enum.map(&bye_team(&1, team)),
      passed_over_omitted: 0,
      next: nil,
      decided_by: nil
    }
  end

  defp bye_team(t, team) do
    %{team: team.(t["tpn"]), match_points: t["match_points"], matches_played: t["matches_played"]}
  end

  defp reason("had_bye"), do: :had_bye
  defp reason(_), do: :won_by_forfeit

  defp selection(nil, _team), do: nil

  defp selection(s, team) do
    %{
      c4: s["c4"],
      sizes_without_legal_set: s["sizes_without_legal_set"] || [],
      chosen: set(s["chosen"], team),
      runner_up: s["runner_up"] && set(s["runner_up"], team),
      decided_by: s["decided_by"],
      considered: Enum.map(s["considered"] || [], &set(&1, team)),
      considered_omitted: s["considered_omitted"] || 0,
      rejected:
        for r <- s["rejected"] || [] do
          %{
            upfloaters: Enum.map(r["upfloaters"] || [], team),
            c4: r["c4"],
            c5: r["c5"] || [],
            failed: r["failed"]
          }
        end,
      rejected_omitted: s["rejected_omitted"] || 0
    }
  end

  defp set(s, team) do
    %{
      upfloaters: Enum.map(s["upfloaters"] || [], team),
      c4: s["c4"],
      c5: s["c5"] || [],
      c6: s["c6"],
      c7: s["c7"]
    }
  end

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
