defmodule PairingsEngineWeb.TeamMatchesLiveTest do
  @moduledoc """
  The Pairings page's team-match actions: forfeiting a match by decision and
  withdrawing it, and boards that belong to no match.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Audit, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Match, Player}

  setup :register_and_log_in_user

  defp teams(n), do: for(i <- 1..n, do: {"T#{i}", [2000 - i * 10, 1990 - i * 10]})

  test "forfeit a match to a team, then withdraw the decision", %{conn: conn, scope: scope} do
    {t, _} = team_swiss(teams(4), user_id: scope.user.id)
    pair_next!(t)
    t = Repo.reload!(t)
    enter!(t, 1, "T1", "T3", ["1-0", "1/2-1/2"])
    {match, _} = match_between(t, 1, "T1", "T3")
    t3 = t.id |> Tournaments.list_teams() |> Enum.find(&(&1.name == "T3"))

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    button = "#team-match-#{match.id} button[phx-value-team-id='#{t3.id}']"
    assert has_element?(lv, button)
    assert lv |> element(button) |> render() =~ "Forfeit match 1 to T3"

    lv |> element(button) |> render_click()

    assert Repo.reload!(match).forfeited_to_team_id == t3.id
    assert has_element?(lv, "#match-decision-#{match.id}", "Forfeited to T3 by decision")
    assert Enum.any?(Audit.list_for_tournament(t.id), &(&1.action == "pairing.match_forfeited"))

    lv
    |> element("#team-match-#{match.id} button[phx-click='withdraw_match_forfeit']")
    |> render_click()

    assert Repo.reload!(match).forfeited_to_team_id == nil
    refute has_element?(lv, "#match-decision-#{match.id}")

    results =
      Tournaments.get_round(t.id, 1).pairings
      |> Enum.filter(&(&1.match_id == match.id))
      |> Enum.sort_by(& &1.board)
      |> Enum.map(& &1.result)

    assert results == ["1-0", "1/2-1/2"]
  end

  test "a board outside every match is marked and can be attached", %{conn: conn, scope: scope} do
    {t, _} =
      team_round_robin([{"A", [2100, 2000, 1900]}, {"B", [2050, 1950, 1850]}],
        boards: 3,
        rounds_count: 1,
        user_id: scope.user.id
      )

    out =
      Repo.all(from p in Player, where: p.tournament_id == ^t.id and p.name in ["A 3", "B 3"])

    Enum.each(out, &(&1 |> Ecto.Changeset.change(absent: true) |> Repo.update!()))
    t = pair_all!(t)

    Enum.each(
      out,
      &(&1 |> Repo.reload!() |> Ecto.Changeset.change(absent: false) |> Repo.update!())
    )

    [a3, b3] = Enum.sort_by(out, & &1.name)
    round = Tournaments.get_round(t.id, 1)
    # Wrong colours: B's player has White on board 3.
    {:ok, outside} = Tournaments.pair_from_pool(round, b3.id, a3.id, 5)

    {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/pairings")
    assert has_element?(lv, "#unattached-boards")
    assert html =~ "not part of a match: it counts for no team"
    assert has_element?(lv, "#pairing-row-#{outside.id} .badge", "no team")

    lv |> element("#unattached-board-#{outside.id} button") |> render_click()

    moved = Repo.reload!(outside)
    assert moved.board == 3
    assert moved.match_id == Repo.one!(from m in Match, where: m.round_id == ^round.id).id
    refute has_element?(lv, "#unattached-boards")
  end
end
