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

  test "it needs no account", %{} do
    # It describes the application, not anybody's tournament, and reads
    # nothing but CHANGELOG.md - there is no data behind it to protect. It
    # sat behind `:require_authenticated_user` only because it was added
    # beside the tournament routes and inherited their pipeline, which
    # surfaced the moment the version number in the top bar was made to link
    # here: that link renders for signed-out visitors too, so it sent them to
    # a log-in screen for a public document.
    {:ok, _lv, html} = live(build_conn(), ~p"/changelog")

    assert html =~ "changelog-body"
    assert html =~ "0.12."
  end

  test "a signed-out reader still gets the version link that brought them", %{} do
    {:ok, lv, _html} = live(build_conn(), ~p"/changelog")

    assert lv |> element("a.app-version[href='/changelog']") |> has_element?()
  end

  test "the nav link is visible outside a tournament and points at /changelog", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")

    assert html =~ ~s(href="/changelog")
    assert html =~ "Changelog"
  end

  test "the nav link disappears once inside a tournament", %{conn: conn, scope: scope} do
    # The TAB goes, so the tournament's own tabs are not competing with a
    # global one. The version number in the corner still links there, which
    # is a different thing: it was already on every page and adds no item to
    # the bar. So this asserts the tab is gone rather than that the path is
    # absent - the broader claim was true only until the version became
    # clickable, and it was never what the rule meant.
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Nav Test", "type" => "swiss"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

    refute lv |> element("nav a[href='/changelog']:not(.app-version)") |> has_element?()
    assert lv |> element("a.app-version[href='/changelog']") |> has_element?()
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
