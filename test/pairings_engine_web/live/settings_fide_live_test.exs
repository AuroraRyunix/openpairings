defmodule PairingsEngineWeb.SettingsFideLiveTest do
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "FIDE LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  test "saves the FIDE tournament ID and event code", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

    lv
    |> form("form[phx-submit=save]", %{
      "tournament" => %{"fide_tournament_id" => "12345", "event_code" => "BEL/2026"}
    })
    |> render_submit()

    render(lv)

    saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
    assert saved.fide_tournament_id == "12345"
    assert saved.event_code == "BEL/2026"
  end

  test "saves the fide_homologated tickbox", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

    lv
    |> form("form[phx-submit=save]", %{"tournament" => %{"fide_homologated" => "true"}})
    |> render_submit()

    render(lv)

    saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
    assert saved.fide_homologated == true
  end

  test "adds a FIDE-ID range row, fills it in, and saves the whole list", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

    refute has_element?(lv, "input[name='tournament[fide_id_ranges][0][fide_tournament_id]']")

    lv |> element("button", "Add range") |> render_click()

    assert has_element?(lv, "input[name='tournament[fide_id_ranges][0][fide_tournament_id]']")

    lv
    |> form("form[phx-submit=save]", %{
      "tournament" => %{
        "fide_id_ranges" => %{
          "0" => %{"fide_tournament_id" => "111", "from_round" => "1", "to_round" => "3"}
        }
      }
    })
    |> render_submit()

    render(lv)

    saved = Tournaments.get_authorized_tournament!(scope, tournament.id)

    assert saved.fide_id_ranges == [
             %{"fide_tournament_id" => "111", "from_round" => 1, "to_round" => 3}
           ]
  end

  test "removes a range row before saving", %{conn: conn, scope: scope} do
    tournament =
      create_tournament(scope, %{
        "fide_id_ranges" => [
          %{"fide_tournament_id" => "111", "from_round" => "1", "to_round" => "3"}
        ]
      })

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

    assert has_element?(lv, "input[name='tournament[fide_id_ranges][0][fide_tournament_id]']")

    lv |> element("button", "Remove") |> render_click()

    refute has_element?(lv, "input[name='tournament[fide_id_ranges][0][fide_tournament_id]']")

    lv |> form("form[phx-submit=save]", %{"tournament" => %{}}) |> render_submit()
    render(lv)

    saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
    assert saved.fide_id_ranges == []
  end

  test "an existing range is shown pre-filled on reload", %{conn: conn, scope: scope} do
    tournament =
      create_tournament(scope, %{
        "fide_id_ranges" => [
          %{"fide_tournament_id" => "222", "from_round" => "1", "to_round" => "9"}
        ]
      })

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

    assert html =~ ~s(name="tournament[fide_id_ranges][0][fide_tournament_id]")
    assert html =~ "222"
  end

  # B.01 1.4.1 (b) / 1.4.3: the norm event type is offered by tournament kind.
  test "offers the team norm event types on a team tournament and saves one", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope, %{"type" => "team-swiss", "rounds_count" => "9"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

    assert has_element?(lv, "#norm-event-type option[value=team_championship]")
    refute has_element?(lv, "#norm-event-type option[value=zonal]")

    lv
    |> form("#fide-settings-form", %{"tournament" => %{"norm_event_type" => "team_championship"}})
    |> render_submit()

    saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
    assert saved.norm_event_type == "team_championship"
  end

  test "offers only the individual norm event types on an individual tournament", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

    assert has_element?(lv, "#norm-event-type option[value=zonal]")
    refute has_element?(lv, "#norm-event-type option[value=team_championship]")
  end

  describe "the Save button and the Rating lists card do not share anything" do
    test "a rating-list click says Saved in its own card, not beside Save FIDE settings", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

      lv
      |> form("#rating-sequence-add-form", %{"entry" => "national"})
      |> render_submit()

      assert has_element?(lv, "#rating-note", "Saved.")
      refute has_element?(lv, "#fide-note")

      # And the other way round: saving the FIDE form leaves the card's words alone.
      lv
      |> form("#fide-settings-form", %{"tournament" => %{"event_code" => "X/1"}})
      |> render_submit()

      assert has_element?(lv, "#fide-note", "Saved.")
      refute has_element?(lv, "#rating-note")
    end

    test "a rating-list click does not throw away a range row nobody saved yet", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

      lv |> element("button[phx-click=add_range]") |> render_click()
      assert has_element?(lv, "input[name='tournament[fide_id_ranges][0][fide_tournament_id]']")

      lv
      |> form("#rating-sequence-add-form", %{"entry" => "national"})
      |> render_submit()

      # The echo of the card's own save arrives as a tournament broadcast.
      _ = :sys.get_state(lv.pid)
      assert has_element?(lv, "input[name='tournament[fide_id_ranges][0][fide_tournament_id]']")
      refute render(lv) =~ "updated elsewhere"
    end

    test "a Save FIDE settings click does not touch the rating sequence", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

      lv |> form("#rating-sequence-add-form", %{"entry" => "national"}) |> render_submit()
      before = Tournaments.get_authorized_tournament!(scope, tournament.id).rating_list_sequence

      lv
      |> form("#fide-settings-form", %{"tournament" => %{"fide_tournament_id" => "777"}})
      |> render_submit()

      saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert saved.rating_list_sequence == before
      assert saved.fide_tournament_id == "777"
    end
  end
end
