defmodule PairingsEngineWeb.PrintLiveScheduleTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  defp tournament(scope, attrs) do
    {:ok, t} = Tournaments.create_tournament(scope, Map.merge(%{"name" => "Print RR"}, attrs))
    t
  end

  test "a round robin lists the schedule, with its ticks in the link", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope, %{"type" => "roundrobin", "pairing_system" => "round_robin"})
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/print")

    assert has_element?(lv, "#print-doc-schedule a[href='/t/#{t.id}/print/schedule']")
    assert has_element?(lv, "#print-doc-schedule-schedule_results[checked]")
    refute has_element?(lv, "#print-doc-team-schedule")

    lv |> element("#print-doc-schedule-schedule_results") |> render_click()
    assert has_element?(lv, "#print-doc-schedule a[href='/t/#{t.id}/print/schedule?results=0']")

    lv |> element("#print-doc-schedule-schedule_postponed") |> render_click()

    assert has_element?(
             lv,
             "#print-doc-schedule a[href='/t/#{t.id}/print/schedule?results=0&postponed=0']"
           )

    lv |> element("#print-doc-cards-cards_blank") |> render_click()
    assert has_element?(lv, "#print-doc-cards a[href='/t/#{t.id}/print/cards?blank=1']")
  end

  test "a Swiss has no schedule, but keeps the blank-card tick", %{conn: conn, scope: scope} do
    t = tournament(scope, %{"type" => "swiss"})
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/print")

    refute has_element?(lv, "#print-doc-schedule")
    refute has_element?(lv, "#print-doc-team-schedule")
    assert has_element?(lv, "#print-doc-cards-cards_blank")
  end

  test "a team round robin lists the team schedule and the team sheets", %{
    conn: conn,
    scope: scope
  } do
    {t, _teams} =
      team_round_robin([{"A", [2000, 1900]}, {"B", [1950, 1850]}], user_id: scope.user.id)

    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/print")

    assert has_element?(lv, "#print-doc-team-schedule a[href='/t/#{t.id}/print/team-schedule']")
    assert has_element?(lv, "#print-doc-team-cards a[href='/t/#{t.id}/print/team-cards']")
    refute has_element?(lv, "#print-doc-schedule")

    lv |> element("#print-doc-team-schedule-schedule_boards") |> render_click()

    assert has_element?(
             lv,
             "#print-doc-team-schedule a[href='/t/#{t.id}/print/team-schedule?boards=0']"
           )
  end
end
