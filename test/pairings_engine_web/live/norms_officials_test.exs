defmodule PairingsEngineWeb.NormsOfficialsTest do
  # The Officials & FIDE report data card moved from SettingsLive to the Norms
  # tab. These tests cover that relocated card (arbiter FIDE-autocomplete,
  # officials fields, saving).
  #
  # async: false: sequential SQLite writes plus self-broadcast/render draining.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Fide.FidePlayer

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Norms LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  test "the Officials card only shows two deputy slots and no standalone FIDE-id / pairing-mode inputs",
       %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

    refute html =~ "Chief arbiter FIDE ID"
    refute html =~ ~s(name="tournament[officials][pairing_mode]")
    refute html =~ ~s(name="tournament[officials][pairing_program]")
    refute html =~ ~s(name="tournament[officials][swiss_variant]")

    assert html =~ "1st deputy arbiter"
    assert html =~ "2nd deputy arbiter"
    refute html =~ "3rd deputy arbiter"
    refute html =~ "4th deputy arbiter"

    # The deputy FIDE id is only carried as a hidden field.
    refute html =~ ~s(type="text" name="tournament[officials][deputy1_fide_id]")
    assert html =~ ~s(type="hidden" name="tournament[officials][deputy1_fide_id]")
  end

  test "typing a chief arbiter query shows FIDE matches, and picking one fills name + FIDE id then saves",
       %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)

    fide_player =
      Repo.insert!(%FidePlayer{
        fide_id: 1_503_014,
        name: "Carlsen, Magnus",
        federation: "NOR",
        title: "GM"
      })

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

    html =
      render_change(lv, "arbiter_search", %{
        "role" => "chief_arbiter",
        "tournament" => %{"chief_arbiter" => "Carlsen"}
      })

    assert html =~ "Carlsen, Magnus"

    html =
      render_click(lv, "arbiter_pick", %{
        "role" => "chief_arbiter",
        "fide-id" => to_string(fide_player.fide_id)
      })

    assert html =~ ~s(value="Carlsen, Magnus")
    assert html =~ "FIDE ID: 1503014"
    assert html =~ ~s(name="tournament[officials][chief_arbiter_fide_id]" value="1503014")

    render_submit(lv, "save_officials", %{
      "tournament" => %{
        "chief_arbiter" => "Carlsen, Magnus",
        "officials" => %{"chief_arbiter_fide_id" => "1503014"}
      }
    })

    render(lv)

    saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
    assert saved.chief_arbiter == "Carlsen, Magnus"
    assert saved.officials["chief_arbiter_fide_id"] == "1503014"
  end

  test "the FIDE identifiers moved to the FIDE settings page, not the Norms Officials card", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

    refute html =~ ~s(name="tournament[fide_tournament_id]")
    refute html =~ ~s(name="tournament[event_code]")

    {:ok, _lv, fide_html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")
    assert fide_html =~ ~s(name="tournament[fide_tournament_id]")
    assert fide_html =~ ~s(name="tournament[event_code]")
  end
end
