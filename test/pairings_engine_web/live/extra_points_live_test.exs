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
        Map.merge(
          %{"name" => "Extra Points LV Test", "type" => "swiss", "rounds_count" => "5"},
          attrs
        )
      )

    tournament
  end

  test "the kind picked in the form changes the wording before it is saved", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/extra-points")

    assert lv |> element("#extra-points-mode-hint") |> render() =~ "Handicap"
    refute has_element?(lv, "#reduce-extra-points-form")

    lv
    |> form("#extra-points-form", %{"tournament" => %{"extra_points_mode" => "acceleration"}})
    |> render_change()

    assert lv |> element("#extra-points-mode-hint") |> render() =~ "Acceleration"
    assert render(lv) =~ "Keep acceleration points in the final standings"
    # Nothing saved yet.
    assert Tournaments.get_authorized_tournament!(scope, tournament.id).extra_points_mode ==
             "handicap"
  end

  test "acceleration mode saves, and \"Remove half a point\" winds it down by rating range", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)

    {:ok, strong} =
      Tournaments.create_player(tournament.id, %{
        "name" => "Strong",
        "fide_rating" => "2200",
        "extra_points" => "1"
      })

    {:ok, weak} =
      Tournaments.create_player(tournament.id, %{
        "name" => "Weak",
        "fide_rating" => "1500",
        "extra_points" => "1"
      })

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/extra-points")

    lv
    |> form("#extra-points-form", %{"tournament" => %{"extra_points_mode" => "acceleration"}})
    |> render_submit()

    assert Tournaments.get_authorized_tournament!(scope, tournament.id).extra_points_mode ==
             "acceleration"

    assert has_element?(lv, "#reduce-extra-points-form")

    html =
      lv
      |> form("#reduce-extra-points-form", %{"reduce" => %{"from" => "2000", "to" => "3000"}})
      |> render_submit()

    assert html =~ "Took half a point off 1 player."
    assert Tournaments.get_player!(tournament.id, strong.id).extra_points == 0.5
    assert Tournaments.get_player!(tournament.id, weak.id).extra_points == 1.0

    html =
      lv
      |> form("#reduce-extra-points-form", %{"reduce" => %{"from" => "3000", "to" => "2000"}})
      |> render_submit()

    assert html =~ "not above the second"
  end

  test "Baku cannot be combined: the page says so instead of saving", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope, %{"acceleration" => "baku"})
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/extra-points")

    html =
      lv
      |> form("#extra-points-form", %{"tournament" => %{"extra_points_mode" => "acceleration"}})
      |> render_submit()

    assert html =~ "Baku acceleration cannot be combined"

    assert Tournaments.get_authorized_tournament!(scope, tournament.id).extra_points_mode ==
             "handicap"
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
    assert Tournaments.get_player!(low.tournament_id, low.id).extra_points == 1.0
    assert Tournaments.get_player!(high.tournament_id, high.id).extra_points == 0.0

    render(lv)
  end
end
