defmodule PairingsEngineWeb.ExtraPointsLiveTest do
  # async: false: sequential SQLite writes plus self-broadcast/render draining.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Extra Points LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  test "discloses that the SWAR \"speed up pairings\" use of extra points is not supported", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/extra-points")

    assert html =~ "speed up pairings"
    assert html =~ "is not supported"
  end

  test "toggling \"count extra points\" and saving the bands persists both", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/extra-points")

    refute html =~ "Set extra points for"
    refute Tournaments.get_authorized_tournament!(scope, tournament.id).count_extra_points

    html =
      lv
      |> form("#extra-points-form", %{
        "tournament" => %{
          "count_extra_points" => "true",
          "extra_points_bands" => " 1600:0.5 , 1400:1 "
        }
      })
      |> render_submit()

    assert html =~ "1400:1"

    saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
    assert saved.count_extra_points == true
    assert saved.extra_points_bands == "1400:1, 1600:0.5"

    render(lv)
  end

  test "\"Apply bands to players\" sets extra_points from the saved bands and shows a summary", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope, %{"extra_points_bands" => "1400:1"})

    {:ok, low} =
      Tournaments.create_player(tournament.id, %{"name" => "Low", "fide_rating" => "1200"})

    {:ok, high} =
      Tournaments.create_player(tournament.id, %{"name" => "High", "fide_rating" => "2000"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/extra-points")

    html =
      lv
      |> element("button", "Apply bands to players")
      |> render_click()

    assert html =~ "Set extra points for 1 of 2 players."
    assert Tournaments.get_player!(low.id).extra_points == 1.0
    assert Tournaments.get_player!(high.id).extra_points == 0.0

    render(lv)
  end
end
