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
