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
end
