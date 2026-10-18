defmodule PairingsEngineWeb.SettingsAdvancedSwitchTest do
  @moduledoc """
  The "Show advanced settings" switch belongs on a Settings page only if the
  page, as rendered for this tournament right now, has something for it to
  show. A switch that flips nothing is a small lie, and an arbiter is entitled
  to wonder what they are missing.

  Walks every Settings page for a few tournament shapes and checks the two
  facts agree: the switch is drawn if and only if a `.tset-adv` element is
  on the page.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  @pages [
    "settings",
    "settings/group",
    "settings/options",
    "settings/scoring",
    "settings/dates",
    "settings/rooms",
    "categories",
    "settings/extra-points",
    "settings/restrictions",
    "settings/results",
    "settings/boards",
    "settings/fide",
    "settings/norms",
    "settings/export",
    "settings/about"
  ]

  @shapes [
    {"Swiss", %{"type" => "swiss"}},
    {"round robin", %{"type" => "swiss", "pairing_system" => "round_robin"}},
    {"team Swiss", %{"type" => "team-swiss"}},
    {"team round robin", %{"type" => "team-roundrobin", "pairing_system" => "round_robin"}}
  ]

  for {shape, attrs} <- @shapes do
    test "the switch is on a page exactly when the page has an advanced element (#{shape})", %{
      conn: conn,
      scope: scope
    } do
      attrs = unquote(Macro.escape(attrs))

      {:ok, tournament} =
        Tournaments.create_tournament(
          scope,
          Map.merge(%{"name" => "Switch", "type" => "swiss", "rounds_count" => "5"}, attrs)
        )

      for page <- @pages do
        {:ok, lv, _html} = live(conn, "/t/#{tournament.id}/#{page}")

        assert has_element?(lv, "#settings-page"), "#{page} is not in the settings frame"

        assert has_element?(lv, "#settings-advanced-toggle") == has_element?(lv, ".tset-adv"),
               "#{page} (#{unquote(shape)}): the switch and the advanced elements disagree"
      end
    end
  end

  test "the Group page is in the rail, after Tournament", %{conn: conn, scope: scope} do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Rail", "type" => "swiss"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

    assert has_element?(lv, "#settings-nav a[href='/t/#{tournament.id}/settings/group']")
    refute has_element?(lv, "#group-card")
    refute has_element?(lv, "#group-link")

    # Not even when the tournament is in a group: the rail is the signpost.
    {:ok, _} = PairingsEngine.TournamentGroups.create_group(scope, tournament, "Festival")
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")
    refute has_element?(lv, "#group-link")
  end
end
