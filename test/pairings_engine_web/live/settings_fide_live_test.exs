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
end
