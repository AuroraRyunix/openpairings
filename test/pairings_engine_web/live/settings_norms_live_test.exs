defmodule PairingsEngineWeb.SettingsNormsLiveTest do
  @moduledoc """
  Settings, Officials & norms: the event type B.01 judges the norms with
  (1.4.1 (b), 1.4.3 (a)-(c)) and what the field says about the big-Swiss
  clause (1.4.3 (d)). The officials form itself is covered in
  `NormsOfficialsTest`.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Officials LV", "type" => "swiss", "rounds_count" => "9"}, attrs)
      )

    tournament
  end

  test "is in the settings frame, with a rail link of its own", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/norms")

    assert has_element?(lv, "#settings-page")
    assert has_element?(lv, "#settings-nav a.active[href='/t/#{tournament.id}/settings/norms']")
    assert has_element?(lv, "#officials-form")
    assert has_element?(lv, "#norm-settings-form")
  end

  # B.01 1.4.1 (b) / 1.4.3: the event type is offered by tournament kind.
  test "offers the team norm event types on a team tournament and saves one", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope, %{"type" => "team-swiss"})
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/norms")

    assert has_element?(lv, "#norm-event-type option[value=team_championship]")
    refute has_element?(lv, "#norm-event-type option[value=zonal]")

    lv
    |> form("#norm-settings-form", %{"tournament" => %{"norm_event_type" => "team_championship"}})
    |> render_submit()

    assert has_element?(lv, "#norm-settings-note")
    assert Tournaments.get_tournament!(tournament.id).norm_event_type == "team_championship"
  end

  test "offers only the individual norm event types on an individual tournament", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/norms")

    assert has_element?(lv, "#norm-event-type option[value=zonal]")
    assert has_element?(lv, "#norm-event-type option[value=ordinary][selected]")
    refute has_element?(lv, "#norm-event-type option[value=team_championship]")
  end

  test "saving the event type leaves unsaved officials typing alone", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/norms")

    # A remove/add only lives in the page until "Save officials".
    lv |> element(~s(button[phx-click="add_arbiter"])) |> render_click()
    assert has_element?(lv, "input[name='tournament[officials][arbiter1_name]']")

    lv
    |> form("#norm-settings-form", %{"tournament" => %{"norm_event_type" => "zonal"}})
    |> render_submit()

    assert has_element?(lv, "input[name='tournament[officials][arbiter1_name]']")
    assert Tournaments.get_tournament!(tournament.id).norm_event_type == "zonal"
    # The echo of its own save is not somebody else's change.
    refute render(lv) =~ "updated elsewhere"
  end

  test "an event type that is not one of B.01's is refused", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/norms")

    render_submit(lv, "save_norm_settings", %{"tournament" => %{"norm_event_type" => "olympiad"}})

    assert Tournaments.get_tournament!(tournament.id).norm_event_type == "ordinary"
  end

  # B.01 1.4.3 (d): nothing to set, only a sentence about the field.
  test "the big-Swiss clause is reported, not set", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/norms")

    assert has_element?(lv, "#big-swiss-status")
    refute has_element?(lv, "#big-swiss-status input")
  end

  describe "UX gaps: officials form" do
    test "text typed since the last save survives adding an arbiter", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/norms")

      render_change(lv, "officials_change", %{
        "tournament" => %{"officials" => %{"remark1" => "typed, not saved"}}
      })

      lv |> element(~s(button[phx-click="add_arbiter"])) |> render_click()

      assert has_element?(
               lv,
               "input[name='tournament[officials][remark1]'][value='typed, not saved']"
             )
    end

    test "removing one extra arbiter moves the later ones up", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _} =
        Tournaments.update_tournament(tournament, %{
          "officials" => %{
            "extra_arbiters_count" => 2,
            "arbiter1_name" => "First",
            "arbiter1_fide_id" => "1",
            "arbiter2_name" => "Second",
            "arbiter2_fide_id" => "2"
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/norms")
      assert has_element?(lv, "#remove-arbiter-1[data-confirm]")

      lv |> element("#remove-arbiter-1") |> render_click()

      assert has_element?(lv, "input[name='tournament[officials][arbiter1_name]'][value=Second]")
      refute has_element?(lv, "input[name='tournament[officials][arbiter2_name]']")
    end

    test "a search that finds nobody says so", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/norms")

      render_change(lv, "arbiter_search", %{
        "_target" => ["tournament", "chief_arbiter"],
        "tournament" => %{"chief_arbiter" => "Zzzzzz"}
      })

      assert has_element?(lv, "#arbiter-combo-chief_arbiter-name-results-empty")
    end
  end
end
