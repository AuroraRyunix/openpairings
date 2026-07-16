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
end
