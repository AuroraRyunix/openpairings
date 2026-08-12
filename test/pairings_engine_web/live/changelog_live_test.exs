defmodule PairingsEngineWeb.ChangelogLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  test "renders CHANGELOG.md content under a top-level heading", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/changelog")

    assert html =~ "Changelog</h1>"
    assert html =~ "changelog-body"
    # A real entry from CHANGELOG.md, not just an empty shell.
    assert html =~ "0.12."
  end

  test "the nav link is visible outside a tournament and points at /changelog", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")

    assert html =~ ~s(href="/changelog")
    assert html =~ "Changelog"
  end

  test "the nav link disappears once inside a tournament", %{conn: conn, scope: scope} do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Nav Test", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    refute html =~ ~s(href="/changelog")
  end

  test "the old tournament-scoped changelog route redirects to the global page", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Old Link Test", "type" => "swiss"})

    assert {:error, {:live_redirect, %{to: "/changelog"}}} =
             live(conn, ~p"/t/#{tournament.id}/settings/changelog")
  end
end
