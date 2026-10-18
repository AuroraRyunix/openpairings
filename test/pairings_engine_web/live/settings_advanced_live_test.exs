defmodule PairingsEngineWeb.SettingsAdvancedLiveTest do
  @moduledoc """
  The "Show advanced settings" switch on the tournament Settings pages
  (`SettingsSupport.settings_page/1`): what it hides, where it is kept, and
  that a changed advanced setting is never out of sight without a word.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Accounts.User

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Advanced LV", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  test "off by default: advanced settings stay in the form, hidden", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

    assert has_element?(lv, "#settings-advanced-toggle[aria-checked='false']")
    refute has_element?(lv, "#settings-main.show-advanced")
    # Hidden by CSS, not left out: the save still sends it.
    assert has_element?(lv, "#pairing-settings-form .tset-adv #initial-colour-select")
    refute has_element?(lv, "#settings-advanced-changed")
  end

  test "the switch is stored on the account and followed by every page", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

    lv |> element("#settings-advanced-toggle") |> render_click()

    assert has_element?(lv, "#settings-main.show-advanced")
    assert has_element?(lv, "#settings-advanced-toggle[aria-checked='true']")
    assert Repo.get!(User, user.id).settings_advanced

    {:ok, other, _html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")
    assert has_element?(other, "#settings-main.show-advanced")

    other |> element("#settings-advanced-toggle") |> render_click()
    refute Repo.get!(User, user.id).settings_advanced
  end

  test "a changed advanced setting is announced while hidden, and the note opens it", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, _} = Tournaments.update_tournament(tournament, %{"shared_places" => "true"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

    assert has_element?(lv, "#settings-advanced-changed", "1 advanced setting")

    lv |> element("#settings-advanced-changed") |> render_click()

    assert has_element?(lv, "#settings-main.show-advanced")
    refute has_element?(lv, "#settings-advanced-changed")
  end

  test "switching it does not mark the page as being edited", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

    lv |> element("#settings-advanced-toggle") |> render_click()

    # A clean page reloads on a broadcast instead of raising the stale
    # banner - which it only does while `dirty` is false.
    {:ok, _} = Tournaments.update_tournament(tournament, %{"name" => "Renamed elsewhere"})
    assert render(lv) =~ "Renamed elsewhere"
  end

  test "every Settings page carries the rail", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)

    for path <- [
          ~p"/t/#{tournament.id}/settings",
          ~p"/t/#{tournament.id}/settings/options",
          ~p"/t/#{tournament.id}/settings/scoring",
          ~p"/t/#{tournament.id}/settings/dates",
          ~p"/t/#{tournament.id}/categories",
          ~p"/t/#{tournament.id}/settings/extra-points",
          ~p"/t/#{tournament.id}/settings/restrictions",
          ~p"/t/#{tournament.id}/settings/results",
          ~p"/t/#{tournament.id}/settings/boards",
          ~p"/t/#{tournament.id}/settings/fide",
          ~p"/t/#{tournament.id}/settings/export",
          ~p"/t/#{tournament.id}/settings/about"
        ] do
      {:ok, lv, _html} = live(conn, path)
      assert has_element?(lv, "#settings-nav a.active[aria-current='page']"), path
    end
  end

  test "the Byes and absences card is advanced, and its points count when they are set", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")

    assert has_element?(lv, "#byes-absences-card.tset-adv")
    refute has_element?(lv, "#settings-advanced-changed")

    {:ok, _} = Tournaments.update_tournament(tournament, %{"abs_value" => "0.5"})
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")

    assert has_element?(lv, "#settings-advanced-changed", "1 advanced setting")
  end
end
