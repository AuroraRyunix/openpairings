defmodule PairingsEngineWeb.StandingsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  test "the overall Print button links to the (round-less) standings print document", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Standings Print Test", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

    assert html =~ ~s(href="/t/#{tournament.id}/print/standings")
    assert html =~ ~s(target="_blank")
  end

  test "shows a public standings link pointing at the tournament's public slug", %{conn: conn, scope: scope} do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Public Link Test", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

    assert tournament.public_slug
    assert html =~ ~s(href="/p/#{tournament.public_slug}/standings")
    assert html =~ "Public standings link"
  end

  describe "Extra points (SWAR parity #12 XtPts) columns" do
    test "XtPts/Total columns are hidden while count_extra_points is off (the default)", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Extra Points Off", "type" => "swiss"})
      {:ok, _p} = Tournaments.create_player(tournament.id, %{"name" => "Alice", "extra_points" => "1.0"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      refute html =~ "XtPts"
      refute html =~ "Total"
    end

    test "XtPts/Total columns appear once count_extra_points is on", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Extra Points On",
          "type" => "swiss",
          "count_extra_points" => "true"
        })

      {:ok, _p} = Tournaments.create_player(tournament.id, %{"name" => "Alice", "extra_points" => "1.5"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      assert html =~ "XtPts"
      assert html =~ "Total"
      assert html =~ "1.5"
    end
  end
end
