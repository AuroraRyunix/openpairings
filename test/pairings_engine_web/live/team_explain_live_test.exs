defmodule PairingsEngineWeb.TeamExplainLiveTest do
  @moduledoc """
  The pairing rationale page of a team Swiss round shows the team engine's
  account instead of the individual analysis.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Repo, Tournaments}

  setup :register_and_log_in_user

  defp teams(n), do: for(i <- 1..n, do: {"T#{i}", [2000 - i * 10, 1990 - i * 10]})

  test "shows the teams, the bye and the brackets of a team Swiss round", %{
    conn: conn,
    scope: scope
  } do
    {t, _} = team_swiss(teams(5), user_id: scope.user.id)
    pair_next!(t)

    {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    assert has_element?(lv, "#team-account")
    assert has_element?(lv, "#team-account-bye", "T5 had the bye.")
    assert has_element?(lv, "#team-account-bracket-1")
    assert html =~ "Swiss (teams), FIDE C.04.6"

    # The engine's reasons, and no "not recorded" note.
    assert has_element?(
             lv,
             "#team-account-bye-decided",
             "Ahead of T4 in that order on the higher pairing number (3.4.4)."
           )

    assert has_element?(
             lv,
             "#team-account-bracket-1-decided",
             "No upfloaters were needed: the teams on this score pair among themselves ([C4])."
           )

    assert html =~ "4.3.1: neither team has played, so the initial colour by pairing number"
    assert html =~ "4.2.3: smaller pairing number"
    refute has_element?(lv, "#team-account-not-recorded")
  end

  test "a bracket's upfloater sets, the one rejected and what decided", %{
    conn: conn,
    scope: scope
  } do
    {t, _} = team_swiss(teams(5), user_id: scope.user.id)
    round = pair_next!(t)

    # A recorded account with an upfloater choice in it, in the shape the
    # engine's reasons are stored: T3 over T4 on [C7], T5 rejected on [C1].
    set = fn ups, c6, c7 ->
      %{"upfloaters" => ups, "c4" => 1, "c5" => [0.0], "c6" => c6, "c7" => c7}
    end

    selection = %{
      "c4" => 1,
      "sizes_without_legal_set" => [],
      "chosen" => set.([3], 0, 0),
      "runner_up" => set.([4], 0, 1),
      "decided_by" => "C7",
      "considered" => [set.([3], 0, 0), set.([4], 0, 1)],
      "considered_omitted" => 12,
      "rejected" => [%{"upfloaters" => [5], "c4" => 1, "c5" => [0.0], "failed" => "C1"}],
      "rejected_omitted" => 0
    }

    [bracket] = round.explanation["brackets"]
    account = %{round.explanation | "brackets" => [Map.put(bracket, "selection", selection)]}
    round |> Ecto.Changeset.change(explanation: account) |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    assert has_element?(
             lv,
             "#team-account-bracket-1-decided",
             "Chosen over {T4}: fewer of its upfloaters floated last round ([C7])."
           )

    assert has_element?(lv, "#team-account-bracket-1-sets tr", "chosen")
    assert has_element?(lv, "#team-account-bracket-1-sets tr", "next best")
    assert has_element?(lv, "#team-account-bracket-1", "12 more not listed.")

    assert has_element?(
             lv,
             "#team-account-bracket-1-rejected",
             "{T5}: the bracket could not be paired without a repeat meeting ([C1])."
           )
  end

  test "a round paired before the engine reported reasons keeps what it has, with the note", %{
    conn: conn,
    scope: scope
  } do
    {t, _} = team_swiss(teams(5), user_id: scope.user.id)
    round = pair_next!(t)

    v1 =
      round.explanation
      |> Map.put("version", 1)
      |> Map.put("bye", %{
        "tpn" => 5,
        "ineligible" => [],
        "candidates" => [
          %{"tpn" => 5, "match_points" => 0.0, "matches_played" => 0, "outcome" => "chosen"}
        ]
      })
      |> Map.update!("brackets", fn bs -> Enum.map(bs, &Map.delete(&1, "selection")) end)
      |> Map.update!("pairs", fn ps ->
        Enum.map(ps, &Map.drop(&1, ["first_team_rule", "colour_rule"]))
      end)

    round |> Ecto.Changeset.change(explanation: v1) |> Repo.update!()

    {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    assert has_element?(lv, "#team-account-bye", "T5 had the bye.")
    assert has_element?(lv, "#team-account-not-recorded")
    refute has_element?(lv, "#team-account-bye-decided")
    refute has_element?(lv, "#team-account-bracket-1-decided")
    refute html =~ "Colours decided by (4.3)"
  end

  test "says so when a round has no account", %{conn: conn, scope: scope} do
    {t, _} = team_swiss(teams(4), user_id: scope.user.id)
    round = pair_next!(t)
    round |> Ecto.Changeset.change(explanation: nil) |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    assert has_element?(lv, "#team-account-missing")
    refute has_element?(lv, "#team-account")
  end

  test "an unpaired round says there is nothing to explain", %{conn: conn, scope: scope} do
    {t, _} = team_swiss(teams(4), user_id: scope.user.id)
    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")
    assert html =~ "has not been paired yet"
    assert Tournaments.get_round(t.id, 2) == nil
  end
end
