defmodule PairingsEngineWeb.SettingsAboutLiveTest do
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "About LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  test "the About link is reachable from the Settings subnav", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

    assert html =~ ~s(href="/t/#{tournament.id}/settings/about")
  end

  test "shows the pairing engine in use and the credits, for a Swiss tournament",
       %{conn: conn, scope: scope} do
    tournament = create_tournament(scope, %{"type" => "swiss"})

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/about")

    assert html =~ "Swiss"
    assert html =~ "Ainalrami"
    # Two people are thanked, each in bold, in one sentence.
    assert has_element?(lv, "#about-credits strong:nth-of-type(2)")
    refute has_element?(lv, "#about-credits strong:nth-of-type(3)")
  end

  test "reflects a round-robin tournament's own engine label", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/about")

    assert html =~ "Round robin (Berger)"
  end
end
